/// Integration tests against PostgreSQL at localhost:5432 (database `teste`,
/// superuser `postgres`; see the README, "Tests"):
/// a connection borrowed per request, holding session state, must go back to
/// the pool clean through `Request.addCleanupHook` — after the response is
/// fully written, and also when the handler throws. This is the per-request
/// pattern a row-level-security setup relies on.
///
/// Skips when the native library is not built or Postgres is unreachable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

/// The executor borrowed for the current request.
final class RequestConnection {
  final PostgresQueryExecutorContract exec;
  const RequestConnection(this.exec);
}

/// Borrows one connection per request and returns it from a cleanup hook.
///
/// Uses only the connector's public API: `withPostgresConnection` holds the
/// connection until the hook completes `done`, then releases it (running the
/// pool's session reset).
InterceptorFunction borrowConnection(PostgresConnectionPool pool) {
  return (request, next) async {
    final ready = Completer<PostgresQueryExecutorContract>();
    final done = Completer<void>();
    final held = withPostgresConnection<void>(pool, (exec) async {
      ready.complete(exec);
      await done.future;
    });
    // Acquire failures surface here, before any hook is registered.
    final exec = await Future.any([ready.future, held.then((_) => ready.future)]);
    request.addCleanupHook(() {
      done.complete();
      return held;
    });
    request.context.set(RequestConnection(exec));
    return next(request);
  };
}

Future<String?> scalar(PostgresQueryExecutorContract exec, String sql) async {
  final rs = await exec.execute(sql);
  try {
    return rs.rowCount > 0 ? rs.row(0).getString('v') : null;
  } finally {
    rs.release();
  }
}

/// Cleanup runs after the response is written, so the client can see the
/// response a moment before the connection is back in the pool.
Future<void> expectPoolFree(PostgresConnectionPool pool) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (pool.borrowed != 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(pool.borrowed, 0);
}

void main() {
  PostgresConnectionPool? pool;
  String? skipReason;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
        connInfo: _connInfo,
        minSize: 1,
        maxSize: 1,
        acquireTimeout: const Duration(seconds: 5),
      ));
      await p.start();
      pool = p;
    } on Object catch (e) {
      skipReason = 'Postgres or native library unavailable ($e) — start PostgreSQL at localhost:5432';
    }
  });

  tearDownAll(() async => pool?.close());

  group('orbiter × slingshot_postgres (live)', () {
    late BackendServer server;
    late HttpClient client;
    late Uri base;

    setUp(() async {
      if (skipReason != null) return;
      final router = Router()
        ..get('/tenant/:id/fail', (request) async {
          final exec = request.context.get<RequestConnection>().exec;
          await exec.execute(
            r"SELECT set_config('app.current_tenant_id', $1, false)",
            params: [Param.text(request.pathParam('id')!)],
          );
          throw StateError('handler failure after setting tenant');
        })
        ..get('/tenant/:id/slow', (request) async {
          final exec = request.context.get<RequestConnection>().exec;
          await exec.execute(
            r"SELECT set_config('app.current_tenant_id', $1, false)",
            params: [Param.text(request.pathParam('id')!)],
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return Response.ok(body: 'finished after the client left');
        })
        ..get('/tenant/current', (request) async {
          final exec = request.context.get<RequestConnection>().exec;
          final tenant =
              await scalar(exec, "SELECT current_setting('app.current_tenant_id', true) AS v");
          return Response.ok(body: tenant ?? '');
        })
        ..get('/stream', (request) {
          final exec = request.context.get<RequestConnection>().exec;
          Stream<List<int>> rows() async* {
            for (var i = 0; i < 3; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              final v = await scalar(exec, 'SELECT ($i + 1)::text AS v');
              yield utf8.encode('$v;');
            }
          }

          return Response(200, body: rows());
        });

      server = await BackendServer.bind(
        handler: Pipeline().add(borrowConnection(pool!)).addHandler(router.handler),
        address: InternetAddress.loopbackIPv4,
        port: 0,
        onError: (error, stackTrace, request) {},
      );
      client = HttpClient();
      base = Uri.parse('http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      if (skipReason != null) return;
      client.close(force: true);
      await server.close(force: true);
    });

    /// Registers [body] as a test that is skipped when Postgres is unavailable.
    void liveTest(String description, Future<void> Function() body) {
      test(description, () async {
        if (skipReason != null) {
          markTestSkipped(skipReason!);
          return;
        }
        await body();
      });
    }

    Future<(int, String)> get(String path) async {
      final res = await (await client.getUrl(base.resolve(path)))
          .close()
          .timeout(const Duration(seconds: 10));
      return (res.statusCode, await utf8.decoder.bind(res).join());
    }

    liveTest('handler exception returns the connection to the pool with session reset', () async {
      final (failStatus, _) = await get('/tenant/clinic-a/fail');
      expect(failStatus, 500);

      // maxSize 1: this only succeeds if the failed request released the
      // connection; the tenant must not leak into the next borrower.
      final (status, tenant) = await get('/tenant/current');
      expect(status, 200);
      expect(tenant, isEmpty);
      await expectPoolFree(pool!);
    });

    liveTest('client abort during the handler still returns the connection', () async {
      final aborting = HttpClient();
      final req = await aborting.getUrl(base.resolve('/tenant/clinic-a/slow'));
      unawaited(req.close().then<void>((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      aborting.close(force: true);

      // maxSize 1: succeeds only once the abandoned request ran its hook,
      // and the tenant must not leak into this borrower.
      final (status, tenant) = await get('/tenant/current');
      expect(status, 200);
      expect(tenant, isEmpty);
      await expectPoolFree(pool!);
    });

    liveTest('streamed body keeps the connection until fully written', () async {
      final (status, body) = await get('/stream');
      expect(status, 200);
      expect(body, '1;2;3;');
      await expectPoolFree(pool!);
    });

    liveTest('concurrent requests, half failing, all answer and leave the pool free', () async {
      final results = await Future.wait([
        for (var i = 0; i < 20; i++)
          get(i.isEven ? '/tenant/t$i/fail' : '/tenant/current'),
      ]);

      for (var i = 0; i < results.length; i++) {
        final (status, body) = results[i];
        if (i.isEven) {
          expect(status, 500);
        } else {
          expect(status, 200);
          expect(body, isEmpty, reason: 'tenant leaked into request $i');
        }
      }
      await expectPoolFree(pool!);
    });
  });
}
