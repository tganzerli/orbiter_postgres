import 'dart:async';

import 'package:orbiter/orbiter.dart';
import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

final class _FakeResultSet implements PostgresResultSet {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeUow
    implements
        UnitOfWork<PostgresQueryExecutorContract>,
        PostgresQueryExecutorContract {
  final calls = <String>[];
  final executed = <String>[];
  final executedParams = <List<Param>>[];
  Object? beginError;
  Object? executeError;
  Object? commitError;
  bool _active = false;

  @override
  bool get isActive => _active;

  @override
  PostgresQueryExecutorContract get executor {
    if (!_active) throw TransactionStateError('no active transaction');
    return this;
  }

  @override
  Future<void> begin() async {
    calls.add('begin');
    final error = beginError;
    if (error != null) throw error;
    _active = true;
  }

  @override
  Future<PostgresResultSet> execute(
    String sql, {
    List<Param> params = const [],
    bool binaryResult = false,
  }) async {
    final error = executeError;
    if (error != null) throw error;
    executed.add(sql);
    executedParams.add(params);
    return _FakeResultSet();
  }

  @override
  Future<void> commit() async {
    calls.add('commit');
    final error = commitError;
    _active = false;
    if (error != null) throw error;
  }

  @override
  Future<void> rollback() async {
    calls.add('rollback');
    _active = false;
  }

  @override
  Future<void> close() async {
    if (!_active) return;
    calls.add('close');
    _active = false;
  }
}

Request _request() =>
    Request(method: 'GET', uri: Uri.parse('http://localhost/'));

Response _unresolved(Request _) => Response(401);

void main() {
  group('rlsTransaction', () {
    late _FakeUow uow;

    setUp(() {
      uow = _FakeUow();
    });

    InterceptorFunction build({
      String? tenant = 'tenant-a',
      CommitPredicate? shouldCommit,
      _FakeUow? unit,
    }) {
      final u = unit ?? uow;
      return rlsTransactionOn(
        tenantResolver: (_) => tenant,
        onUnresolved: _unresolved,
        shouldCommit: shouldCommit ?? commitOnSuccess,
        unitOfWorkFactory: () => u,
      );
    }

    test('applies the tenant as a bound set_config, first in the transaction',
        () async {
      final request = _request();
      await build()(request, (r) {
        expect(r.rls.tenantId, 'tenant-a');
        return Response.ok(body: 'x');
      });

      expect(uow.executed, [r'SELECT set_config($1, $2, true)']);
      expect(uow.executedParams.single, hasLength(2));
      expect(uow.calls, ['begin', 'commit']);
    });

    test('buffered 200 commits before returning and the hook is a no-op',
        () async {
      final request = _request();
      final response = await build()(request, (_) => Response.ok(body: 'x'));

      expect(response.statusCode, 200);
      expect(uow.calls, ['begin', 'commit']);
      await request.runCleanupHooks();
      expect(uow.calls, ['begin', 'commit']);
    });

    test('status >= 400 rolls back and does not commit', () async {
      final request = _request();
      await build()(request, (_) => Response(409, body: 'conflict'));

      expect(uow.calls, ['begin', 'close']);
      expect(uow.calls, isNot(contains('commit')));
    });

    test('custom shouldCommit is honored', () async {
      final request = _request();
      await build(shouldCommit: (r) => r.statusCode == 409)(
        request,
        (_) => Response(409),
      );
      expect(uow.calls, ['begin', 'commit']);
    });

    test('setRollbackOnly forces a rollback on a 200', () async {
      final request = _request();
      await build()(request, (r) {
        r.rls.setRollbackOnly();
        return Response.ok();
      });
      expect(uow.calls, ['begin', 'close']);
    });

    test('a throwing handler rolls back before the error propagates', () async {
      final request = _request();
      await expectLater(
        build()(request, (_) => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(uow.calls, ['begin', 'close']);
    });

    test('streamed 200 defers the commit to the cleanup hook', () async {
      final request = _request();
      final response = await build()(
        request,
        (_) => Response(200, body: const Stream<List<int>>.empty()),
      );

      expect(response.statusCode, 200);
      expect(uow.calls, ['begin']);
      expect(uow.isActive, isTrue);

      await request.runCleanupHooks();
      expect(uow.calls, ['begin', 'commit']);
    });

    test('streamed 409 rolls back in the cleanup hook', () async {
      final request = _request();
      await build()(
        request,
        (_) => Response(409, body: const Stream<List<int>>.empty()),
      );
      expect(uow.calls, ['begin']);
      await request.runCleanupHooks();
      expect(uow.calls, ['begin', 'close']);
    });

    test('a failing deferred commit reaches the hook error callback', () async {
      uow.commitError = StateError('commit failed');
      final request = _request();
      await build()(
        request,
        (_) => Response(200, body: const Stream<List<int>>.empty()),
      );

      final reported = <Object>[];
      await request.runCleanupHooks(onError: (e, s) => reported.add(e));

      expect(reported.single, isA<RlsCommitException>());
      expect((reported.single as RlsCommitException).afterResponse, isTrue);
    });

    test('a failing commit on a buffered body becomes an error, not a 200',
        () async {
      uow.commitError = StateError('commit failed');
      final request = _request();
      await expectLater(
        build()(request, (_) => Response.ok(body: 'x')),
        throwsA(
          isA<RlsCommitException>()
              .having((e) => e.afterResponse, 'afterResponse', isFalse),
        ),
      );
    });

    for (final tenant in <String?>[null, '']) {
      test(
          'tenant ${tenant == null ? 'null' : 'empty'} short-circuits without a connection',
          () async {
        final request = _request();
        var nextCalled = false;
        final response = await build(tenant: tenant)(request, (_) {
          nextCalled = true;
          return Response.ok();
        });

        expect(response.statusCode, 401);
        expect(nextCalled, isFalse);
        expect(uow.calls, isEmpty);
      });
    }

    test('an exhausted pool answers 503 with Retry-After and registers no hook',
        () async {
      uow.beginError = PoolExhaustedException(const Duration(milliseconds: 5));
      final request = _request();
      final response = await build()(request, (_) => Response.ok());

      expect(response.statusCode, 503);
      expect(response.headers['retry-after'], ['1']);
      await request.runCleanupHooks();
      expect(uow.calls, ['begin']);
    });

    test('a set_config failure rolls back and raises RlsContextException',
        () async {
      uow.executeError = QueryFailedException('select', 'boom');
      final request = _request();
      await expectLater(
        build()(request, (_) => Response.ok()),
        throwsA(isA<RlsContextException>()),
      );
      expect(uow.calls, ['begin', 'close']);
    });

    test('the handler hook runs before the transaction safety net (LIFO)',
        () async {
      final order = <String>[];
      final request = _request();
      await build()(
        request,
        (r) {
          r.addCleanupHook(
              () => order.add('handler-hook-saw-active=${uow.isActive}'));
          return Response(200, body: const Stream<List<int>>.empty());
        },
      );

      await request.runCleanupHooks();
      expect(order, ['handler-hook-saw-active=true']);
      expect(uow.calls, ['begin', 'commit']);
    });

    test('the executor is unavailable after the transaction ended', () async {
      final request = _request();
      await build()(request, (_) => Response.ok());
      expect(() => request.rls.executor, throwsA(isA<TransactionStateError>()));
    });
  });
}
