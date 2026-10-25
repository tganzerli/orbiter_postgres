/// Support for the stress suite of the RLS middleware: fixture, parameters,
/// ledger, pool sampler, server and load generator.
///
/// The suite asserts INTEGRITY invariants only. It never reports or asserts
/// time, throughput or latency: client and server share one event loop and
/// the handlers sleep on purpose, so any timing would be contaminated.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:orbiter/orbiter.dart';
import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';

const adminConn =
    'host=localhost port=5432 dbname=teste user=postgres password=123';
const appConn =
    'host=localhost port=5432 dbname=teste user=rls_stress_app password=app';

/// Four tenants; index 0 is the hot one.
final tenantIds = [
  for (var k = 1; k <= 4; k++) '00000000-0000-0000-0000-00000000000$k'
];
String tokenOf(int k) => 'tok$k';

const fixture = [
  'DROP SCHEMA IF EXISTS rls_stress CASCADE',
  'DROP ROLE IF EXISTS rls_stress_app',
  'DROP ROLE IF EXISTS rls_stress_owner',
  'CREATE ROLE rls_stress_owner NOLOGIN',
  "CREATE ROLE rls_stress_app LOGIN PASSWORD 'app' NOSUPERUSER NOBYPASSRLS",
  'CREATE SCHEMA rls_stress AUTHORIZATION rls_stress_owner',
  'CREATE TABLE rls_stress.note (id serial PRIMARY KEY, tenant_id uuid NOT NULL, body text NOT NULL)',
  'ALTER TABLE rls_stress.note OWNER TO rls_stress_owner',
  'ALTER TABLE rls_stress.note ENABLE ROW LEVEL SECURITY',
  'ALTER TABLE rls_stress.note FORCE ROW LEVEL SECURITY',
  '''CREATE POLICY tenant_isolation ON rls_stress.note
     USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
     WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)''',
  'GRANT USAGE ON SCHEMA rls_stress TO rls_stress_app',
  'GRANT SELECT, INSERT, UPDATE, DELETE ON rls_stress.note TO rls_stress_app',
  'GRANT USAGE, SELECT ON SEQUENCE rls_stress.note_id_seq TO rls_stress_app',
];

int _envInt(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

final class StressParams {
  final int requests = _envInt('STRESS_REQUESTS', 400);
  final int users = _envInt('STRESS_USERS', 32);
  final int seed = _envInt(
      'STRESS_SEED', DateTime.now().microsecondsSinceEpoch & 0x7fffffff);
}

Future<String> scalar(PostgresQueryExecutorContract exec, String sql) async {
  final rs = await exec.execute(sql);
  try {
    return rs.rowCount > 0 ? rs.row(0).getString('v')! : '';
  } finally {
    rs.release();
  }
}

Future<List<String>> column(
    PostgresQueryExecutorContract exec, String sql) async {
  final rs = await exec.execute(sql);
  try {
    return [for (var i = 0; i < rs.rowCount; i++) rs.row(i).getString('v')!];
  } finally {
    rs.release();
  }
}

/// What the SERVER decided, recorded by the handlers (same process).
final class Ledger {
  final intendedCommit = <String>{};
  int ghostAttempts = 0;
  int throwsReached = 0;

  /// Queries a stream generator issued AFTER the framework began the cleanup
  /// of its request (the connection may already belong to someone else).
  int queryAfterCleanup = 0;

  /// Errors a stream generator got from its own query (e.g. the connection was
  /// busy because the cleanup already started).
  final streamQueryErrors = <String>[];
}

/// Samples the pool gauges every millisecond.
final class Sampler {
  final PostgresConnectionPool pool;
  int maxBorrowed = 0, maxPending = 0, runNow = 0, maxRun = 0;
  Timer? _t;
  Sampler(this.pool);
  void start() => _t = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (pool.borrowed > maxBorrowed) maxBorrowed = pool.borrowed;
        if (pool.pending > maxPending) maxPending = pool.pending;
        if (pool.pending > 0) {
          runNow++;
          if (runNow > maxRun) maxRun = runNow;
        } else {
          runNow = 0;
        }
      });
  void stop() => _t?.cancel();
}

