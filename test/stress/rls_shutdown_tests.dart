import 'dart:async';
import 'dart:io';

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

import 'stress_support.dart';

/// Clean shutdown under load: server first, then pool, with requests in flight.
/// Registered by rls_stress_test.dart so both share one fixture and run in series.
void registerShutdownTests(
    PostgresConnectionPool? Function() admin, String? Function() skip) {
  group('shutdown', () {
    /// Fires [n] writes and returns when [entered] reached [until] and the queue is non-empty.
    Future<List<Future<int>>> fire(Harness h, HttpClient c, int n) async => [
          for (var i = 0; i < n; i++)
            c.postUrl(h.base.resolve('/notes')).then((r) {
              r.headers.set('authorization', 'Bearer ${tokenOf(0)}');
              r.write('t0:$i');
              return r.close();
            }).then((resp) async {
              await resp.drain<void>();
              return resp.statusCode;
            }).catchError((Object _) => -1)
        ];

    Future<void> until(bool Function() cond) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!cond() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cond(), isTrue, reason: 'condition not reached in 10 s');
    }

    Future<void> reset() =>
        withPostgresConnection<void>(admin()!, (exec) async {
          (await exec.execute('TRUNCATE rls_stress.note')).release();
        });

    test(
        'S1 server.close() with requests in flight, then pool.close(): nothing leaks',
        () async {
      if (skip() != null) {
        markTestSkipped(skip()!);
        return;
      }
      await reset();
      final gate = Completer<void>();
      var entered = 0;
      final h = await Harness.start(
          maxSize: 2,
          seed: StressParams().seed,
          gate: gate,
          onEntered: () => entered++);
      final client = HttpClient()..maxConnectionsPerHost = 16;
      final statuses = await fire(h, client, 8);
      await until(() => entered >= 2 && h.pool.pending > 0);

      final closing = h.server.close();
      gate.complete();
      await closing;

      expect(h.reported.whereType<TimeoutException>(), isEmpty);
      expect(h.pool.borrowed, 0,
          reason: 'a connection outlived server.close()');
      expect(h.server.inFlight, 0);
      expect(h.pool.pending, 0);
      await h.pool.close();
      await expectLater(h.pool.acquire(), throwsStateError);
      expect(await Future.wait(statuses), everyElement(201));
      final rows = await withPostgresConnection(admin()!,
          (exec) => column(exec, 'SELECT body AS v FROM rls_stress.note'));
      expect(rows.toSet(), equals(h.ledger.intendedCommit));
      expect(h.reported.whereType<RlsException>(), isEmpty);
      client.close(force: true);
    });

    test(
        'S2 drain timeout with a hung handler: reported, pool refuses to close until it returns',
        () async {
      if (skip() != null) {
        markTestSkipped(skip()!);
        return;
      }
      await reset();
      final gate = Completer<void>();
      var entered = 0;
      final h = await Harness.start(
          maxSize: 2,
          seed: StressParams().seed,
          gate: gate,
          onEntered: () => entered++);
      final client = HttpClient()..maxConnectionsPerHost = 16;
      final statuses = await fire(h, client, 6);
      await until(() => entered >= 2 && h.pool.pending > 0);

      await h.server
          .close(force: true, drainTimeout: const Duration(milliseconds: 200));
      expect(h.reported.whereType<TimeoutException>().length, 1);
      expect(h.pool.borrowed, 2,
          reason: 'the hung handlers still hold their connections');
      expect(h.server.inFlight, greaterThan(0));

      // Contract: close() with borrowed connections times out and stays armed.
      await expectLater(
          h.pool.close(timeout: const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()));

      gate.complete();
      await until(() => h.pool.borrowed == 0);
      await h.pool.close();
      expect(h.pool.nativePool, isNull);
      expect(h.reported.whereType<RlsException>(), isEmpty);
      await Future.wait(statuses);
      client.close(force: true);
    });

    test(
        'S3 client leaves before the first byte of a stream whose handler still has queries to run: none runs after the cleanup',
        () async {
      if (skip() != null) {
        markTestSkipped(skip()!);
        return;
      }
      await reset();
      final h = await Harness.start(maxSize: 1, seed: StressParams().seed);
      for (var i = 0; i < 20; i++) {
        final client = HttpClient();
        final req = await client.getUrl(h.base.resolve('/notes/stream-slow'));
        req.headers.set('authorization', 'Bearer ${tokenOf(0)}');
        unawaited(req.close().then<void>((_) {}, onError: (_) {}));
        // The client leaves before the server wrote anything: no write failure
        // gives the generator a safe point to stop.
        await Future<void>.delayed(Duration(milliseconds: i % 8));
        client.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await until(() => h.pool.borrowed == 0);
      await h.server.close();
      await h.pool.close();
      expect(h.ledger.streamQueryErrors, isEmpty);
      expect(h.ledger.queryAfterCleanup, 0,
          reason:
              'a stream generator queried after the framework began the cleanup');
      expect(h.reported.whereType<RlsException>(), isEmpty);
    });
  });
}
