# orbiter_postgres

[![pub package](https://img.shields.io/pub/v/orbiter_postgres.svg)](https://pub.dev/packages/orbiter_postgres)
[![pub points](https://img.shields.io/pub/points/orbiter_postgres)](https://pub.dev/packages/orbiter_postgres/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Multi-tenant PostgreSQL for Dart backends: one interceptor gives every request its own row-level-security
transaction, so a query can only see its tenant's rows.**

Row-level security lets PostgreSQL itself filter every query by tenant, but only if each request runs inside a
transaction with the tenant set, and that transaction always ends: committed before a success response, rolled
back on errors, and its connection returned to the pool even when the client disconnects mid-stream. Getting that
right by hand in every handler is where tenant data leaks come from. This package does it once, as an interceptor
for [`orbiter`](https://pub.dev/packages/orbiter) over the native pool of
[`slingshot_postgres`](https://pub.dev/packages/slingshot_postgres): the tenant comes from your authentication, the
setting is bound as a parameter, and the handler just runs its queries.

## Features

- **`rlsTransaction`:** an interceptor that opens one transaction per request, applies the tenant with
  `set_config(..., true)` as its first statement and hands the handler an executor pinned to it.
- **Deterministic end:** `COMMIT` before a buffered response is written, so a failed commit never turns into a `200`
  already sent; rollback on `4xx`/`5xx`, on exceptions or on demand; streamed bodies finish their transaction after
  the last byte.
- **Fails closed:** no tenant means no connection and no handler call; an exhausted pool answers `503` with
  `Retry-After`; errors carry the tenant without leaking the server message.
- **`withTenantTransaction`:** the same transaction opened by a repository or use case, when a request has to call
  something slow outside it.
- **`prefixTsQuery`:** turns free text into a safe prefix `tsquery` for search-as-you-type over a GIN index.
- **Testable without a database:** `rlsTransactionOn` runs the same policy over any `UnitOfWork` factory.

## Install

```sh
dart pub add orbiter_postgres
```

The framework and the connector come with it. Experimental (pre-1.0). The connector ships its native library
pre-built and needs `libpq` at run time; see its README for AOT and container builds.

## The family

| Package | Role |
|---|---|
| [`orbiter_postgres`](https://pub.dev/packages/orbiter_postgres) | This kit. |
| [`orbiter`](https://pub.dev/packages/orbiter) | HTTP backend framework, no database dependency. |
| [`slingshot_postgres`](https://pub.dev/packages/slingshot_postgres) | PostgreSQL driver over `libpq`, with a native connection pool. |
| [`slingshot`](https://pub.dev/packages/slingshot) | The contract every slingshot driver implements. |

## `rlsTransaction`: one RLS transaction per request

```dart
final handler = Pipeline()
    .add(authenticate())                       // yours: puts the principal in the context
    .add(rlsTransaction(
      pool: pool,
      tenantResolver: (request) => request.context.getOrNull<Principal>()?.tenantId,
      onUnresolved: (_) => Response.forbidden(),
    ))
    .addHandler(router.handler);

// In a handler:
final rows = await request.rls.executor.execute('SELECT ...');
```

Per request the middleware borrows a connection through `PostgresUnitOfWork`,
runs `SELECT set_config($name, $tenant, true)` (both bound as parameters) as the
first statement of the transaction, hands the handler an executor pinned to that
transaction, and ends it deterministically. The connection always goes back to
the pool, from a cleanup hook if nothing else did.

### What ends the transaction

| Situation | Outcome |
|---|---|
| Buffered body, status below 400 | `COMMIT` **before** the response is written, so a failing commit becomes an error response, never a 200 already sent |
| Buffered body, status 400 or above | rollback (predicate `shouldCommit`, default `commitOnSuccess`) |
| Handler throws | rollback, then the error reaches the error boundary |
| `request.rls.setRollbackOnly()` | rollback, whatever the status |
| `Stream` body | decided after the handler, applied by the cleanup hook **after the last byte**, so the stream can keep reading through the executor |
| No tenant (`null` or empty) | `onUnresolved`; no connection is borrowed, no `next()` |
| Pool exhausted | 503 with `Retry-After: 1` (`onUnavailable`) |

### Errors and configuration

Failures of the transaction itself are thrown as the sealed **`RlsException`**, so an `errorHandler` can switch
over it. Each carries the `tenantId`, and the original database error stays in `cause` / `causeStackTrace`;
`toString` does not repeat the server message, so mapping it to a response never leaks it by accident.

| Exception | When | What the client gets |
|---|---|---|
| `RlsContextException` | applying the tenant setting failed; already rolled back, connection returned | whatever the `errorHandler` answers |
| `RlsCommitException`, `afterResponse: false` | `COMMIT` failed before the response was written | whatever the `errorHandler` answers |
| `RlsCommitException`, `afterResponse: true` | `COMMIT` of a streamed body failed after the last byte | the response already sent; the failure only reaches `onError` |

The callbacks are typed: `tenantResolver` is a **`TenantResolver`** (`FutureOr<String?> Function(Request)`, where
`null` or empty means no tenant) and `shouldCommit` a **`CommitPredicate`** (`bool Function(Response)`,
`commitOnSuccess` by default). `settingName` (default `app.tenant_id`) must match the name the database policy
reads.

`rlsTransactionOn` is the same middleware over any `UnitOfWork` factory. It exists to exercise the policy in
tests without the native library or a database; production code uses `rlsTransaction`.

### Rules this package cannot enforce

- **Streamed routes under RLS must be read-only.** A `COMMIT` that fails after
  the last byte reaches only the server-side `onError` (`RlsCommitException`
  with `afterResponse: true`); the client already has its response.
- **Never capture the pool in a handler** to run an autocommit statement on
  tenant data: the tenant setting does not exist there. Treat it as a review rule.
- **The tenant comes from an authenticated source**, never from the body, the
  query or an unauthenticated header.
- **Routes without a tenant** (health, login) go in another `Pipeline`.
- **The database role** must be neither superuser, nor table owner, nor
  `BYPASSRLS`, and the table needs `FORCE ROW LEVEL SECURITY`; otherwise the
  policy does not apply.
- **`settingName`** (default `app.tenant_id`) must match the name the policy
  reads with `current_setting(..., true)`. It is configuration on purpose.

### Cost

Each request adds a `BEGIN`, the `set_config`, a `COMMIT` and the pool's
session reset on return. The cost of this middleware has not been measured.

### Tests

`test/rls_middleware_test.dart`, `test/tenant_transaction_test.dart` and
`test/prefix_ts_query_test.dart` need no database. The integration tests (`test/integration/postgres_live_test.dart`,
`rls_live_test.dart` and `prefix_ts_query_live_test.dart`) need PostgreSQL at
`localhost:5432` (`dbname=teste user=postgres password=123`).
`prefix_ts_query_live_test.dart` creates no schema or role.
`rls_live_test.dart` uses a superuser because it creates schema `rls_mw` and
roles `rls_mw_owner`/`rls_mw_app`, so do not run two instances at once:

```bash
dart test
```

The integration tests **skip silently** without the library; confirm the skipped
count is zero.

### Stress suite (integrity under load)

`test/stress/` is tagged `stress` (`dart_test.yaml`). It asserts integrity invariants only and never emits time, throughput or latency: client and server share one event loop and the handlers sleep on purpose.

```bash
dart test -x stress                       # fast suite, skips the stress files
dart test -t stress -r compact
```

Parameters (environment): `STRESS_REQUESTS` (400), `STRESS_USERS` (32), `STRESS_SEED` (random, always printed; the same seed rebuilds the same intents). It uses its own schema and roles (`rls_stress*`), so it can run next to `rls_live_test.dart`.

It covers four pool configurations (1, 4, 2 without session reset, 2 with a 100 ms acquire timeout), four tenants with one hot tenant, client aborts at four moments, handlers that fail or answer 409, and a clean shutdown (`server.close()` then `pool.close()`) with requests in flight, plus a stream the client abandons before the first byte. Two more cases run `withTenantTransaction` directly under the same parameters (pool of 2, with and without session reset), with bodies that throw or set rollback-only after inserting, and check that no caller sees another tenant's rows or a stale local setting.

The suite SKIPS silently when the native library or Postgres is missing: check the printed `executed=N skipped=M` line (skipped must be 0).

## `withTenantTransaction`: one RLS transaction opened by the repository

`rlsTransaction` keeps the transaction open for the whole handler. When a use
case has to call something slow or external (a KMS, another service) outside
the transaction, open it where it is needed instead:

```dart
final appointment = await withTenantTransaction(pool, principal.tenantId,
    (tx) async {
  final rs = await tx.executor.execute(
    r'SELECT ... FROM appointment WHERE id = $1',
    params: [Param.int8(id)],
  );
  try {
    return Appointment.fromRow(rs.row(0));
  } finally {
    rs.release();
  }
}, localSettings: {'app.correlation_id': correlationId});
```

The function receives the same `RlsTransaction` a handler gets from
`request.rls` (`executor`, `tenantId`, `setRollbackOnly()`), and its value is
returned. The two modes are independent: an application can use either, or
both, under the same database policy.

| Situation | What happens |
|---|---|
| tenant `null` or empty | `TenantRequiredException`, before the pool is touched |
| pool exhausted | `PoolExhaustedException` propagates; map it (for example to 503 with `Retry-After`) |
| applying the settings fails | rollback, then `RlsContextException` |
| the function throws | rollback, and the error is rethrown |
| `tx.setRollbackOnly()` | rollback, and the value is still returned |
| `COMMIT` fails | rollback, then `RlsCommitException` with `afterResponse: false` |

The connection goes back to the pool on every exit. `TenantRequiredException`
is not an `RlsException`: there is no tenant and no database error behind it.

**`localSettings`** are other transaction-local settings applied in the same
first statement as the tenant, one `set_config(name, value, true)` each, every
name and value bound as a parameter:
`SELECT set_config($1, $2, true), set_config($3, $4, true), ...`. Names must be
prefixed custom settings (`app.correlation_id`); an empty name, a name without
a dot or the tenant's own `settingName` throws `ArgumentError` before the pool
is touched. Without `localSettings` the statement is the one `rlsTransaction`
sends.

`withTenantTransactionOn` is the same function over any `UnitOfWork` factory,
for tests without the native library or a database. The rules above about the
database role, `FORCE ROW LEVEL SECURITY` and an authenticated tenant apply
here too.

## `prefixTsQuery`: prefix search from free text

Turns what a user types into a prefix `tsquery`, safe to bind as a parameter:

```dart
prefixTsQuery('jo sil');      // "'jo':* & 'sil':*"
prefixTsQuery("d'avila & !"); // "'d':* & 'avila':*"
prefixTsQuery('  &|! ');      // null
```

With a generated `tsvector` column and a GIN index:

```sql
CREATE TABLE person (
  id   serial PRIMARY KEY,
  name text NOT NULL,
  doc  tsvector GENERATED ALWAYS AS (to_tsvector('simple', name)) STORED
);
CREATE INDEX person_doc ON person USING gin (doc);
```

```dart
final q = prefixTsQuery(term);
if (q == null) return Response.badRequest(); // or run the query without the filter
final rows = await request.rls.executor.execute(
  "SELECT id, name FROM person WHERE doc @@ to_tsquery('simple', \$1)",
  params: [Param.text(q)],
);
```

Only runs of Unicode letters, combining marks and digits survive; every other
character (`& | ! ( ) : * < - >`, quotes, backslashes, spaces, punctuation) is
a separator. Each word becomes a quoted prefix lexeme, joined with `&`.

- **Normalise the input the way the index was built.** Case is folded by the
  text search configuration, but accents are kept: if the `tsvector` comes from
  `unaccent(...)`, apply the same removal to the term.
- **`null` means no word**: skip the filter. `to_tsquery` on an empty string
  matches nothing.
- **Always bind the result** (`Param.text`); never concatenate it into SQL.

### Cost

One regular expression pass over the input. Not measured.

## Example: CRUD server

`example/main.dart` wires `BackendServer`, `Pipeline` and `Router` to the native pool. It
expects a `users` table:

```sql
CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL, email text NOT NULL UNIQUE);
```

```bash
POSTGRES_HOST=localhost POSTGRES_DB=teste POSTGRES_USER=postgres POSTGRES_PASSWORD=123 \
  dart run example/main.dart
```

Endpoints: `GET /health`, `GET /api/v1/users` (first 50), `GET /api/v1/users/:id`, `POST /api/v1/users`
(inside a transaction). Error responses carry generic messages; exception details and PostgreSQL server
messages are logged on the server only. The server shuts down on `SIGINT` and `SIGTERM`.

`test/integration/postgres_live_test.dart` runs against the same database and skips when it, or the native
library, is unavailable.

## Benchmarks and research

The project started as an MBA thesis in Software Engineering at the University of São Paulo (USP). The
cross-language benchmark suite, its results and the evaluated code are public at
[tganzerli/dart_db_connector](https://github.com/tganzerli/dart_db_connector) (see
[`benchmarks/RESULTS.md`](https://github.com/tganzerli/dart_db_connector/blob/main/benchmarks/RESULTS.md)). The
cost of this kit's middleware has not been measured.

## License

MIT, see `LICENSE`.