final class _Principal {
  final String tenantId;
  const _Principal(this.tenantId);
}

/// Server under test: the RLS middleware over [pool], plus public routes.
final class Harness {
  final PostgresConnectionPool pool;
  final BackendServer server;
  final Ledger ledger;
  final List<Object> reported;
  final Uri base;
  Harness._(this.pool, this.server, this.ledger, this.reported, this.base);

  static Future<Harness> start({
    required int maxSize,
    String? reset = 'DISCARD ALL',
    Duration acquireTimeout = const Duration(seconds: 5),
    required int seed,
    Completer<void>? gate,
    void Function()? onEntered,
  }) async {
    final pool = PostgresConnectionPool(PoolConfig(
      connInfo: appConn,
      minSize: 1,
      maxSize: maxSize,
      acquireTimeout: acquireTimeout,
      sessionResetQuery: reset,
    ));
    await pool.start();
    final ledger = Ledger();
    final reported = <Object>[];
    final rng = Random(seed ^ 0x5eed);
    double nap() => 0.005 + rng.nextDouble() * 0.015;

    InterceptorFunction authenticate() => (request, next) {
          final h = request.headers['authorization']?.first;
          if (h != null) {
            for (var k = 0; k < tenantIds.length; k++) {
              if (h == 'Bearer ${tokenOf(k)}') {
                request.context.set<_Principal>(_Principal(tenantIds[k]));
              }
            }
          }
          return next(request);
        };

    Future<void> insert(Request r, String body) async {
      (await r.rls.executor.execute(
        r'INSERT INTO rls_stress.note (tenant_id, body) VALUES ($1::uuid, $2)',
        params: [Param.text(r.rls.tenantId), Param.text(body)],
      ))
          .release();
    }

    final router = Router()
      ..post('/notes', (r) async {
        final marker = await r.readAsString();
        await insert(r, marker);
        await scalar(r.rls.executor, 'SELECT pg_sleep(${nap()})::text AS v');
        onEntered?.call();
        if (gate != null) await gate.future;
        ledger.intendedCommit.add(marker);
        return Response.created(body: marker);
      })
      ..get('/notes', (r) async {
        final rows = await column(
            r.rls.executor, 'SELECT body AS v FROM rls_stress.note');
        return Response.ok(body: jsonEncode(rows));
      })
      ..get('/notes/stream', (r) {
        final exec = r.rls.executor;
        Stream<List<int>> rows() async* {
          for (var i = 0; i < 3; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 3));
            final v = await scalar(exec,
                "SELECT current_setting('app.tenant_id', true) || ';' || pg_backend_pid() AS v");
            yield utf8.encode('$v|');
          }
        }

        return Response(200, body: rows());
      })
      ..get('/notes/stream-slow', (r) {
        final exec = r.rls.executor;
        var cleanupStarted = false;
        r.addCleanupHook(() => cleanupStarted =
            true); // LIFO: runs before the transaction's own hook
        Stream<List<int>> rows() async* {
          for (var i = 0; i < 6; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 3));
            if (cleanupStarted) ledger.queryAfterCleanup++;
            try {
              await scalar(exec, 'SELECT 1::text AS v');
            } on Object catch (e) {
              ledger.streamQueryErrors
                  .add('step $i (cleanupStarted=$cleanupStarted): $e');
              return;
            }
            yield utf8.encode('step$i|');
          }
        }

        return Response(200, body: rows());
      })
      ..post('/notes/then-409', (r) async {
        await insert(r, 'ghost');
        ledger.ghostAttempts++;
        return Response(409, body: 'conflict');
      })
      ..post('/notes/then-throw', (r) async {
        await insert(r, 'ghost');
        ledger.throwsReached++;
        throw StateError('intentional failure after insert');
      });

    final withTenant = Pipeline()
        .add(authenticate())
        .add(rlsTransaction(
          pool: pool,
          tenantResolver: (r) => r.context.getOrNull<_Principal>()?.tenantId,
          onUnresolved: (_) => Response(401, body: 'no tenant'),
        ))
        .addHandler(router.handler);

    // Outside the middleware on purpose: autocommit, to observe the session.
    Future<String> sessionView() => withPostgresConnection(
        pool,
        (exec) => scalar(exec,
            "SELECT pg_backend_pid()::text || ':' || coalesce(current_setting('app.tenant_id', true), '') AS v"));
    final publicRouter = Router()
      ..get('/session/tenant',
          (r) async => Response.ok(body: await sessionView()))
      ..get('/session/probe', (r) async {
        // Holds a connection until every connection of the pool is held, so
        // the probes provably land on distinct backends.
        return Response.ok(
            body: await withPostgresConnection(pool, (exec) async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (pool.borrowed < maxSize && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          return scalar(exec,
              "SELECT pg_backend_pid()::text || ':' || coalesce(current_setting('app.tenant_id', true), '') AS v");
        }));
      });

    final server = await BackendServer.bind(
      handler: (request) => request.uri.path.startsWith('/session')
          ? publicRouter.handler(request)
          : withTenant(request),
      address: InternetAddress.loopbackIPv4,
      port: 0,
      onError: (error, stack, request) => reported.add(error),
    );
    return Harness._(pool, server, ledger, reported,
        Uri.parse('http://127.0.0.1:${server.port}'));
  }
}

