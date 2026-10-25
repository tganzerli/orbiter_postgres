/// RLS middleware against PostgreSQL at localhost:5432 (database `teste`,
/// superuser `postgres`; see the README, "Tests").
///
/// The application pool connects as `rls_mw_app`: not a superuser, not the
/// table owner, no BYPASSRLS, over a table with FORCE ROW LEVEL SECURITY. The
/// tenant comes from a stand-in authentication middleware (never from the
/// body, query or an unauthenticated header) and reaches the database only
/// through the middleware under test.
///
/// Creates schema `rls_mw` and roles `rls_mw_owner`/`rls_mw_app`; do not run two
/// instances at once. Skips when Postgres or the native library is missing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

const _adminConn =
    'host=localhost port=5432 dbname=teste user=postgres password=123';
const _appConn =
    'host=localhost port=5432 dbname=teste user=rls_mw_app password=app';

const _tenantA = '11111111-1111-1111-1111-111111111111';
const _tenantB = '22222222-2222-2222-2222-222222222222';
const _tokens = {'token-a': _tenantA, 'token-b': _tenantB};

final class Principal {
  final String tenantId;
  const Principal(this.tenantId);
}

const _fixture = [
  'DROP SCHEMA IF EXISTS rls_mw CASCADE',
  'DROP ROLE IF EXISTS rls_mw_app',
  'DROP ROLE IF EXISTS rls_mw_owner',
  'CREATE ROLE rls_mw_owner NOLOGIN',
  "CREATE ROLE rls_mw_app LOGIN PASSWORD 'app' NOSUPERUSER NOBYPASSRLS",
  'CREATE SCHEMA rls_mw AUTHORIZATION rls_mw_owner',
  'CREATE TABLE rls_mw.note (id serial PRIMARY KEY, tenant_id uuid NOT NULL, body text NOT NULL)',
  'ALTER TABLE rls_mw.note OWNER TO rls_mw_owner',
  'ALTER TABLE rls_mw.note ENABLE ROW LEVEL SECURITY',
  'ALTER TABLE rls_mw.note FORCE ROW LEVEL SECURITY',
  '''CREATE POLICY tenant_isolation ON rls_mw.note
     USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)
     WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid)''',
  'GRANT USAGE ON SCHEMA rls_mw TO rls_mw_app',
  'GRANT SELECT, INSERT, UPDATE, DELETE ON rls_mw.note TO rls_mw_app',
  'GRANT USAGE, SELECT ON SEQUENCE rls_mw.note_id_seq TO rls_mw_app',
];

Future<List<String>> column(
  PostgresQueryExecutorContract exec,
  String sql,
) async {
  final rs = await exec.execute(sql);
  try {
    return [for (var i = 0; i < rs.rowCount; i++) rs.row(i).getString('v')!];
  } finally {
    rs.release();
  }
}

Future<void> expectPoolFree(PostgresConnectionPool pool) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (pool.borrowed != 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(pool.borrowed, 0, reason: 'a connection leaked from the pool');
}

