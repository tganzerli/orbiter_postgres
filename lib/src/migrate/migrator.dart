import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'script_runner.dart';
import 'sql_script.dart';

/// Applies schema migrations: `.sql` files run once each, in version order.
///
/// ```dart
/// final applied = await Migrator(pool).run(
///   await SqlScript.loadDirectory('migrations'),
/// );
/// ```
///
/// Before running anything, every script already recorded in [table] is
/// checked against the one given: a changed checksum or a missing script
/// throws `MigrationException`. Then each pending script runs in its own
/// transaction together with its row in [table]; a failure rolls that
/// script back and stops the run. Concurrent runs (several instances
/// starting at once) are serialised by an advisory lock, so each script is
/// applied once. There is no `down`: undo a change with a new script.
final class Migrator {
  /// Pool the run borrows one connection from.
  final PostgresConnectionPool pool;

  /// Bookkeeping table, created when missing. Lower-case identifier,
  /// optionally schema-qualified.
  final String table;

  Migrator(this.pool, {this.table = 'orbiter_migrations'}) {
    checkTableName(table);
  }

  /// Applies the pending [scripts]; returns the ones applied by this call,
  /// in order (empty when everything was already applied).
  Future<List<SqlScript>> run(List<SqlScript> scripts) =>
      runScripts(pool, scripts, table: table);
}

/// Applies seed data with the same rules as [Migrator], recorded in its own
/// table, so seeds and migrations version independently.
///
/// "Once" is per file: a seed is not re-applied after it ran, and editing an
/// applied seed is refused like an edited migration. Make the SQL itself
/// idempotent (`ON CONFLICT DO NOTHING`) when the same rows may already
/// exist.
final class Seeder {
  /// Pool the run borrows one connection from.
  final PostgresConnectionPool pool;

  /// Bookkeeping table, created when missing.
  final String table;

  Seeder(this.pool, {this.table = 'orbiter_seeds'}) {
    checkTableName(table);
  }

  /// Applies the pending [scripts]; returns the ones applied by this call.
  Future<List<SqlScript>> run(List<SqlScript> scripts) =>
      runScripts(pool, scripts, table: table);
}