// ---------------------------------------------------------------- load

enum Kind { write, read, stream, then409, thenThrow, sessionTenant, noToken }

enum Cancel { none, beforeSend, duringHandler, duringStream, afterResponse }

final class Intent {
  final Kind kind;
  final int tenant;
  final int seq;
  final Cancel cancel;
  final int delayMs;
  const Intent(this.kind, this.tenant, this.seq, this.cancel, this.delayMs);
  String get marker => 't$tenant:$seq';
}

/// Deterministic list of intents from [seed].
List<Intent> buildIntents(int n, int seed) {
  final rng = Random(seed);
  int pickTenant() {
    final x = rng.nextInt(100);
    return x < 70 ? 0 : 1 + (x - 70) ~/ 10;
  }

  Kind pickKind() {
    final x = rng.nextInt(100);
    if (x < 40) return Kind.write;
    if (x < 70) return Kind.read;
    if (x < 80) return Kind.stream;
    if (x < 85) return Kind.then409;
    if (x < 90) return Kind.thenThrow;
    if (x < 95) return Kind.sessionTenant;
    return Kind.noToken;
  }

  final out = <Intent>[];
  for (var i = 0; i < n; i++) {
    final kind = pickKind();
    var cancel = Cancel.none;
    if (rng.nextInt(100) < 10 &&
        kind != Kind.sessionTenant &&
        kind != Kind.noToken) {
      cancel = Cancel.values[1 + rng.nextInt(4)];
      if (cancel == Cancel.duringStream && kind != Kind.stream) {
        cancel = Cancel.duringHandler;
      }
    }
    // STRESS_NO_STREAM_CANCEL=1 turns off client aborts on streams (diagnosis).
    if (kind == Kind.stream &&
        Platform.environment['STRESS_NO_STREAM_CANCEL'] == '1') {
      cancel = Cancel.none;
    }
    out.add(Intent(kind, pickTenant(), i, cancel, rng.nextInt(40)));
  }
  return out;
}

final class LoadResult {
  final confirmed = <String>{};
  final cancelledWrites = <String>{};
  final status = <String, int>{};
  final violations = <String>[];
  int cancelled = 0;
  void count(String k) => status[k] = (status[k] ?? 0) + 1;
}

