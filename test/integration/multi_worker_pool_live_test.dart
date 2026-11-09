/// Integration tests against PostgreSQL at localhost:5432 (database `teste`,
/// superuser `postgres`; see the README, "Tests"): a [MultiWorkerServer] whose
/// workers each open their own real [PostgresConnectionPool] in the setup and
/// close it in `onShutdown`.
///
/// Connections are counted where it matters, in `pg_stat_activity`: every
/// worker tags its pool with `application_name=orbiter_mw_<run>_w<id>`.
///
/// Skips when the native library is not built or Postgres is unreachable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:orbiter/orbiter.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _workers = 3;
const _poolSize = 2;

String _appPrefix(String run) => 'orbiter_mw_${run}_w';

/// Each worker opens a pool of [_poolSize] real connections. `/` answers
/// `<workerId>:<backend pid>`; the short sleep makes concurrent requests queue
/// on the pool. `/crash` on worker 1 throws an uncaught error that ends the
/// isolate while its query is in flight.
///
/// Top-level so the closure captures only [run], which can cross isolates.
WorkerSetup _pgSetup(String run) => (context) async {
      final pool = PostgresConnectionPool(PoolConfig(
        connInfo: '$_connInfo application_name=${_appPrefix(run)}${context.id}',
        minSize: _poolSize,
        maxSize: _poolSize,
        acquireTimeout: const Duration(seconds: 5),
      ));
      await pool.start();
      return WorkerApp(
        handler: (request) async {
          if (request.uri.path == '/crash' && context.id == 1) {
            scheduleMicrotask(() => throw StateError('boom'));
          }
          final pid = await withPostgresConnection(pool, (exec) async {
            final rs = await exec
                .execute('SELECT pg_backend_pid()::text AS v, pg_sleep(0.01)');
            try {
              return rs.row(0).getString('v');
            } finally {
              rs.release();
            }
          });
          return Response.ok(body: '${context.id}:$pid');
        },
        onShutdown: pool.close,
      );
    };

Future<(int, String)> _get(HttpClient client, int port,
    [String path = '/']) async {
  final request =
      await client.get(InternetAddress.loopbackIPv4.address, port, path);
  request.persistentConnection = false;
  final response = await request.close();
  return (response.statusCode, await response.transform(utf8.decoder).join());
}

/// Backend pid → `application_name` of every connection opened by run [run]'s
/// workers.
Future<Map<String, String>> _backends(
    PostgresConnectionPool observer, String run) {
  return withPostgresConnection(observer, (exec) async {
    final rs = await exec.execute(
      'SELECT pid::text AS p, application_name AS a FROM pg_stat_activity '
      r'WHERE starts_with(application_name, $1)',
      params: [Param.text(_appPrefix(run))],
    );
    try {
      return {
        for (var i = 0; i < rs.rowCount; i++)
          rs.row(i).getString('p')!: rs.row(i).getString('a')!,
      };
    } finally {
      rs.release();
    }
  });
}

