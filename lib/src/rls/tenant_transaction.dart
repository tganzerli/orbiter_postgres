import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'rls_exceptions.dart';
import 'rls_transaction.dart';

/// Runs [body] inside one RLS transaction opened by the caller (a repository
/// or a use case), not by the request pipeline.
///
/// Same sequence as `rlsTransaction`, without the `Request` around it:
///
/// - `null` or empty [tenantId] throws [TenantRequiredException], and an
///   invalid [localSettings] name throws [ArgumentError], both before the pool
///   is touched;
/// - `BEGIN`; a [PoolExhaustedException] propagates, for the caller to map
///   (for example to 503);
/// - the tenant and [localSettings] are applied in one first statement, every
///   name and value bound as a parameter; on failure, rollback and
///   [RlsContextException];
/// - [body] throws: rollback, and the error is rethrown;
/// - [RlsTransaction.setRollbackOnly] was called: rollback, and the value of
///   [body] is returned;
/// - otherwise `COMMIT`; on failure, rollback and [RlsCommitException] with
///   `afterResponse: false`.
///
/// The connection goes back to the pool on every exit.
Future<T> withTenantTransaction<T>(
  PostgresConnectionPool pool,
  String? tenantId,
  Future<T> Function(RlsTransaction tx) body, {
  String settingName = 'app.tenant_id',
  Map<String, String> localSettings = const {},
}) =>
    withTenantTransactionOn(
      () => PostgresUnitOfWork(pool),
      tenantId,
      body,
      settingName: settingName,
      localSettings: localSettings,
    );

/// Same as [withTenantTransaction], over any unit-of-work factory. Exists so
/// the policy can be exercised without a native library or a database;
/// production code uses [withTenantTransaction].
Future<T> withTenantTransactionOn<T>(
  UnitOfWork<PostgresQueryExecutorContract> Function() unitOfWorkFactory,
  String? tenantId,
  Future<T> Function(RlsTransaction tx) body, {
  String settingName = 'app.tenant_id',
  Map<String, String> localSettings = const {},
}) async {
  if (tenantId == null || tenantId.isEmpty) {
    throw const TenantRequiredException();
  }
  _checkLocalSettings(localSettings, settingName);
  final settings = Map<String, String>.of(localSettings);

  final uow = unitOfWorkFactory();
  await uow.begin();

  final tx = RlsTransaction.internal(
    uow,
    tenantId,
    settingName,
    localSettings: settings,
  );
  try {
    await tx.applyContext();
  } on Object catch (error, stackTrace) {
    await tx.abort();
    throw RlsContextException(tenantId, error, stackTrace);
  }

  final T result;
  try {
    result = await body(tx);
  } on Object {
    await tx.abort();
    rethrow;
  }

  if (tx.rollbackOnly) {
    await tx.abort();
    return result;
  }
  try {
    await tx.commit();
  } catch (error, stackTrace) {
    await tx.abort();
    throw RlsCommitException(
      tenantId,
      error,
      stackTrace,
      afterResponse: false,
    );
  }
  return result;
}

/// PostgreSQL only accepts a custom setting with a prefix (`app.x`). Checked
/// here so a bad name fails before a connection is taken, not as an
/// [RlsContextException] inside the transaction.
void _checkLocalSettings(Map<String, String> settings, String settingName) {
  for (final name in settings.keys) {
    if (name.isEmpty || !name.contains('.')) {
      throw ArgumentError.value(
        name,
        'localSettings',
        'must be a prefixed custom setting, such as app.correlation_id',
      );
    }
    if (name == settingName) {
      throw ArgumentError.value(
        name,
        'localSettings',
        'is the tenant setting; pass the tenant as tenantId',
      );
    }
  }
}
