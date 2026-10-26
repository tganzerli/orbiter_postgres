/// Failures raised by the RLS transaction middleware.
///
/// `toString` does not repeat the server message; the original error is kept
/// in [cause] so it is reachable (logging, mapping) but never forwarded blindly.
sealed class RlsException implements Exception {
  /// Tenant the failing request belonged to.
  final String tenantId;

  /// The error that triggered this exception.
  final Object cause;

  /// Stack trace of [cause].
  final StackTrace causeStackTrace;

  const RlsException(this.tenantId, this.cause, this.causeStackTrace);

  @override
  String toString() =>
      '$runtimeType(tenant: $tenantId, cause: ${cause.runtimeType})';
}

/// Applying the tenant setting failed. The transaction was rolled back and the
/// connection was already returned to the pool.
final class RlsContextException extends RlsException {
  /// Wraps [cause], raised while applying the setting for [tenantId].
  const RlsContextException(
    super.tenantId,
    super.cause,
    super.causeStackTrace,
  );
}

/// `COMMIT` failed.
///
/// When [afterResponse] is `false` the response had not been written yet, so
/// the client receives an error. When `true` (streamed bodies) the client
/// already has the response and the failure only reaches the server-side
/// `onError`.
final class RlsCommitException extends RlsException {
  /// Whether the response was already written when the commit failed.
  final bool afterResponse;

  /// Wraps [cause], raised by the commit of [tenantId]'s transaction.
  const RlsCommitException(
    super.tenantId,
    super.cause,
    super.causeStackTrace, {
    required this.afterResponse,
  });
}

/// `withTenantTransaction` was called without a tenant. Thrown before the pool
/// is touched, so no connection was taken.
///
/// Not an [RlsException]: there is no tenant and no underlying cause, and that
/// hierarchy is sealed.
final class TenantRequiredException implements Exception {
  /// Creates the exception; it carries no data.
  const TenantRequiredException();

  @override
  String toString() => 'TenantRequiredException';
}