/// Runs [intents] with [users] virtual users against [h].
Future<LoadResult> runLoad(Harness h, List<Intent> intents, int users,
    {required bool allow503}) async {
  final res = LoadResult();
  final shared = HttpClient()..maxConnectionsPerHost = users;
  var next = 0;

  Future<void> one(Intent it) async {
    final path = switch (it.kind) {
      Kind.write => '/notes',
      Kind.read || Kind.noToken => '/notes',
      Kind.stream => '/notes/stream',
      Kind.then409 => '/notes/then-409',
      Kind.thenThrow => '/notes/then-throw',
      Kind.sessionTenant => '/session/tenant',
    };
    final method = switch (it.kind) {
      Kind.write || Kind.then409 || Kind.thenThrow => 'POST',
      _ => 'GET',
    };
    final client = it.cancel == Cancel.none ? shared : HttpClient();
    try {
      final req = await client.openUrl(method, h.base.resolve(path));
      if (it.kind != Kind.noToken && it.kind != Kind.sessionTenant) {
        req.headers.set('authorization', 'Bearer ${tokenOf(it.tenant)}');
      }
      if (it.kind == Kind.write) req.write(it.marker);
      if (it.cancel == Cancel.beforeSend) {
        client.close(force: true);
        res.cancelled++;
        if (it.kind == Kind.write) res.cancelledWrites.add(it.marker);
        return;
      }
      final done = req.close();
      if (it.cancel == Cancel.duringHandler) {
        await Future<void>.delayed(Duration(milliseconds: it.delayMs));
        client.close(force: true);
        unawaited(done.then<void>((_) {}, onError: (_) {}));
        res.cancelled++;
        if (it.kind == Kind.write) res.cancelledWrites.add(it.marker);
        return;
      }
      final resp = await done.timeout(const Duration(seconds: 30));
      if (it.cancel == Cancel.afterResponse) {
        client.close(force: true);
        res.cancelled++;
        if (it.kind == Kind.write) res.cancelledWrites.add(it.marker);
        return;
      }
      if (it.cancel == Cancel.duringStream) {
        await resp.first.timeout(const Duration(seconds: 30));
        client.close(force: true);
        res.cancelled++;
        return;
      }
      final body = await utf8.decoder.bind(resp).join();
      res.count('${resp.statusCode}');
      _check(it, resp.statusCode, body, res, allow503);
    } on Object catch (e) {
      if (it.cancel == Cancel.none) {
        res.violations
            .add('${it.kind} t${it.tenant} #${it.seq}: client error $e');
      }
    } finally {
      if (it.cancel != Cancel.none) client.close(force: true);
    }
  }

  Future<void> user() async {
    while (next < intents.length) {
      await one(intents[next++]);
    }
  }

  await Future.wait([for (var u = 0; u < users; u++) user()]);
  shared.close(force: true);
  return res;
}

void _check(Intent it, int status, String body, LoadResult res, bool allow503) {
  void bad(String why) => res.violations.add(
      '${it.kind} t${it.tenant} #${it.seq}: $why (status $status, body "$body")');
  if (status == 503 &&
      allow503 &&
      it.kind != Kind.noToken &&
      it.kind != Kind.sessionTenant) {
    return;
  }
  // The public route has no 503 mapping: an exhausted pool is a plain 500 there.
  if (allow503 && it.kind == Kind.sessionTenant && status == 500) return;
  switch (it.kind) {
    case Kind.write:
      if (status == 201 && body == it.marker) {
        res.confirmed.add(it.marker);
      } else {
        bad('expected 201 echoing ${it.marker}');
      }
    case Kind.read:
      if (status != 200) return bad('expected 200');
      final rows = (jsonDecode(body) as List<dynamic>).cast<String>();
      for (final r in rows) {
        if (!r.startsWith('t${it.tenant}:')) bad('row of another tenant: $r');
      }
    case Kind.stream:
      if (status != 200) return bad('expected 200');
      final chunks = body.split('|').where((c) => c.isNotEmpty);
      if (chunks.length != 3) bad('expected 3 chunks');
      for (final c in chunks) {
        if (!c.startsWith('${tenantIds[it.tenant]};')) {
          bad('chunk of another tenant: $c');
        }
      }
    case Kind.then409:
      if (status != 409) bad('expected 409');
    case Kind.thenThrow:
      if (status != 500) bad('expected 500');
    case Kind.sessionTenant:
      if (status != 200 || !body.endsWith(':')) bad('session leaked a tenant');
    case Kind.noToken:
      if (status != 401) bad('expected 401');
  }
}
