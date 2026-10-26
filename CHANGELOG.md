# Changelog

## 0.1.6

Documentation only: README rewritten, the CRUD server example renamed to `example/main.dart`, dartdoc on the
exception constructors. No API change.

## 0.1.5

First release on pub.dev. Depends on `orbiter` `^0.1.3` and `slingshot_postgres` `^0.1.5` from pub.dev instead
of by `git`. No API change.

## 0.1.4

Renamed from `dart_backend_framework_postgres` to `orbiter_postgres`; the repository moved with it. No API change: only the package
name, the library import (`package:orbiter_postgres/orbiter_postgres.dart`) and the dependency key change. Depends on `orbiter` and
`slingshot_postgres`, the renamed framework and connector.

## 0.1.3

Consumed by `git` reference to the tag `v0.1.3`. Depends on `dart_backend_framework` 0.1.0 and
`dart_db_connector_postgres` 0.1.3, as before.

### Added

- `withTenantTransaction(pool, tenantId, body)`: the RLS transaction opened by a repository or use case instead of
  the request pipeline. Same sequence and exceptions as `rlsTransaction`: rollback and rethrow when the function
  throws, rollback when `setRollbackOnly()` was called, rollback and `RlsCommitException` when `COMMIT` fails; a
  `PoolExhaustedException` propagates. Returns the value of the function.
- `localSettings` on `withTenantTransaction`: other transaction-local settings (such as `app.correlation_id`) applied
  in the same first statement as the tenant, every name and value bound as a parameter. Invalid names throw
  `ArgumentError` before the pool is touched.
- `TenantRequiredException`, thrown before the pool is touched when the tenant is `null` or empty. It is outside the
  sealed `RlsException`, so existing exhaustive `switch` statements keep compiling.
- `withTenantTransactionOn`, the same function over any `UnitOfWork` factory, for tests without a database.

### Changed

- Nothing changes for `rlsTransaction`: the statement that applies the tenant is the same.

### Documentation

- README: a section on `withTenantTransaction`; and, under `rlsTransaction`, "Errors and configuration", covering
  the sealed `RlsException`, when each exception is thrown and what the client gets, the `TenantResolver` and
  `CommitPredicate` types, `settingName` and `rlsTransactionOn`.

### Tests

- Repository-mode tests without a database, against PostgreSQL (tenant isolation, rollback, local settings that do
  not outlive the transaction, exhausted pool) and in the stress suite.

## 0.1.2

Consumed by `git` reference to the tag `v0.1.2`. Depends on `dart_backend_framework` 0.1.0 and
`dart_db_connector_postgres` 0.1.3.

### Added

- `prefixTsQuery(input)`: a prefix `tsquery` (`'jo':* & 'sil':*`) from free text, for
  `to_tsquery(config, $1)` with `Param.text`. Only letters, combining marks and digits survive; operators, quotes and
  backslashes are separators. Returns `null` when there is no word.

### Changed

- The package is described as the PostgreSQL kit for applications that use the framework with the connector.
- The connector dependency moves to 0.1.3 (from 0.1.1), so this kit and the connector at 0.1.3 can be used together.
  Through the connector, `tsvector`, `tsquery` and `regconfig` values now read as `String`; see its CHANGELOG.

### Tests

- The integration tests no longer point to a directory outside the package; their header and the README "Tests"
  section say which PostgreSQL they expect.
- Operator-injection tests for `prefixTsQuery`, without a database and against PostgreSQL.
- A public-surface test over the package barrel.

## 0.1.1

Consumed by `git` reference to the tag `v0.1.1`. Depends on `dart_backend_framework` 0.1.0 and
`dart_db_connector_postgres` 0.1.1.

- No code change. The connector dependency moves to 0.1.1, so this extension and the connector at 0.1.1 can be
  used together; on 0.1.0 they conflicted in `pub get`.

## 0.1.0

First public release, consumed by `git` reference to the tag `v0.1.0`. Depends on `dart_backend_framework`
0.1.0 and `dart_db_connector_postgres` 0.1.0.

- `rlsTransaction` / `rlsTransactionOn`: one transaction per request with the tenant set by a parameterised
  `set_config` as its first statement; commit before the response is written (buffered body) or after the last
  byte (stream); rollback on exception, on a status of 400 or above (`shouldCommit`, default `commitOnSuccess`)
  or on `setRollbackOnly()`; `onUnresolved` without borrowing a connection when there is no tenant; `503` with
  `Retry-After` when the pool is exhausted.
- `RlsException`, `RlsContextException`, `RlsCommitException`.
- Example CRUD server in `example/`.
