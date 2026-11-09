import 'dart:convert';
import 'dart:io';

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:orbiter_postgres/src/migrate/crc32.dart';
import 'package:test/test.dart';

void main() {
  group('crc32', () {
    test('matches the standard check value', () {
      expect(crc32(ascii.encode('123456789')), 0xCBF43926);
      expect(crc32(const []), 0);
    });

    test('script checksum ignores CRLF vs LF', () {
      expect(scriptChecksum('a;\r\nb;\r\n'), scriptChecksum('a;\nb;\n'));
      expect(scriptChecksum('a;\nb;'), isNot(scriptChecksum('a;\nc;')));
    });
  });

  group('SqlScript', () {
    test('version comes from the numeric prefix', () {
      expect(SqlScript('001_init.sql', '').version, 1);
      expect(SqlScript('10_index.sql', '').version, 10);
      expect(SqlScript('0_zero.sql', '').name, '0_zero.sql');
    });

    test('badly named files are rejected', () {
      for (final name in [
        'init.sql',
        '001init.sql',
        '001_init.txt',
        'v1_init.sql',
        '_init.sql',
        '001_.sq',
        '99999999999999999999_too_big.sql',
      ]) {
        expect(
          () => SqlScript(name, ''),
          throwsA(isA<MigrationException>()),
          reason: name,
        );
      }
    });

    test('no-transaction marker on the first non-blank line', () {
      expect(SqlScript('1_a.sql', 'CREATE TABLE t ();').transactional, isTrue);
      expect(
        SqlScript('1_a.sql', '-- orbiter:no-transaction\nCREATE INDEX ...')
            .transactional,
        isFalse,
      );
      expect(
        SqlScript('1_a.sql', '\n  \n  -- orbiter:no-transaction  \nX')
            .transactional,
        isFalse,
      );
      // Not the first non-blank line, or not exactly the marker.
      expect(
        SqlScript('1_a.sql', '-- note\n-- orbiter:no-transaction\nX')
            .transactional,
        isTrue,
      );
      expect(
        SqlScript('1_a.sql', '-- orbiter:no-transaction please\nX')
            .transactional,
        isTrue,
      );
    });

    test('sortScripts orders numerically and rejects duplicate versions', () {
      final sorted = SqlScript.sortScripts([
        SqlScript('10_c.sql', ''),
        SqlScript('2_b.sql', ''),
        SqlScript('001_a.sql', ''),
      ]);
      expect(sorted.map((s) => s.name), ['001_a.sql', '2_b.sql', '10_c.sql']);
      expect(
        () => SqlScript.sortScripts(
            [SqlScript('1_a.sql', ''), SqlScript('001_b.sql', '')]),
        throwsA(isA<MigrationException>()),
      );
    });

    group('loadDirectory', () {
      late Directory dir;
      setUp(() async => dir = await Directory.systemTemp.createTemp('mig'));
      tearDown(() async => dir.delete(recursive: true));

      test('reads only *.sql at the top level, sorted, as UTF-8', () async {
        await File('${dir.path}/10_b.sql').writeAsString('SELECT 10;');
        await File('${dir.path}/2_a.sql').writeAsString("SELECT 'ação';");
        await File('${dir.path}/README.md').writeAsString('ignored');
        await Directory('${dir.path}/nested').create();
        await File('${dir.path}/nested/3_x.sql').writeAsString('ignored');
        final scripts = await SqlScript.loadDirectory(dir.path);
        expect(scripts.map((s) => s.name), ['2_a.sql', '10_b.sql']);
        expect(scripts.first.sql, "SELECT 'ação';");
      });

      test('a symbolic link to a .sql file is read', () async {
        final target = File('${dir.path}/target.txt')
          ..writeAsStringSync('SELECT 1;');
        await Link('${dir.path}/1_linked.sql').create(target.path);
        final scripts = await SqlScript.loadDirectory(dir.path);
        expect(scripts.single.name, '1_linked.sql');
        expect(scripts.single.sql, 'SELECT 1;');
      });

      test('a dangling symbolic link fails the load', () async {
        await Link('${dir.path}/1_gone.sql').create('${dir.path}/missing.txt');
        await expectLater(
          SqlScript.loadDirectory(dir.path),
          throwsA(isA<MigrationException>()),
        );
      });

      test('a badly named .sql file fails the load', () async {
        await File('${dir.path}/init.sql').writeAsString('');
        await expectLater(
          SqlScript.loadDirectory(dir.path),
          throwsA(isA<MigrationException>()),
        );
      });
    });
  });
}
