/// A `Migrator` or `Seeder` run refused to start or stopped.
///
/// Nothing of the script named in [script] stays applied when it was
/// transactional; scripts applied before it in the same run stay applied.
final class MigrationException implements Exception {
  /// What went wrong.
  final String message;

  /// File name of the script involved, when there is one.
  final String? script;

  /// The underlying error (for example the server's `QueryFailedException`).
  final Object? cause;

  const MigrationException(this.message, {this.script, this.cause});

  @override
  String toString() {
    final at = script == null ? '' : ' [$script]';
    final why = cause == null ? '' : ': $cause';
    return 'MigrationException$at: $message$why';
  }
}
