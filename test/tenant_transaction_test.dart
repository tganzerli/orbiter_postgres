import 'dart:convert';

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

List<String> _values(List<Param> params) =>
    [for (final p in params) utf8.decode(p.encode()!)];

void main() {
  late _FakeUow uow;
  late int opened;

  UnitOfWork<PostgresQueryExecutorContract> factory() {
    opened++;
    return uow;
  }

  setUp(() {
    uow = _FakeUow();
    opened = 0;
  });

  group('withTenantTransactionOn', () {
    test('commits and returns the value of the body', () async {
      final result = await withTenantTransactionOn(factory, 't1', (tx) async {
        expect(tx.tenantId, 't1');
        await tx.executor.execute('SELECT 1');
        return 42;
      });
      expect(result, 42);
      expect(uow.calls, ['begin', 'commit']);
      expect(uow.executed.first, r'SELECT set_config($1, $2, true)');
      expect(_values(uow.executedParams.first), ['app.tenant_id', 't1']);
      expect(uow.executed, hasLength(2));
      expect(uow.isActive, isFalse);
    });

    for (final tenant in [null, '']) {
      test('tenant ${tenant ?? 'null'} throws before the pool', () async {
        await expectLater(
          withTenantTransactionOn(factory, tenant, (tx) async => 0),
          throwsA(isA<TenantRequiredException>()),
        );
        expect(opened, 0);
      });
    }

    test('pool exhausted propagates, no statement runs', () async {
      uow.beginError = PoolExhaustedException(const Duration(milliseconds: 5));
      var ran = false;
      await expectLater(
        withTenantTransactionOn(factory, 't1', (tx) async => ran = true),
        throwsA(isA<PoolExhaustedException>()),
      );
      expect(ran, isFalse);
      expect(uow.executed, isEmpty);
    });

    test('body throws: rollback and rethrow', () async {
      final error = StateError('boom');
      await expectLater(
        withTenantTransactionOn(factory, 't1', (tx) async => throw error),
        throwsA(same(error)),
      );
      expect(uow.calls, ['begin', 'close']);
      expect(uow.isActive, isFalse);
    });

    test('setRollbackOnly: rollback and the value is returned', () async {
      final result = await withTenantTransactionOn(factory, 't1', (tx) async {
        tx.setRollbackOnly();
        return 'kept';
      });
      expect(result, 'kept');
      expect(uow.calls, ['begin', 'close']);
      expect(uow.isActive, isFalse);
    });

    test('COMMIT fails: RlsCommitException after rollback', () async {
      uow.commitError = StateError('commit');
      await expectLater(
        withTenantTransactionOn(factory, 't1', (tx) async => 0),
        throwsA(
          isA<RlsCommitException>()
              .having((e) => e.tenantId, 'tenantId', 't1')
              .having((e) => e.afterResponse, 'afterResponse', isFalse)
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(uow.isActive, isFalse);
    });

    test('context fails: RlsContextException, body never runs', () async {
      uow.executeError = StateError('set_config');
      var ran = false;
      await expectLater(
        withTenantTransactionOn(factory, 't1', (tx) async => ran = true),
        throwsA(isA<RlsContextException>()),
      );
      expect(ran, isFalse);
      expect(uow.calls, ['begin', 'close']);
    });

    test('local settings go in the same statement, in order', () async {
      await withTenantTransactionOn(
        factory,
        't1',
        (tx) async => 0,
        settingName: 'app.org',
        localSettings: {'app.correlation_id': 'c-9', 'app.user_id': 'u-3'},
      );
      expect(
        uow.executed.single,
        r'SELECT set_config($1, $2, true), set_config($3, $4, true), '
        r'set_config($5, $6, true)',
      );
      expect(_values(uow.executedParams.single), [
        'app.org',
        't1',
        'app.correlation_id',
        'c-9',
        'app.user_id',
        'u-3',
      ]);
    });

    for (final name in ['', 'correlation_id', 'app.tenant_id']) {
      test('local setting "$name" is rejected before the pool', () async {
        await expectLater(
          withTenantTransactionOn(
            factory,
            't1',
            (tx) async => 0,
            localSettings: {name: 'x'},
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(opened, 0);
      });
    }
  });
}
