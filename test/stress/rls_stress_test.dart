@Tags(['stress'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

import 'rls_shutdown_tests.dart';
import 'stress_support.dart';

/// Stress suite for the RLS middleware. Integrity invariants only, no timing.
/// Run: `dart test -t stress` (needs the native library and the dev Postgres;
/// it SKIPS silently otherwise, so check the printed executed/skipped line).
void main() {
  PostgresConnectionPool? admin;
  String? skipReason;
  final params = StressParams();
  var executed = 0, skipped = 0;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
          connInfo: adminConn,
          minSize: 1,
          maxSize: 1,
          acquireTimeout: const Duration(seconds: 5)));
      await p.start();
      await withPostgresConnection<void>(p, (exec) async {
        for (final sql in fixture) {
          (await exec.execute(sql)).release();
        }
      });
      admin = p;
    } on Object catch (e) {
      skipReason = 'Postgres or native library unavailable ($e)';
    }
  });

  tearDownAll(() async {
    final p = admin;
    if (p != null) {
      await withPostgresConnection<void>(p, (exec) async {
        (await exec.execute('DROP SCHEMA IF EXISTS rls_stress CASCADE'))
            .release();
      });
      await p.close();
    }
    // ignore: avoid_print
    print('[stress] seed=${params.seed} requests=${params.requests} '
        'users=${params.users} executed=$executed skipped=$skipped');
  });

  Future<void> settle(PostgresConnectionPool pool) async {
    final end = DateTime.now().add(const Duration(seconds: 3));
    while (pool.borrowed != 0 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void groupTest(String name,
      {required int maxSize,
      String? reset = 'DISCARD ALL',
      Duration acquireTimeout = const Duration(seconds: 5),
      bool allow503 = false}) {
    test(name, () async {
      if (skipReason != null) {
        skipped++;
        markTestSkipped(skipReason!);
        return;
      }
      executed++;
      await withPostgresConnection<void>(admin!, (exec) async {
        (await exec.execute('TRUNCATE rls_stress.note')).release();
      });
      final h = await Harness.start(
          maxSize: maxSize,
          reset: reset,
          acquireTimeout: acquireTimeout,
          seed: params.seed);
      final sampler = Sampler(h.pool)..start();
      final res = await runLoad(
          h, buildIntents(params.requests, params.seed), params.users,
          allow503: allow503);
      await settle(h.pool);
      sampler.stop();

      // Session hygiene: 2 rounds of maxSize probes on provably distinct backends.
      final probeClient = HttpClient();
      final probeFailures = <String>[];
      for (var round = 0; round < 2; round++) {
        final answers = await Future.wait([
          for (var i = 0; i < maxSize; i++)
            probeClient
                .getUrl(h.base.resolve('/session/probe'))
                .then((r) => r.close())
                .then((r) => utf8.decoder.bind(r).join())
        ]);
        final pids = answers.map((a) => a.split(':').first).toSet();
        if (pids.length != maxSize) {
          probeFailures.add(
              'round $round: ${pids.length} distinct backends of $maxSize');
        }
        for (final a in answers) {
          if (!a.endsWith(':')) {
            probeFailures.add('round $round: tenant left in the session: $a');
          }
        }
      }
      probeClient.close(force: true);
      await settle(h.pool);

      final bodies = await withPostgresConnection(admin!,
          (exec) => column(exec, 'SELECT body AS v FROM rls_stress.note'));
      await h.server.close();
      final borrowed = h.pool.borrowed,
          pending = h.pool.pending,
          idle = h.pool.idle;
      await h.pool.close();

      final observed = bodies.where((b) => b != 'ghost').toSet();
      // ignore: avoid_print
      print('[stress] $name seed=${params.seed} status=${res.status} '
          'cancelled=${res.cancelled} maxBorrowed=${sampler.maxBorrowed} '
          'maxPending=${sampler.maxPending} maxPendingRun=${sampler.maxRun} '
          'rows=${bodies.length}');

      expect(res.violations, isEmpty, reason: 'seed=${params.seed}');
      expect(bodies.where((b) => b == 'ghost'), isEmpty,
          reason: 'rolled-back rows survived (seed=${params.seed})');
      expect(observed, equals(h.ledger.intendedCommit),
          reason: 'rows in the database differ from what the server committed');
      expect(res.confirmed.difference(observed), isEmpty,
          reason: 'a confirmed write is missing');
      expect(observed.difference(res.confirmed.union(res.cancelledWrites)),
          isEmpty,
          reason: 'a row nobody confirmed or cancelled');
      expect(borrowed, 0);
      expect(pending, 0);
      expect(idle, maxSize);
      expect(sampler.maxBorrowed, lessThanOrEqualTo(maxSize));
      expect(probeFailures, isEmpty);
      if (!allow503) {
        expect(sampler.maxRun, greaterThanOrEqualTo(20),
            reason:
                'the load did not keep a queue; the test proves less than intended');
        expect(res.status['503'] ?? 0, 0);
      } else {
        expect(res.status['503'] ?? 0, greaterThan(0));
        expect(res.status['201'] ?? 0, greaterThan(0));
      }
      expect(h.reported.whereType<RlsException>(), isEmpty);
      expect(h.reported.whereType<StateError>().length, h.ledger.throwsReached,
          reason:
              'StateError reported != failures the handlers raised on purpose');
      final strangers = h.reported.where((e) =>
          e is! StateError &&
          e is! SocketException &&
          e is! HttpException &&
          !(allow503 && e is PoolExhaustedException));
      expect(strangers, isEmpty,
          reason: 'unexpected reported errors: $strangers');
    });
  }

  /// Repository mode under the same load: no HTTP, each caller opens its own
  /// transaction. A third of the calls throw and a sixth set rollback-only,
  /// after inserting, so their rows must never survive.
  void repositoryTest(String name, {required int maxSize, String? reset}) {
    test(name, () async {
      if (skipReason != null) {
        skipped++;
        markTestSkipped(skipReason!);
        return;
      }
      executed++;
      await withPostgresConnection<void>(admin!, (exec) async {
        (await exec.execute('TRUNCATE rls_stress.note')).release();
      });
      final pool = PostgresConnectionPool(PoolConfig(
          connInfo: appConn,
          minSize: 1,
          maxSize: maxSize,
          acquireTimeout: const Duration(seconds: 10),
          sessionResetQuery: reset));
      await pool.start();
      final sampler = Sampler(pool)..start();
      final rng = Random(params.seed);
      final committed = <String>{};
      final violations = <String>[];
      var next = 0, thrown = 0;

      Future<void> call(int seq) async {
        final k = rng.nextInt(10) < 4 ? 0 : 1 + rng.nextInt(3);
        final roll = rng.nextInt(6);
        final delay = rng.nextInt(4);
        final marker = 't$k:$seq';
        try {
          await withTenantTransaction(pool, tenantIds[k], (tx) async {
            (await tx.executor.execute(
              r'INSERT INTO rls_stress.note (tenant_id, body) VALUES ($1::uuid, $2)',
              params: [Param.text(tx.tenantId), Param.text(marker)],
            ))
                .release();
            await Future<void>.delayed(Duration(milliseconds: delay));
            final seen = await column(
                tx.executor, 'SELECT body AS v FROM rls_stress.note');
            for (final b in seen) {
              if (!b.startsWith('t$k:')) violations.add('$marker saw $b');
            }
            final local = await scalar(
                tx.executor,
                "SELECT current_setting('app.tenant_id') || '|' || "
                "current_setting('app.correlation_id') AS v");
            if (local != '${tenantIds[k]}|$marker') {
              violations.add('$marker read local settings $local');
            }
            if (roll < 2) throw StateError(marker);
            if (roll == 2) tx.setRollbackOnly();
          }, localSettings: {'app.correlation_id': marker});
          if (roll > 2) committed.add(marker);
        } on StateError catch (e) {
          if (e.message != marker) rethrow;
          thrown++;
        }
      }

      await Future.wait([
        for (var u = 0; u < params.users; u++)
          () async {
            while (next < params.requests) {
              await call(next++);
            }
          }()
      ]);
      await settle(pool);
      sampler.stop();

      // Session hygiene: maxSize probes held at once, so each lands on a
      // distinct backend.
      final hygiene = <String>[];
      for (var round = 0; round < 2; round++) {
        final answers = await Future.wait([
          for (var i = 0; i < maxSize; i++)
            withPostgresConnection(
                pool,
                (exec) => scalar(
                    exec,
                    "SELECT pg_backend_pid()::text || ':' || "
                    "coalesce(current_setting('app.tenant_id', true), '') || '|' || "
                    "coalesce(current_setting('app.correlation_id', true), '') AS v "
                    'FROM pg_sleep(0.05)'))
        ]);
        if (answers.map((a) => a.split(':').first).toSet().length != maxSize) {
          hygiene.add('round $round: probes shared a backend');
        }
        hygiene.addAll(answers.where((a) => !a.endsWith(':|')));
      }
      final bodies = await withPostgresConnection(admin!,
          (exec) => column(exec, 'SELECT body AS v FROM rls_stress.note'));
      final borrowed = pool.borrowed, pending = pool.pending;
      await pool.close();

      // ignore: avoid_print
      print('[stress] $name seed=${params.seed} committed=${committed.length} '
          'thrown=$thrown maxBorrowed=${sampler.maxBorrowed} '
          'maxPending=${sampler.maxPending} rows=${bodies.length}');

      expect(violations, isEmpty, reason: 'seed=${params.seed}');
      expect(bodies.toSet(), equals(committed),
          reason: 'rows in the database differ from the committed calls');
      expect(bodies, hasLength(committed.length));
      expect(thrown, greaterThan(0));
      expect(hygiene, isEmpty, reason: 'a setting leaked into the session');
      expect(borrowed, 0);
      expect(pending, 0);
      expect(sampler.maxBorrowed, lessThanOrEqualTo(maxSize));
      expect(sampler.maxPending, greaterThan(0),
          reason: 'the load did not queue; the test proves less than intended');
    });
  }

  groupTest('G1 pool 1, DISCARD ALL', maxSize: 1);
  groupTest('G2 pool 4, DISCARD ALL', maxSize: 4);
  groupTest('G3 pool 2, no session reset', maxSize: 2, reset: null);
  registerShutdownTests(() => admin, () => skipReason);
  groupTest('G4 pool 2, 100 ms acquire timeout',
      maxSize: 2,
      acquireTimeout: const Duration(milliseconds: 100),
      allow503: true);
  repositoryTest('R1 repository mode, pool 2, DISCARD ALL',
      maxSize: 2, reset: 'DISCARD ALL');
  repositoryTest('R2 repository mode, pool 2, no session reset', maxSize: 2);
}
