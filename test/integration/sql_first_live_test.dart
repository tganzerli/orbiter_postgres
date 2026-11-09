/// SQL-first queries against PostgreSQL at localhost:5432 (database `teste`,
/// superuser `postgres`; see the README, "Tests"): `@name` placeholders and
/// inferred parameters on a pooled connection, inside `withTransaction` and
/// on `RlsTransaction.executor`.
///
/// Skips when the native library is not built or Postgres is unreachable.
library;

import 'dart:typed_data';

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _table = 'orbiter_sql_first_live';

final class _Row {
  final int id;
  final String name;
  final bool active;
  const _Row(this.id, this.name, this.active);

  static _Row fromRow(PostgresResultRow r) =>
      _Row(r['id']! as int, r['name']! as String, r['active']! as bool);
}

void main() {
  PostgresConnectionPool? pool;
  String? skipReason;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
        connInfo: _connInfo,
        minSize: 1,
        maxSize: 2,
        acquireTimeout: const Duration(seconds: 5),
      ));
      await p.start();
      pool = p;
      await withPostgresConnection<void>(p, (exec) async {
        (await exec.execute('DROP TABLE IF EXISTS $_table')).release();
        (await exec.execute('''
          CREATE TABLE $_table (
            id int8 PRIMARY KEY,
            org int4 NOT NULL,
            name text NOT NULL,
            active bool NOT NULL,
            ref uuid,
            note text,
            seen timestamptz,
            blob bytea
          )''')).release();
      });
    } on Object catch (e) {
      skipReason =
          'Postgres or native library unavailable ($e) — start PostgreSQL at localhost:5432';
    }
  });

  tearDownAll(() async {
    final p = pool;
    if (p == null) return;
    await withPostgresConnection<void>(p, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS $_table')).release();
    });
    await p.close();
  });

  Future<T> onPool<T>(Future<T> Function(PostgresQueryExecutorContract) f) =>
      withPostgresConnection(pool!, f);

  group('SQL-first (live)', () {
    setUp(() async {
      if (skipReason != null) return;
      await onPool((exec) async {
        (await exec.execute('TRUNCATE $_table')).release();
      });
    });

    test('insert with inferred types, then query, queryFirst and scalar',
        () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final seen = DateTime.utc(2026, 11, 9, 12, 30);
      await onPool((exec) async {
        for (final (id, name, active) in [
          (1, 'ana', true),
          (2, 'bia', false),
          (3, 'caio', true),
        ]) {
          await exec.query(
            'INSERT INTO $_table (id, org, name, active, seen, blob) '
            'VALUES (@id, @org, @name, @active, @seen, @blob) RETURNING id',
            (r) => r[0],
            params: {
              'id': id,
              'org': 10, // int8 parameter into an int4 column
              'name': name,
              'active': active,
              'seen': seen,
              'blob': Uint8List.fromList([id]),
            },
          );
        }

        final actives = await exec.query(
          'SELECT id, name, active FROM $_table '
          'WHERE org = @org AND active = @active ORDER BY id',
          _Row.fromRow,
          params: {'org': 10, 'active': true},
        );
        expect(actives.map((r) => r.name), ['ana', 'caio']);

        final first = await exec.queryFirst(
          'SELECT id, name, active FROM $_table WHERE id = @id',
          _Row.fromRow,
          params: {'id': 2},
        );
        expect(first?.name, 'bia');
        expect(first?.active, isFalse);

        expect(
          await exec.queryFirst(
              'SELECT id, name, active FROM $_table WHERE id = @id',
              _Row.fromRow,
              params: {'id': 99}),
          isNull,
        );

        expect(
          await exec.scalar<int>(
              'SELECT count(*) FROM $_table WHERE org = @org',
              params: {'org': 10}),
          3,
        );
        expect(
          await exec.scalar<DateTime>('SELECT seen FROM $_table WHERE id = @id',
              params: {'id': 1}),
          seen,
        );
      });
    });

    test('a repeated name binds once and is read at every use', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      await onPool((exec) async {
        expect(
          await exec
              .scalar<int>('SELECT @n::int8 + @n::int8 * 10', params: {'n': 3}),
          33,
        );
      });
    });

    test('null travels with OID 0 and the server infers its type', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      await onPool((exec) async {
        await exec.query(
          'INSERT INTO $_table (id, org, name, active, note) '
          'VALUES (@id, 1, @name, true, @note) RETURNING id',
          (r) => r[0],
          params: {'id': 50, 'name': 'nulo', 'note': null},
        );
        expect(
          await exec.scalar<int>(
            'SELECT id FROM $_table WHERE note IS NOT DISTINCT FROM @note',
            params: {'note': null},
          ),
          50,
        );
      });
    });

    test('a null with no context needs a cast', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      await expectLater(
        onPool((exec) =>
            exec.scalar<bool>('SELECT @x IS NULL', params: {'x': null})),
        throwsA(isA<QueryFailedException>()),
      );
      await onPool((exec) async {
        expect(
          await exec
              .scalar<bool>('SELECT @x::int8 IS NULL', params: {'x': null}),
          isTrue,
        );
      });
    });

    test('uuid column: a String needs a cast or an explicit Param', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      const ref = '00000000-0000-0000-0000-0000000000aa';
      await onPool((exec) async {
        await exec.query(
          'INSERT INTO $_table (id, org, name, active, ref) '
          'VALUES (@id, 1, @name, true, @ref::uuid) RETURNING id',
          (r) => r[0],
          params: {'id': 60, 'name': 'cast', 'ref': ref},
        );
        expect(
          await exec.scalar<int>('SELECT id FROM $_table WHERE ref = @ref',
              params: {'ref': const Param.uuid(ref)}),
          60,
        );
      });
      // Without a cast, text against uuid is refused by the server.
      await expectLater(
        onPool((exec) => exec.scalar<int>(
            'SELECT id FROM $_table WHERE ref = @ref',
            params: {'ref': ref})),
        throwsA(isA<QueryFailedException>()),
      );
    });

    test('inside withTransaction: committed and rolled back', () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      await withTransaction<void>(pool!, (exec) async {
        await exec.query(
          'INSERT INTO $_table (id, org, name, active) '
          'VALUES (@id, 1, @name, true) RETURNING id',
          (r) => r[0],
          params: {'id': 70, 'name': 'tx'},
        );
      });
      await expectLater(
        withTransaction<void>(pool!, (exec) async {
          await exec.query(
            'INSERT INTO $_table (id, org, name, active) '
            'VALUES (@id, 1, @name, true) RETURNING id',
            (r) => r[0],
            params: {'id': 71, 'name': 'rolled back'},
          );
          throw StateError('abort');
        }),
        throwsStateError,
      );
      await onPool((exec) async {
        expect(
          await exec.query(
              'SELECT id FROM $_table WHERE id IN (@a, @b)', (r) => r[0],
              params: {'a': 70, 'b': 71}),
          [70],
        );
      });
    });

    test('on RlsTransaction.executor, with the tenant setting visible',
        () async {
      if (skipReason != null) return markTestSkipped(skipReason!);
      final seen = await withTenantTransaction(pool!, 'tenant-x', (tx) {
        return tx.executor.scalar<String>(
          "SELECT current_setting('app.tenant_id', true) || @suffix",
          params: {'suffix': '!'},
        );
      });
      expect(seen, 'tenant-x!');
    });
  });
}
