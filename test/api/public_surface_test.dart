/// Smoke test for the public API surface.
///
/// Imports ONLY the package barrel, NOT any `src/` path. The test is
/// compile-only — no DB is needed. If any symbol disappears from the barrel,
/// this file fails to compile. `quoteTsLexeme` is not part of the surface.
library;

// ignore_for_file: unused_local_variable

import 'package:orbiter/orbiter.dart';
import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:test/test.dart';

void main() {
  test(
      'barrel exposes the RLS middleware, the repository mode and prefixTsQuery',
      () {
    // Types (7)
    expect(RlsException, isA<Type>());
    expect(RlsContextException, isA<Type>());
    expect(RlsCommitException, isA<Type>());
    expect(RlsTransaction, isA<Type>());
    expect(CommitPredicate, isA<Type>());
    expect(TenantResolver, isA<Type>());
    expect(TenantRequiredException, isA<Type>());

    // Functions (6)
    expect(rlsTransaction, isA<Function>());
    expect(rlsTransactionOn, isA<Function>());
    expect(commitOnSuccess, isA<Function>());
    expect(prefixTsQuery, isA<Function>());
    expect(withTenantTransaction, isA<Function>());
    expect(withTenantTransactionOn, isA<Function>());

    // Extension `RlsRequest`, referenced by use in a body that never runs.
    RlsTransaction rlsOf(Request request) => request.rls;
    expect(rlsOf, isA<Function>());
  });
}