void main() {
  PostgresConnectionPool? admin;
  String? skipReason;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
        connInfo: _adminConn,
        minSize: 1,
        maxSize: 1,
        acquireTimeout: const Duration(seconds: 5),
      ));
      await p.start();
      await withPostgresConnection<void>(p, (exec) async {
        for (final sql in _fixture) {
          (await exec.execute(sql)).release();
        }
      });
      admin = p;
    } on Object catch (e) {
      skipReason =
          'Postgres or native library unavailable ($e); start PostgreSQL at localhost:5432';
    }
  });

  tearDownAll(() async {
    final p = admin;
    if (p != null) {
      await withPostgresConnection<void>(p, (exec) async {
        (await exec.execute('DROP SCHEMA IF EXISTS rls_mw CASCADE')).release();
      });
      await p.close();
    }
  });

  void liveGroup(String name,
      {required int maxSize,
      String? sessionReset = 'DISCARD ALL',
      Duration acquireTimeout = const Duration(seconds: 5)}) {
    group(name, () {
      late PostgresConnectionPool pool;
      late BackendServer server;
      late HttpClient client;
      late Uri base;
      final reported = <Object>[];

      Future<void> truncate() =>
          withPostgresConnection<void>(admin!, (exec) async {
            (await exec.execute('TRUNCATE rls_mw.note')).release();
          });

      setUp(() async {
        if (skipReason != null) return;
        await truncate();
        reported.clear();
        pool = PostgresConnectionPool(PoolConfig(
          connInfo: _appConn,
          minSize: 1,
          maxSize: maxSize,
          acquireTimeout: acquireTimeout,
          sessionResetQuery: sessionReset,
        ));
        await pool.start();

        // Stand-in for authentication: resolves a token into a Principal.
        InterceptorFunction authenticate() => (request, next) {
              final header = request.headers['authorization']?.first;
              final tenant = header == null
                  ? null
                  : _tokens[header.replaceFirst('Bearer ', '')];
              if (tenant != null) {
                request.context.set<Principal>(Principal(tenant));
              }
              return next(request);
            };

        final router = Router()
          ..post('/notes', (request) async {
            final tx = request.rls;
            final body = await request.readAsString();
            (await tx.executor.execute(
              r'INSERT INTO rls_mw.note (tenant_id, body) VALUES ($1::uuid, $2)',
              params: [Param.text(tx.tenantId), Param.text(body)],
            ))
                .release();
            return Response.created(body: 'ok');
          })
          ..get('/notes', (request) async {
            final rows = await column(request.rls.executor,
                'SELECT body AS v FROM rls_mw.note ORDER BY id');
            return Response.ok(body: jsonEncode(rows));
          })
          ..post('/notes/then-throw', (request) async {
            (await request.rls.executor.execute(
              r"INSERT INTO rls_mw.note (tenant_id, body) VALUES ($1::uuid, 'ghost')",
              params: [Param.text(request.rls.tenantId)],
            ))
                .release();
            throw StateError('failure after insert');
          })
          ..post('/notes/then-409', (request) async {
            (await request.rls.executor.execute(
              r"INSERT INTO rls_mw.note (tenant_id, body) VALUES ($1::uuid, 'ghost')",
              params: [Param.text(request.rls.tenantId)],
            ))
                .release();
            return Response(409, body: 'conflict');
          })
          ..get('/notes/stream', (request) {
            final exec = request.rls.executor;
            Stream<List<int>> rows() async* {
              for (var i = 0; i < 3; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
                final v = await column(exec, 'SELECT ($i + 1)::text AS v');
                yield utf8.encode('${v.single};');
              }
            }

            return Response(200, body: rows());
          })
          ..get('/slow', (request) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return Response.ok(body: 'slow done');
          });

        final withTenant = Pipeline()
            .add(authenticate())
            .add(rlsTransaction(
              pool: pool,
              tenantResolver: (r) => r.context.getOrNull<Principal>()?.tenantId,
              onUnresolved: (_) => Response(401, body: 'no tenant'),
            ))
            .addHandler(router.handler);

        // Outside the middleware on purpose: autocommit, to observe the session.
        final publicRouter = Router()
          ..get('/session/tenant', (request) async {
            final v = await withPostgresConnection(
                pool,
                (exec) => column(exec,
                    "SELECT coalesce(current_setting('app.tenant_id', true), '') AS v"));
            return Response.ok(body: v.single);
          })
          ..get('/session/count', (request) async {
            final v = await withPostgresConnection(
                pool,
                (exec) => column(
                    exec, 'SELECT count(*)::text AS v FROM rls_mw.note'));
            return Response.ok(body: v.single);
          })
          ..post('/session/insert', (request) async {
            try {
              await withPostgresConnection<void>(pool, (exec) async {
                (await exec.execute(
                        "INSERT INTO rls_mw.note (tenant_id, body) VALUES ('$_tenantA', 'no-context')"))
                    .release();
              });
              return Response.ok(body: 'inserted');
            } on QueryFailedException catch (e) {
              return Response(403, body: '${e.serverMessage}');
            }
          });

        server = await BackendServer.bind(
          handler: (request) => request.uri.path.startsWith('/session')
              ? publicRouter.handler(request)
              : withTenant(request),
          address: InternetAddress.loopbackIPv4,
          port: 0,
          onError: (error, stackTrace, request) => reported.add(error),
        );
        client = HttpClient();
        base = Uri.parse('http://127.0.0.1:${server.port}');
      });

      tearDown(() async {
        if (skipReason != null) return;
        client.close(force: true);
        await server.close(force: true);
        await pool.close();
      });

      void liveTest(String description, Future<void> Function() body) {
        test(description, () async {
          if (skipReason != null) {
            markTestSkipped(skipReason!);
            return;
          }
          await body();
        });
      }

      Future<(int, String)> send(String method, String path,
          {String? token, String? body}) async {
        final req = await client.openUrl(method, base.resolve(path));
        if (token != null) req.headers.set('authorization', 'Bearer $token');
        if (body != null) req.write(body);
        final res = await req.close().timeout(const Duration(seconds: 15));
        final text = await utf8.decoder.bind(res).join();
        return (res.statusCode, text);
      }

      Future<List<String>> notes(String token) async {
        final (status, text) = await send('GET', '/notes', token: token);
        expect(status, 200);
        return (jsonDecode(text) as List<dynamic>).cast<String>();
      }

      liveTest(
          '1. without the middleware context the policy denies reads and writes',
          () async {
        await send('POST', '/notes', token: 'token-a', body: 'seed');
        final (_, count) = await send('GET', '/session/count');
        expect(count, '0',
            reason: 'no tenant set: the forced policy must hide the row');
        final (status, message) = await send('POST', '/session/insert');
        expect(status, 403);
        expect(message, contains('row-level security'));
        await expectPoolFree(pool);
      });

      liveTest('2. each tenant sees only its own rows', () async {
        for (var i = 0; i < 2; i++) {
          await send('POST', '/notes', token: 'token-a', body: 'a$i');
        }
        for (var i = 0; i < 3; i++) {
          await send('POST', '/notes', token: 'token-b', body: 'b$i');
        }
        expect(await notes('token-a'), ['a0', 'a1']);
        expect(await notes('token-b'), ['b0', 'b1', 'b2']);
        final total = await withPostgresConnection(admin!,
            (e) => column(e, 'SELECT count(*)::text AS v FROM rls_mw.note'));
        expect(total.single, '5');
        await expectPoolFree(pool);
      });

      liveTest(
          '3/4. concurrent tenants never see each other (pool of $maxSize)',
          () async {
        await Future.wait([
          for (var i = 0; i < 20; i++)
            send('POST', '/notes',
                token: i.isEven ? 'token-a' : 'token-b', body: 'n$i'),
        ]);
        final reads = await Future.wait([
          for (var i = 0; i < 40; i++) notes(i.isEven ? 'token-a' : 'token-b'),
        ]);
        for (var i = 0; i < reads.length; i++) {
          final expected = [
            for (var n = i.isEven ? 0 : 1; n < 20; n += 2) 'n$n'
          ];
          expect(reads[i], unorderedEquals(expected), reason: 'read $i');
        }
        await expectPoolFree(pool);
      });

      liveTest('5. a handler that throws after an insert leaves no row',
          () async {
        final (status, _) =
            await send('POST', '/notes/then-throw', token: 'token-a');
        expect(status, 500);
        expect(await notes('token-a'), isEmpty);
        await expectPoolFree(pool);
      });

      liveTest('6. a 409 response after an insert rolls back', () async {
        final (status, _) =
            await send('POST', '/notes/then-409', token: 'token-a');
        expect(status, 409);
        expect(await notes('token-a'), isEmpty);
        await expectPoolFree(pool);
      });

      liveTest(
          '7. a client that leaves during the handler still frees the connection',
          () async {
        final leaving = HttpClient();
        final req = await leaving.getUrl(base.resolve('/slow'));
        req.headers.set('authorization', 'Bearer token-a');
        unawaited(req.close().then<void>((_) {}, onError: (_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        leaving.close(force: true);

        expect(await notes('token-b'), isEmpty);
        await expectPoolFree(pool);
      });

      liveTest(
          '8. a streamed body keeps the transaction until the last byte, then commits',
          () async {
        final (status, body) =
            await send('GET', '/notes/stream', token: 'token-a');
        expect(status, 200);
        expect(body, '1;2;3;');
        await expectPoolFree(pool);
      });

      liveTest('10. a request without tenant never borrows a connection',
          () async {
        final (status, _) = await send('GET', '/notes');
        expect(status, 401);
        expect(pool.borrowed, 0);
      });

      liveTest('11. the tenant does not leak into the session after a request',
          () async {
        await send('POST', '/notes', token: 'token-a', body: 'x');
        await send('POST', '/notes/then-throw', token: 'token-b');
        await send('GET', '/notes/stream', token: 'token-a');
        for (var i = 0; i < 5; i++) {
          final (_, tenant) = await send('GET', '/session/tenant');
          expect(tenant, isEmpty,
              reason: 'tenant leaked into a later borrower');
        }
        await expectPoolFree(pool);
        // Only the deliberate handler failure is reported; the middleware itself
        // (commit, rollback, hook) reported nothing.
        expect(reported.whereType<RlsException>(), isEmpty);
        expect(reported.whereType<StateError>(), hasLength(1));
      });

      // Repository mode: the same transaction, opened by the caller.
      Future<void> insertAs(String tenant, String body) =>
          withTenantTransaction(pool, tenant, (tx) async {
            (await tx.executor.execute(
              r'INSERT INTO rls_mw.note (tenant_id, body) VALUES ($1::uuid, $2)',
              params: [Param.text(tx.tenantId), Param.text(body)],
            ))
                .release();
          });

      Future<List<String>> bodiesAs(String tenant) => withTenantTransaction(
          pool,
          tenant,
          (tx) => column(
              tx.executor, 'SELECT body AS v FROM rls_mw.note ORDER BY id'));

      liveTest('12. repository mode: each tenant sees only its own rows',
          () async {
        await insertAs(_tenantA, 'a0');
        await insertAs(_tenantB, 'b0');
        await insertAs(_tenantA, 'a1');
        expect(await bodiesAs(_tenantA), ['a0', 'a1']);
        expect(await bodiesAs(_tenantB), ['b0']);
        expect(await notes('token-b'), ['b0'],
            reason: 'the two modes share the policy');
        await expectPoolFree(pool);
      });

      liveTest(
          '13. repository mode: a throwing body and setRollbackOnly roll back',
          () async {
        await expectLater(
          withTenantTransaction(pool, _tenantA, (tx) async {
            (await tx.executor.execute(
              r"INSERT INTO rls_mw.note (tenant_id, body) VALUES ($1::uuid, 'ghost')",
              params: [Param.text(tx.tenantId)],
            ))
                .release();
            throw StateError('failure after insert');
          }),
          throwsA(isA<StateError>()),
        );
        final kept = await withTenantTransaction(pool, _tenantA, (tx) async {
          (await tx.executor.execute(
            r"INSERT INTO rls_mw.note (tenant_id, body) VALUES ($1::uuid, 'dry')",
            params: [Param.text(tx.tenantId)],
          ))
              .release();
          tx.setRollbackOnly();
          return 'returned';
        });
        expect(kept, 'returned');
        expect(await bodiesAs(_tenantA), isEmpty);
        await expectPoolFree(pool);
      });

      liveTest(
          '14. repository mode: local settings hold inside the transaction only',
          () async {
        final inside = await withTenantTransaction(
          pool,
          _tenantB,
          (tx) => column(
              tx.executor,
              "SELECT current_setting('app.tenant_id') || '|' || "
              "current_setting('app.correlation_id') AS v"),
          localSettings: {'app.correlation_id': 'corr-7'},
        );
        expect(inside, ['$_tenantB|corr-7']);
        for (var i = 0; i < 3; i++) {
          final after = await withPostgresConnection(
              pool,
              (exec) => column(
                  exec,
                  "SELECT coalesce(current_setting('app.correlation_id', true), '') "
                  "|| '|' || coalesce(current_setting('app.tenant_id', true), '') AS v"));
          expect(after, ['|'],
              reason: 'a local setting leaked into the session');
        }
        await expectPoolFree(pool);
      });
    });
  }

  liveGroup('pool of 4', maxSize: 4);
  liveGroup('pool of 1', maxSize: 1);
  // Without the pool reset, transaction-local set_config alone must not leak.
  liveGroup('pool of 1, no session reset', maxSize: 1, sessionReset: null);

  group('9. exhausted pool', () {
    test(
        'answers 503 with Retry-After while another request holds the only connection',
        () async {
      if (skipReason != null) {
        markTestSkipped(skipReason!);
        return;
      }
      final pool = PostgresConnectionPool(PoolConfig(
        connInfo: _appConn,
        minSize: 1,
        maxSize: 1,
        acquireTimeout: const Duration(milliseconds: 200),
      ));
      await pool.start();
      final server = await BackendServer.bind(
        handler: Pipeline()
            .add(rlsTransaction(
          pool: pool,
          tenantResolver: (_) => _tenantA,
          onUnresolved: (_) => Response(401),
        ))
            .addHandler((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return Response.ok(body: 'held');
        }),
        address: InternetAddress.loopbackIPv4,
        port: 0,
        onError: (error, stackTrace, request) {},
      );
      final client = HttpClient();
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');
      try {
        final first = client.getUrl(uri).then((r) => r.close());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final second = await (await client.getUrl(uri)).close();
        expect(second.statusCode, 503);
        expect(second.headers.value('retry-after'), '1');
        await second.drain<void>();
        expect((await first).statusCode, 200);
        await expectPoolFree(pool);
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await pool.close();
      }
    });
  });

  group('15. exhausted pool, repository mode', () {
    test(
        'propagates PoolExhaustedException while another call holds the only connection',
        () async {
      if (skipReason != null) {
        markTestSkipped(skipReason!);
        return;
      }
      final pool = PostgresConnectionPool(PoolConfig(
        connInfo: _appConn,
        minSize: 1,
        maxSize: 1,
        acquireTimeout: const Duration(milliseconds: 200),
      ));
      await pool.start();
      try {
        final first = withTenantTransaction(pool, _tenantA, (tx) async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return 'held';
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await expectLater(
          withTenantTransaction(pool, _tenantB, (tx) async => 'second'),
          throwsA(isA<PoolExhaustedException>()),
        );
        expect(await first, 'held');
        await expectPoolFree(pool);
      } finally {
        await pool.close();
      }
    });
  });
}
