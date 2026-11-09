import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'migration_exception.dart';
import 'sql_script.dart';

/// A row of the bookkeeping table.
typedef AppliedScript = ({String name, int checksum});

final RegExp _tablePattern = RegExp(r'^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?$');

/// Validates [table] as a plain (optionally schema-qualified) lower-case
/// identifier, so it can be spliced into SQL.
String checkTableName(String table) {
  if (!_tablePattern.hasMatch(table)) {
    throw ArgumentError.value(
      table,
      'table',
      'must be a lower-case identifier, optionally schema-qualified',
    );
  }
  return table;
}

/// Decides which of [scripts] (sorted, distinct versions) still have to run
/// given what [applied] records, keyed by version.
///
/// Throws [MigrationException], before anything runs, when an applied
/// script changed (checksum differs) or is no longer in [scripts]. A pending
/// script with a version lower than the highest applied one is returned and
/// will run: that is what merging two branches with new scripts looks like.
List<SqlScript> planScripts(
  Map<int, AppliedScript> applied,
  List<SqlScript> scripts,
) {
  final byVersion = {for (final s in scripts) s.version: s};
  for (final MapEntry(key: version, value: row) in applied.entries) {
    final script = byVersion[version];
    if (script == null) {
      throw MigrationException(
        'version $version ("${row.name}") is applied but missing from the '
        'scripts given',
        script: row.name,
      );
    }
    if (script.checksum != row.checksum) {
      throw MigrationException(
        'version $version was applied with checksum ${row.checksum} and the '
        'file now has ${script.checksum}; an applied script must not change '
        '(add a new script instead)',
        script: script.name,
      );
    }
  }
  return [
    for (final s in scripts)
      if (!applied.containsKey(s.version)) s,
  ];
}

/// Applies the pending [scripts] on one connection of [pool], recording each
/// in [table]. Returns the scripts applied by this call.
///
/// A session advisory lock keyed on [table] serialises concurrent runs. It
/// is released explicitly on every exit; if the process dies, the server
/// releases it when the connection closes.
Future<List<SqlScript>> runScripts(
  PostgresConnectionPool pool,
  List<SqlScript> scripts, {
  required String table,
}) {
  checkTableName(table);
  final sorted = SqlScript.sortScripts(scripts);
  final lockKey = "hashtext('$table')";
  return withPostgresConnection(pool, (exec) async {
    await _run(exec, 'SELECT pg_advisory_lock($lockKey)');
    try {
      await _run(
        exec,
        'CREATE TABLE IF NOT EXISTS $table ('
        'version int8 PRIMARY KEY, '
        'name text NOT NULL, '
        'checksum int8 NOT NULL, '
        'applied_at timestamptz NOT NULL DEFAULT now())',
      );
      final applied = <int, AppliedScript>{};
      final rs =
          await exec.execute('SELECT version, name, checksum FROM $table');
      try {
        for (final row in rs.rows) {
          applied[row[0]! as int] =
              (name: row[1]! as String, checksum: row[2]! as int);
        }
      } finally {
        rs.release();
      }

      final done = <SqlScript>[];
      for (final script in planScripts(applied, sorted)) {
        await _apply(exec, script, table);
        done.add(script);
      }
      return done;
    } finally {
      try {
        await _run(exec, 'SELECT pg_advisory_unlock($lockKey)');
      } on Object {
        // Only reached when the connection is broken; the server ends that
        // session, and the lock with it. Rethrowing here would hide the
        // error that brought us to this finally.
      }
    }
  });
}

Future<void> _apply(
  PostgresQueryExecutorContract exec,
  SqlScript script,
  String table,
) async {
  final record = [
    Param.int8(script.version),
    Param.text(script.name),
    Param.int8(script.checksum),
  ];
  final insert =
      'INSERT INTO $table (version, name, checksum) VALUES (\$1, \$2, \$3)';
  if (!script.transactional) {
    try {
      await _run(exec, script.sql);
    } on Object catch (e) {
      throw MigrationException(
        'failed (no transaction: earlier statements of this script may '
        'have taken effect)',
        script: script.name,
        cause: e,
      );
    }
    try {
      (await exec.execute(insert, params: record)).release();
    } on Object catch (e) {
      throw MigrationException(
        'was applied but could not be recorded; it will run again on the next '
        'run unless recorded by hand',
        script: script.name,
        cause: e,
      );
    }
    return;
  }
  await _run(exec, 'BEGIN');
  int? xid;
  try {
    xid = await _txid(exec);
    await _run(exec, script.sql);
    // A COMMIT, ROLLBACK or END inside the file ends this transaction, and
    // with it the guarantee that file and row commit together: the next
    // txid_current() then starts a new transaction with another id.
    if (await _txid(exec) != xid) {
      throw MigrationException(
        'ended the transaction it runs in (COMMIT, ROLLBACK or END in the '
        'file); its statements most likely took effect, but the script was '
        'not recorded and will run again. Check the database, remove the '
        'transaction control, or mark the file with -- orbiter:no-transaction',
        script: script.name,
      );
    }
    (await exec.execute(insert, params: record)).release();
    await _run(exec, 'COMMIT');
  } on Object catch (e) {
    if (e is MigrationException) {
      await _rollback(exec);
      rethrow;
    }
    // Inside our failed transaction txid_current() errors (the transaction
    // is aborted). If it answers with another id, the file ended our
    // transaction before failing, so part of it is committed.
    var partial = false;
    if (xid != null) {
      try {
        partial = await _txid(exec) != xid;
      } on Object {
        // Aborted transaction (still ours) or broken connection.
      }
    }
    await _rollback(exec);
    throw MigrationException(
      partial
          ? 'failed after ending its own transaction (COMMIT, ROLLBACK or END '
              'in the file): statements before that point are committed and '
              'the script was not recorded'
          : 'failed and was rolled back',
      script: script.name,
      cause: e,
    );
  }
}

Future<void> _rollback(PostgresQueryExecutorContract exec) async {
  try {
    await _run(exec, 'ROLLBACK');
  } on Object {
    // Broken connection: the server already discarded the transaction.
  }
}

Future<int> _txid(PostgresQueryExecutorContract exec) async {
  final rs = await exec.execute('SELECT txid_current()');
  try {
    return rs.row(0)[0]! as int;
  } finally {
    rs.release();
  }
}

Future<void> _run(PostgresQueryExecutorContract exec, String sql) async {
  (await exec.execute(sql)).release();
}