/// Connection count per worker id, as Postgres sees it.
Future<Map<int, int>> _connectionsByWorker(
    PostgresConnectionPool observer, String run) async {
  final prefix = _appPrefix(run);
  final counts = <int, int>{};
  for (final app in (await _backends(observer, run)).values) {
    final id = int.parse(app.substring(prefix.length));
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}

/// Backends end asynchronously after the client closes them; polls until
/// [expected] or the deadline.
Future<Map<int, int>> _settleConnections(
    PostgresConnectionPool observer, String run, Map<int, int> expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  var counts = await _connectionsByWorker(observer, run);
  while (!_sameCounts(counts, expected) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    counts = await _connectionsByWorker(observer, run);
  }
  return counts;
}

bool _sameCounts(Map<int, int> a, Map<int, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

Map<int, int> _full(Iterable<int> ids) => {for (final id in ids) id: _poolSize};

void main() {
  PostgresConnectionPool? observer;
  String? skipReason;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
        connInfo: '$_connInfo application_name=orbiter_mw_observer',
        minSize: 1,
        maxSize: 1,
        acquireTimeout: const Duration(seconds: 5),
      ));
      await p.start();
      observer = p;
    } on Object catch (e) {
      skipReason =
          'Postgres or native library unavailable ($e) — start PostgreSQL at localhost:5432';
    }
  });

  tearDownAll(() async => observer?.close());

  group('MultiWorkerServer × per-worker PostgresConnectionPool (live)', () {
    late String run;
    late HttpClient client;
    late List<Object> reports;
    MultiWorkerServer? server;

    setUp(() async {
      run = Random().nextInt(1 << 32).toRadixString(16);
      client = HttpClient();
      reports = [];
      if (skipReason != null) return;
      server = await MultiWorkerServer.start(
        setup: _pgSetup(run),
        workers: _workers,
        address: InternetAddress.loopbackIPv4,
        port: 0,
        onError: (error, _, __) => reports.add(error),
      );
    });

    tearDown(() async {
      client.close(force: true);
      await server?.close(force: true, drainTimeout: Duration.zero);
      server = null;
      // A dead worker's connections outlive it; end them in the database so
      // they do not leak into other tests.
      final o = observer;
      if (o != null) {
        await withPostgresConnection(o, (exec) async {
          final rs = await exec.execute(
            'SELECT pg_terminate_backend(pid) FROM pg_stat_activity '
            r'WHERE starts_with(application_name, $1)',
            params: [Param.text(_appPrefix(run))],
          );
          rs.release();
        });
      }
    });

    test('every worker opens its own pool and serves SQL concurrently',
        () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final s = server!;

      expect(await _settleConnections(observer!, run, _full([0, 1, 2])),
          _full([0, 1, 2]));

      final results = await Future.wait([
        for (var i = 0; i < 200; i++) _get(client, s.port),
      ]);
      expect(results.map((r) => r.$1), everyElement(200));

      final backends = await _backends(observer!, run);
      final workersSeen = <String>{};
      for (final (_, body) in results) {
        final [worker, pid] = body.split(':');
        workersSeen.add(worker);
        // The connection that answered belongs to the worker that answered.
        expect(backends[pid], '${_appPrefix(run)}$worker', reason: body);
      }
      expect(workersSeen, everyElement(isIn(['0', '1', '2'])));
      expect(workersSeen.length, greaterThanOrEqualTo(2));
      expect(reports, isEmpty);
    });

    test('close returns every connection to the database', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final s = server!;
      expect(await _settleConnections(observer!, run, _full([0, 1, 2])),
          _full([0, 1, 2]));
      await Future.wait([for (var i = 0; i < 30; i++) _get(client, s.port)]);

      await s.close();
      server = null;

      expect(await _settleConnections(observer!, run, {}), isEmpty);
      // No onShutdown failure (pool.close timeout) and no killed worker.
      expect(reports, isEmpty);
    });

    test('a worker that dies leaves the other pools intact', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final s = server!;
      expect(await _settleConnections(observer!, run, _full([0, 1, 2])),
          _full([0, 1, 2]));

      // Connections land on any worker; only worker 1 crashes, and the request
      // open on it is never answered, so crash requests are not awaited.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (reports.isEmpty && DateTime.now().isBefore(deadline)) {
        unawaited(_get(client, s.port, '/crash')
            .timeout(const Duration(seconds: 1))
            .then<void>((_) {}, onError: (_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(reports, [
        isA<WorkerExitedException>()
            .having((e) => e.workerId, 'workerId', 1)
            .having((e) => '${e.cause}', 'cause', contains('boom')),
      ]);

      final results = await Future.wait([
        for (var i = 0; i < 40; i++) _get(client, s.port),
      ]);
      expect(results.map((r) => r.$1), everyElement(200));
      expect(results.map((r) => r.$2.split(':').first),
          everyElement(isIn(['0', '2'])));

      // Nothing closes the dead worker's pool (no onShutdown, no finalizer):
      // its connections stay open in the database until the process exits.
      expect(await _connectionsByWorker(observer!, run), _full([0, 1, 2]));

      // The survivors still shut down cleanly.
      await s.close();
      server = null;
      expect(await _settleConnections(observer!, run, {1: _poolSize}),
          {1: _poolSize});
      expect(reports, hasLength(1));
    });
  });
}
