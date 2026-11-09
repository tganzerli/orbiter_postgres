import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

final class _FakeRow implements PostgresResultRow {
  final List<Object?> values;
  _FakeRow(this.values);

  @override
  Object? operator [](Object key) => values[key as int];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeResultSet implements PostgresResultSet {
  final List<List<Object?>> data;
  int releases = 0;
  _FakeResultSet(this.data);

  @override
  int get rowCount => data.length;

  @override
  PostgresResultRow row(int i) => _FakeRow(data[i]);

  @override
  Iterable<PostgresResultRow> get rows => data.map(_FakeRow.new);

  @override
  void release() => releases++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeExec implements PostgresQueryExecutorContract {
  final List<List<Object?>> rows;
  final sql = <String>[];
  final params = <List<Param>?>[];
  final sets = <_FakeResultSet>[];
  _FakeExec([this.rows = const []]);

  @override
  Future<PostgresResultSet> execute(
    String sql, {
    List<Param>? params,
    bool binaryResult = false,
  }) async {
    this.sql.add(sql);
    this.params.add(params);
    final rs = _FakeResultSet(rows);
    sets.add(rs);
    return rs;
  }
}

void main() {
  setUp(NamedSql.clearCache);

  group('query', () {
    test('rewrites, binds in order, maps every row and releases', () async {
      final exec = _FakeExec([
        [1, 'a'],
        [2, 'b'],
      ]);
      final out = await exec.query(
        'SELECT id, name FROM t WHERE org = @org AND active = @active',
        (r) => '${r[0]}:${r[1]}',
        params: {'active': true, 'org': 7},
      );
      expect(out, ['1:a', '2:b']);
      expect(exec.sql.single,
          r'SELECT id, name FROM t WHERE org = $1 AND active = $2');
      final bound = exec.params.single!;
      expect(bound.map((p) => p.oid),
          [Param.int8(7).oid, const Param.bool(true).oid]);
      expect(exec.sets.single.releases, 1);
    });

    test('without placeholders and params uses the simple path', () async {
      final exec = _FakeExec([
        [1],
      ]);
      await exec.query('SELECT 1', (r) => r[0]);
      expect(exec.sql.single, 'SELECT 1');
      expect(exec.params.single, isNull);
    });

    test('releases the result set when the mapper throws', () async {
      final exec = _FakeExec([
        [1],
      ]);
      await expectLater(
        exec.query<int>('SELECT @x', (r) => throw StateError('boom'),
            params: {'x': 1}),
        throwsStateError,
      );
      expect(exec.sets.single.releases, 1);
    });

    test('a missing value throws before anything is sent', () async {
      final exec = _FakeExec();
      await expectLater(
        exec.query('SELECT @a, @b', (r) => r, params: {'a': 1}),
        throwsArgumentError,
      );
      expect(exec.sql, isEmpty);
    });
  });

  group('queryFirst', () {
    test('maps only the first row', () async {
      final exec = _FakeExec([
        ['first'],
        ['second'],
      ]);
      expect(await exec.queryFirst('SELECT n FROM t', (r) => r[0]), 'first');
      expect(exec.sets.single.releases, 1);
    });

    test('returns null on no rows and still releases', () async {
      final exec = _FakeExec();
      expect(
        await exec.queryFirst('SELECT n FROM t WHERE id = @id', (r) => r[0],
            params: {'id': 1}),
        isNull,
      );
      expect(exec.sets.single.releases, 1);
    });
  });

  group('scalar', () {
    test('returns column 0 of row 0', () async {
      final exec = _FakeExec([
        [42, 'ignored'],
      ]);
      expect(await exec.scalar<int>('SELECT count(*), 1 FROM t'), 42);
      expect(exec.sets.single.releases, 1);
    });

    test('null when there is no row', () async {
      expect(await _FakeExec().scalar<int>('SELECT 1 WHERE false'), isNull);
    });

    test('wrong type throws TypeError and still releases', () async {
      final exec = _FakeExec([
        ['text'],
      ]);
      await expectLater(
          exec.scalar<int>('SELECT 1'), throwsA(isA<TypeError>()));
      expect(exec.sets.single.releases, 1);
    });
  });

  test('namedStmt returns the positional record', () {
    final (sql, params) = namedStmt('DELETE FROM t WHERE id = @id', {'id': 3});
    expect(sql, r'DELETE FROM t WHERE id = $1');
    expect(params.single.oid, Param.int8(3).oid);
  });

  test('the rewrite is cached across calls', () async {
    final exec = _FakeExec();
    await exec.query('SELECT @x', (r) => r, params: {'x': 1});
    await exec.query('SELECT @x', (r) => r, params: {'x': 2});
    expect(NamedSql.cacheSize, 1);
  });
}
