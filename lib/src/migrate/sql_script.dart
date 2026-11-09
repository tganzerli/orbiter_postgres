import 'dart:convert';
import 'dart:io';

import 'crc32.dart';
import 'migration_exception.dart';

/// One `.sql` file applied by `Migrator` or `Seeder`.
///
/// The file name is `<version>_<description>.sql`, where `<version>` is a
/// non-negative integer: `001_init.sql`, `2_users.sql`, `10_index.sql`.
/// Scripts run in numeric order of `version` (so `2_` before `10_`), each
/// at most once. The whole file goes to the server in one call, so
/// functions, `DO $$ … $$` blocks and `;` inside literals need no special
/// care.
///
/// A script runs inside a transaction together with its bookkeeping row,
/// unless its first non-blank line is `-- orbiter:no-transaction`
/// (surrounding spaces ignored), which is needed by `CREATE INDEX
/// CONCURRENTLY` and a few other statements. Such
/// a script can leave partial effects when it fails halfway. A transactional
/// script must not contain `COMMIT`, `ROLLBACK` or `END`: the run detects
/// it and stops.
final class SqlScript {
  /// Numeric prefix of the file name; the ordering and identity key.
  final int version;

  /// File name, for example `002_users.sql`.
  final String name;

  /// The SQL sent to the server, unchanged.
  final String sql;

  /// Whether the script runs inside a transaction.
  final bool transactional;

  /// CRC-32 of [sql] with `\r\n` normalised to `\n`.
  final int checksum;

  SqlScript._(this.version, this.name, this.sql, this.transactional)
      : checksum = scriptChecksum(sql);

  /// Builds a script from a file name and its SQL; use this to embed the
  /// scripts in the program (for example in an AOT binary without the
  /// `.sql` files next to it).
  ///
  /// Throws [MigrationException] when [fileName] does not follow
  /// `<version>_<description>.sql`.
  factory SqlScript(String fileName, String sql) {
    final m = _namePattern.firstMatch(fileName);
    final version = m == null ? null : int.tryParse(m.group(1)!);
    if (version == null) {
      throw MigrationException(
        'script name must be <version>_<description>.sql with a version that '
        'fits in 64 bits, got "$fileName"',
      );
    }
    return SqlScript._(
      version,
      fileName,
      sql,
      !_hasNoTransactionMarker(sql),
    );
  }

  /// Reads every `*.sql` file directly inside [path] (not recursive;
  /// symbolic links to files are followed), as UTF-8, and returns them
  /// sorted by [version].
  ///
  /// Throws [MigrationException] on a badly named file, a dangling link or
  /// two files with the same version.
  static Future<List<SqlScript>> loadDirectory(String path) async {
    final scripts = <SqlScript>[];
    await for (final entity in Directory(path).list()) {
      final fileName = entity.uri.pathSegments.last;
      if (!fileName.endsWith('.sql')) continue;
      // Links are followed, so a Link here does not resolve to a file.
      if (entity is Link) {
        throw MigrationException(
          'symbolic link "$fileName" does not point to a readable file',
          script: fileName,
        );
      }
      if (entity is! File) continue;
      scripts.add(
        SqlScript(fileName, await entity.readAsString(encoding: utf8)),
      );
    }
    return sortScripts(scripts);
  }

  /// Returns [scripts] sorted by [version]; throws [MigrationException] when
  /// two share a version.
  static List<SqlScript> sortScripts(Iterable<SqlScript> scripts) {
    final sorted = scripts.toList()
      ..sort((a, b) => a.version.compareTo(b.version));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].version == sorted[i - 1].version) {
        throw MigrationException(
          'two scripts with version ${sorted[i].version}: '
          '"${sorted[i - 1].name}" and "${sorted[i].name}"',
        );
      }
    }
    return sorted;
  }

  @override
  String toString() => 'SqlScript($name)';
}

final RegExp _namePattern = RegExp(r'^(\d+)_[^/\\]+\.sql$');

const String _noTransactionMarker = '-- orbiter:no-transaction';

bool _hasNoTransactionMarker(String sql) {
  for (final line in const LineSplitter().convert(sql)) {
    final t = line.trim();
    if (t.isEmpty) continue;
    return t == _noTransactionMarker;
  }
  return false;
}
