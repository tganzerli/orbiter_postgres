/// PostgreSQL kit for `orbiter`.
///
/// For applications that use the framework together with
/// `slingshot_postgres`. The framework has no database dependency;
/// this package holds the PostgreSQL-specific pieces for using the two together.
library;

export 'src/fts/prefix_ts_query.dart' show prefixTsQuery;

export 'src/rls/rls_exceptions.dart'
    show
        RlsCommitException,
        RlsContextException,
        RlsException,
        TenantRequiredException;
export 'src/rls/rls_middleware.dart'
    show
        CommitPredicate,
        TenantResolver,
        commitOnSuccess,
        rlsTransaction,
        rlsTransactionOn;
export 'src/rls/rls_transaction.dart' show RlsRequest, RlsTransaction;
export 'src/rls/tenant_transaction.dart'
    show withTenantTransaction, withTenantTransactionOn;
