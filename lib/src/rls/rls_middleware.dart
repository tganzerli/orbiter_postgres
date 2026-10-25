import 'dart:async';
import 'dart:convert';

import 'package:orbiter/orbiter.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'rls_exceptions.dart';
import 'rls_transaction.dart';

/// Resolves the tenant of a request, or `null` when there is none. The tenant
/// must come from an authenticated source, never from the body, query or an
/// unauthenticated header.
typedef TenantResolver = FutureOr<String?> Function(Request request);

/// Decides whether a response commits its transaction.
typedef CommitPredicate = bool Function(Response response);

/// Default policy: commit for any status below 400.
bool commitOnSuccess(Response response) => response.statusCode < 400;

final Response _serviceUnavailable = Response(
  503,
  headers: const {
    'content-type': ['application/json; charset=utf-8'],
    'retry-after': ['1'],
  },
  body: utf8.encode('{"error":"Service Unavailable","code":503}'),
);

Response _defaultUnavailable(Request request, PoolExhaustedException error) =>
    _serviceUnavailable;

/// Opens one transaction per request with the tenant applied by
/// `set_config(settingName, tenant, true)`, and ends it deterministically.
///
/// - **No tenant, no connection.** A `null` or empty tenant short-circuits to
///   [onUnresolved] before any connection is borrowed. There is no optional
///   mode.
/// - **Buffered bodies commit before the response is written**, so a failing
///   `COMMIT` becomes an error response instead of a 200 already sent.
/// - **`Stream` bodies commit in the cleanup hook, after the last byte**, so
///   the stream can keep reading through the executor. A failing commit then
///   reaches only the server-side `onError`; such routes must be read-only.
/// - **Rollback** when the handler throws, when [shouldCommit] says no, or
///   after `RlsTransaction.setRollbackOnly`.
/// - The pool being exhausted answers 503 with `Retry-After` ([onUnavailable]).
///
/// [settingName] is configuration, not a decision of this package: the
/// database policy must read the same name.
InterceptorFunction rlsTransaction({
  required PostgresConnectionPool pool,
  required TenantResolver tenantResolver,
  required Response Function(Request request) onUnresolved,
  String settingName = 'app.tenant_id',
  CommitPredicate shouldCommit = commitOnSuccess,
  Response Function(Request request, PoolExhaustedException error)
      onUnavailable = _defaultUnavailable,
}) =>
    rlsTransactionOn(
      unitOfWorkFactory: () => PostgresUnitOfWork(pool),
      tenantResolver: tenantResolver,
      onUnresolved: onUnresolved,
      settingName: settingName,
      shouldCommit: shouldCommit,
      onUnavailable: onUnavailable,
    );

/// Same as [rlsTransaction], over any unit-of-work factory. Exists so the
/// policy can be exercised without a native library or a database; production
/// code uses [rlsTransaction].
InterceptorFunction rlsTransactionOn({
  required UnitOfWork<PostgresQueryExecutorContract> Function()
      unitOfWorkFactory,
  required TenantResolver tenantResolver,
  required Response Function(Request request) onUnresolved,
  String settingName = 'app.tenant_id',
  CommitPredicate shouldCommit = commitOnSuccess,
  Response Function(Request request, PoolExhaustedException error)
      onUnavailable = _defaultUnavailable,
}) {
  final newUow = unitOfWorkFactory;

  return (request, next) async {
    final tenant = await tenantResolver(request);
    if (tenant == null || tenant.isEmpty) return onUnresolved(request);

    final uow = newUow();
    try {
      await uow.begin();
    } on PoolExhaustedException catch (error) {
      return onUnavailable(request, error);
    }

    final tx = RlsTransaction.internal(uow, tenant, settingName);
    // Registered before next(): LIFO runs the hooks of the handler first.
    request.addCleanupHook(tx.finish);
    request.context.set<RlsTransaction>(tx);

    try {
      await tx.applyContext();
    } on Object catch (error, stackTrace) {
      await tx.abort();
      throw RlsContextException(tenant, error, stackTrace);
    }

    final Response response;
    try {
      response = await next(request);
    } on Object {
      await tx.abort();
      rethrow;
    }

    final commit = shouldCommit(response) && !tx.rollbackOnly;
    if (response.body is Stream<List<int>>) {
      tx.deferCommit(commit: commit);
      return response;
    }
    if (!commit) {
      await tx.abort();
      return response;
    }
    try {
      await tx.commit();
    } catch (error, stackTrace) {
      await tx.abort();
      throw RlsCommitException(
        tenant,
        error,
        stackTrace,
        afterResponse: false,
      );
    }
    return response;
  };
}
