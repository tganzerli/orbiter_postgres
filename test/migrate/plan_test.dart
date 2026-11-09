import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:orbiter_postgres/src/migrate/script_runner.dart';
import 'package:test/test.dart';

void main() {
  final a = SqlScript('1_a.sql', 'SELECT 1;');
  final b = SqlScript('2_b.sql', 'SELECT 2;');
  final c = SqlScript('3_c.sql', 'SELECT 3;');

  AppliedScript rec(SqlScript s) => (name: s.name, checksum: s.checksum);

  test('nothing applied: everything is pending, in order', () {
    expect(planScripts({}, [a, b, c]), [a, b, c]);
  });

  test('applied scripts are skipped', () {
    expect(planScripts({1: rec(a), 2: rec(b)}, [a, b, c]), [c]);
    expect(planScripts({1: rec(a), 2: rec(b), 3: rec(c)}, [a, b, c]), isEmpty);
  });

  test('a pending version below the highest applied still runs', () {
    expect(planScripts({1: rec(a), 3: rec(c)}, [a, b, c]), [b]);
  });

  test('an applied script whose checksum changed is refused', () {
    final edited = SqlScript('2_b.sql', 'SELECT 22;');
    expect(
      () => planScripts({1: rec(a), 2: rec(b)}, [a, edited, c]),
      throwsA(isA<MigrationException>()
          .having((e) => e.script, 'script', '2_b.sql')
          .having((e) => e.message, 'message', contains('checksum'))),
    );
  });

  test('an applied script missing from the set is refused', () {
    expect(
      () => planScripts({1: rec(a), 2: rec(b)}, [a, c]),
      throwsA(isA<MigrationException>()
          .having((e) => e.message, 'message', contains('missing'))),
    );
  });

  test('table names are validated', () {
    for (final ok in ['orbiter_migrations', 'app.migrations', '_t1']) {
      expect(checkTableName(ok), ok);
    }
    for (final bad in ['Migrations', 'a-b', 'x; DROP TABLE y', 'a.b.c', '1t']) {
      expect(() => checkTableName(bad), throwsArgumentError, reason: bad);
    }
  });
}
