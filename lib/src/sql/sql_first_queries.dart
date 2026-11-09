import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'named_sql.dart';

/// SQL-first queries with `@name` placeholders on any PostgreSQL executor.
///
/// Works the same on a pooled connection (`withPostgresConnection`), inside
/// `withTransaction`, and on `RlsTransaction.executor`:
///
/// ```dart
/// final users = await exec.query(
///   'SELECT id, name FROM users WHERE org = @org AND active = @active',
///   User.fromRow,
///   params: {'org': orgId, 'active': true},
/// );
/// ```
///
/// The `@name` rewrite is done once per SQL text and cached (see
/// [NamedSql]). Values are converted as the table on `inferParam` shows; pass a
/// `Param` for an explicit type. A missing value throws [ArgumentError]
/// before anything is sent. The result set is always released, also when
/// the mapper throws. A mapper that wants a map can call `row.toMap()`.
extension SqlFirstQueries on PostgresQueryExecutorContract {
  /// Runs [sql] and maps every row with [map].
  Future<List<T>> query<T>(
    String sql,
    T Function(PostgresResultRow row) map, {
    Map<String, Object?> params = const {},
  }) async {
    final rs = await _run(sql, params);
    try {
      return [for (final row in rs.rows) map(row)];
    } finally {
      rs.release();
    }
  }

  /// Runs [sql] and maps the first row with [map], or returns `null` when
  /// there is no row.
  Future<T?> queryFirst<T>(
    String sql,
    T Function(PostgresResultRow row) map, {
    Map<String, Object?> params = const {},
  }) async {
    final rs = await _run(sql, params);
    try {
      return rs.rowCount == 0 ? null : map(rs.row(0));
    } finally {
      rs.release();
    }
  }

  /// Runs [sql] and returns column 0 of the first row, or `null` when there
  /// is no row. Throws a [TypeError] when the value is not a `T`.
  Future<T?> scalar<T>(
    String sql, {
    Map<String, Object?> params = const {},
  }) async {
    final rs = await _run(sql, params);
    try {
      return rs.rowCount == 0 ? null : rs.row(0)[0] as T?;
    } finally {
      rs.release();
    }
  }

  Future<PostgresResultSet> _run(String sql, Map<String, Object?> params) {
    final named = NamedSql.cached(sql);
    final bound = named.bind(params);
    if (bound.isEmpty) return execute(named.sql);
    return execute(named.sql, params: bound);
  }
}

/// Rewrites [sql] and binds [params] into the positional statement that
/// `PostgresRepository`'s `*SqlParams` hooks return.
SqlStmt namedStmt(String sql, Map<String, Object?> params) {
  final named = NamedSql.cached(sql);
  return (named.sql, named.bind(params));
}
