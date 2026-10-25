import 'package:orbiter/orbiter.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:meta/meta.dart';

import 'rls_exceptions.dart';

/// The transaction bound to one request, with the tenant already applied.
///
/// Handlers reach it through `request.rls`. It exposes the transactional
/// executor only: no pool, no connection and no unit of work, so a handler
/// cannot open an autocommit statement through this package. (A handler that
/// captures the pool by another route is outside what this type can prevent;
/// the README makes that a review rule.)
final class RlsTransaction {
  final UnitOfWork<PostgresQueryExecutorContract> _uow;

  /// Tenant applied to this transaction.
  final String tenantId;

  /// Name of the setting that carries the tenant.
  final String settingName;

  /// Other transaction-local settings applied with the tenant.
  final Map<String, String> _localSettings;

  bool _rollbackOnly = false;
  bool _deferredCommit = false;

  @internal
  RlsTransaction.internal(
    this._uow,
    this.tenantId,
    this.settingName, {
    Map<String, String> localSettings = const {},
  }) : _localSettings = localSettings;

  /// Executor pinned to the transaction. Throws [TransactionStateError] once
  /// the transaction has ended.
  PostgresQueryExecutorContract get executor => _uow.executor;

  /// Whether the transaction is still open.
  bool get isActive => _uow.isActive;

  /// Whether the transaction will be rolled back regardless of the response.
  bool get rollbackOnly => _rollbackOnly;

  /// Forces a rollback for this request, whatever the response status.
  void setRollbackOnly() => _rollbackOnly = true;

  /// `set_config(name, tenant, true)`: transaction-local, both values bound as
  /// parameters (Extended protocol), first statement of the transaction.
  ///
  /// The local settings, when present, go in the same `SELECT`, one
  /// `set_config` each, after the tenant. Without them the statement is the
  /// single-setting one.
  @internal
  Future<void> applyContext() async {
    final sql = StringBuffer(r'SELECT set_config($1, $2, true)');
    final params = [Param.text(settingName), Param.text(tenantId)];
    for (final MapEntry(:key, :value) in _localSettings.entries) {
      final n = params.length;
      sql.write(', set_config(\$${n + 1}, \$${n + 2}, true)');
      params
        ..add(Param.text(key))
        ..add(Param.text(value));
    }
    final rs = await _uow.executor.execute(sql.toString(), params: params);
    rs.release();
  }

  @internal
  Future<void> commit() => _uow.commit();

  /// Best-effort rollback; never throws.
  @internal
  Future<void> abort() => _uow.close();

  /// Streamed bodies: the decision is taken after `next()` and applied by the
  /// cleanup hook, once the body is fully written.
  @internal
  void deferCommit({required bool commit}) {
    _deferredCommit = commit;
  }

  /// Cleanup hook. Idempotent: the buffered path has already ended the
  /// transaction, so this is the safety net and the deferred commit.
  @internal
  Future<void> finish() async {
    if (!_uow.isActive) return;
    if (!_deferredCommit) {
      await _uow.close();
      return;
    }
    try {
      await _uow.commit();
    } catch (error, stackTrace) {
      await _uow.close();
      throw RlsCommitException(
        tenantId,
        error,
        stackTrace,
        afterResponse: true,
      );
    }
  }
}

/// Access to the request's [RlsTransaction].
extension RlsRequest on Request {
  /// The RLS transaction of this request. Throws if the middleware did not run.
  RlsTransaction get rls => context.get<RlsTransaction>();
}
