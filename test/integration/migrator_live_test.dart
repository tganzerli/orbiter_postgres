/// Migrator and Seeder against PostgreSQL at localhost:5432 (database
/// `teste`, superuser `postgres`; see the README, "Tests"). Every object is
/// created in the schema `orbiter_mig_live`, dropped before and after.
///
/// Skips when the native library is not built or Postgres is unreachable.
library;

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _s = 'orbiter_mig_live';
const _table = '$_s.migrations';

void main() {
  PostgresConnectionPool? pool;
  String? skipReason;

  Future<T> onPool<T>(Future<T> Function(PostgresQueryExecutorContract) f) =>
      withPostgresConnection(pool!, f);

  Future<void> sql(String text) =>
      onPool((e) async => (await e.execute(text)).release());

  Future<List<int>> appliedVersions([String table = _table]) =>
      onPool((e) => e.query(
          'SELECT version FROM $table ORDER BY version', (r) => r[0]! as int));

  Future<bool> tableExists(String name) async =>
      (await onPool<bool?>((e) => e.scalar<bool>(
          'SELECT to_regclass(@n) IS NOT NULL',
          params: {'n': name}))) ??
      false;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
        connInfo: _connInfo,
        minSize: 1,
        maxSize: 3,
        acquireTimeout: const Duration(seconds: 10),
      ));
      await p.start();
      pool = p;
    } on Object catch (e) {
      skipReason =
          'Postgres or native library unavailable ($e) — start PostgreSQL at localhost:5432';
    }
  });

  tearDownAll(() async {
    if (pool == null) return;
    await sql('DROP SCHEMA IF EXISTS $_s CASCADE');
    await pool!.close();
  });

  setUp(() async {
    if (skipReason != null) return;
    await sql('DROP SCHEMA IF EXISTS $_s CASCADE');
    await sql('CREATE SCHEMA $_s');
  });

  test('applies functions, DO blocks and ; in literals; reruns are no-ops',
      () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    final scripts = [
      SqlScript('001_init.sql', '''
        CREATE TABLE $_s.item (id int8 PRIMARY KEY, label text NOT NULL);
        CREATE FUNCTION $_s.add_item(i int8, l text) RETURNS void
        LANGUAGE plpgsql AS \$fn\$
        BEGIN
          INSERT INTO $_s.item VALUES (i, l);
        END;
        \$fn\$;
      '''),
      SqlScript('002_do.sql', '''
        DO \$\$
        BEGIN
          PERFORM $_s.add_item(1, 'from do');
          PERFORM $_s.add_item(2, 'two');
        END
        \$\$;
      '''),
      SqlScript(
          '10_literal.sql', "INSERT INTO $_s.item VALUES (3, 'a; b; c');"),
    ];
    final migrator = Migrator(pool!, table: _table);
    final applied = await migrator.run(scripts);
    expect(applied.map((s) => s.name),
        ['001_init.sql', '002_do.sql', '10_literal.sql']);
    expect(await appliedVersions(), [1, 2, 10]);
    expect(
      await onPool((e) => e.query(
          'SELECT label FROM $_s.item ORDER BY id', (r) => r[0]! as String)),
      ['from do', 'two', 'a; b; c'],
    );

    expect(await migrator.run(scripts), isEmpty);
    expect(await appliedVersions(), [1, 2, 10]);
  });

  test('a failing script leaves nothing behind and stops the run', () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    final scripts = [
      SqlScript('1_ok.sql', 'CREATE TABLE $_s.ok (id int);'),
      SqlScript('2_bad.sql', '''
        CREATE TABLE $_s.half (id int);
        SELECT 1 / 0;
      '''),
      SqlScript('3_after.sql', 'CREATE TABLE $_s.after (id int);'),
    ];
    await expectLater(
      Migrator(pool!, table: _table).run(scripts),
      throwsA(isA<MigrationException>()
          .having((e) => e.script, 'script', '2_bad.sql')
          .having((e) => e.cause, 'cause', isA<QueryFailedException>())),
    );
    expect(await appliedVersions(), [1]);
    expect(await tableExists('$_s.ok'), isTrue);
    expect(await tableExists('$_s.half'), isFalse);
    expect(await tableExists('$_s.after'), isFalse);
  });

  test('a COMMIT inside a transactional script is detected and not recorded',
      () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    await expectLater(
      Migrator(pool!, table: _table).run([
        SqlScript('1_commits.sql', '''
          CREATE TABLE $_s.early (id int);
          COMMIT;
          CREATE TABLE $_s.late (id int);
        '''),
        SqlScript('2_after.sql', 'CREATE TABLE $_s.after2 (id int);'),
      ]),
      throwsA(isA<MigrationException>()
          .having((e) => e.script, 'script', '1_commits.sql')
          .having(
              (e) => e.message, 'message', contains('ended the transaction'))),
    );
    expect(await appliedVersions(), isEmpty);
    // Documented: after the COMMIT the server commits the rest of the file
    // in an implicit transaction, so the whole file took effect, unrecorded.
    expect(await tableExists('$_s.early'), isTrue);
    expect(await tableExists('$_s.late'), isTrue);
    expect(await tableExists('$_s.after2'), isFalse);
  });

  test('a script that commits and then fails reports partial application',
      () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    await expectLater(
      Migrator(pool!, table: _table).run([
        SqlScript('1_partial.sql', '''
          CREATE TABLE $_s.kept (id int);
          COMMIT;
          SELECT 1 / 0;
        '''),
      ]),
      throwsA(isA<MigrationException>()
          .having((e) => e.message, 'message', contains('committed'))),
    );
    expect(await appliedVersions(), isEmpty);
    expect(await tableExists('$_s.kept'), isTrue);
  });

  test('an edited applied script stops the run before anything runs', () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    final migrator = Migrator(pool!, table: _table);
    await migrator.run([SqlScript('1_a.sql', 'CREATE TABLE $_s.a (id int);')]);
    await expectLater(
      migrator.run([
        SqlScript('1_a.sql', 'CREATE TABLE $_s.a (id int, x int);'),
        SqlScript('2_b.sql', 'CREATE TABLE $_s.b (id int);'),
      ]),
      throwsA(isA<MigrationException>()
          .having((e) => e.message, 'message', contains('checksum'))),
    );
    expect(await appliedVersions(), [1]);
    expect(await tableExists('$_s.b'), isFalse);
  });

  test('an applied script missing from the set is refused', () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    final migrator = Migrator(pool!, table: _table);
    final a = SqlScript('1_a.sql', 'SELECT 1;');
    final b = SqlScript('2_b.sql', 'SELECT 2;');
    await migrator.run([a, b]);
    await expectLater(migrator.run([b]), throwsA(isA<MigrationException>()));
  });

  test('concurrent runs apply each script once and both finish', () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    final scripts = [
      SqlScript(
          '1_slow.sql', 'SELECT pg_sleep(0.3); CREATE TABLE $_s.c1 (id int);'),
      SqlScript('2_next.sql', 'CREATE TABLE $_s.c2 (id int);'),
      SqlScript('3_last.sql', 'CREATE TABLE $_s.c3 (id int);'),
    ];
    final results = await Future.wait([
      Migrator(pool!, table: _table).run(scripts),
      Migrator(pool!, table: _table).run(scripts),
    ]);
    final all = [for (final r in results) ...r.map((s) => s.version)]..sort();
    expect(all, [1, 2, 3], reason: 'each script applied by exactly one run');
    expect(await appliedVersions(), [1, 2, 3]);
  });

  test('the no-transaction marker lets CREATE INDEX CONCURRENTLY run',
      () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    final migrator = Migrator(pool!, table: _table);
    await migrator.run([SqlScript('1_t.sql', 'CREATE TABLE $_s.t (id int);')]);

    // Without the marker the server refuses it inside the transaction.
    await expectLater(
      migrator.run([
        SqlScript('1_t.sql', 'CREATE TABLE $_s.t (id int);'),
        SqlScript('2_idx.sql', 'CREATE INDEX CONCURRENTLY t_id ON $_s.t (id);'),
      ]),
      throwsA(isA<MigrationException>()),
    );
    expect(await appliedVersions(), [1]);

    final applied = await migrator.run([
      SqlScript('1_t.sql', 'CREATE TABLE $_s.t (id int);'),
      SqlScript('2_idx.sql',
          '-- orbiter:no-transaction\nCREATE INDEX CONCURRENTLY t_id ON $_s.t (id);'),
    ]);
    expect(applied.single.name, '2_idx.sql');
    expect(await tableExists('$_s.t_id'), isTrue);
  });

  test('Seeder keeps its own table, independent of migrations', () async {
    if (skipReason != null) return markTestSkipped(skipReason!);
    await Migrator(pool!, table: _table).run([
      SqlScript(
          '1_schema.sql', 'CREATE TABLE $_s.color (name text PRIMARY KEY);'),
    ]);
    const seeds = '$_s.seeds';
    final seeder = Seeder(pool!, table: seeds);
    final applied = await seeder.run([
      SqlScript('1_colors.sql',
          "INSERT INTO $_s.color VALUES ('red'), ('blue') ON CONFLICT DO NOTHING;"),
    ]);
    expect(applied, hasLength(1));
    expect(await seeder.run([applied.single]), isEmpty);
    expect(await appliedVersions(seeds), [1]);
    expect(await appliedVersions(), [1]);
    expect(
      await onPool((e) => e.scalar<int>('SELECT count(*) FROM $_s.color')),
      2,
    );
  });
}
