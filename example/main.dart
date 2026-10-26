import 'dart:convert';
import 'dart:io';

import 'package:orbiter/orbiter.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';

/// Runnable example wiring [BackendServer], [Pipeline] and [Router] to the
/// native [PostgresConnectionPool] of `slingshot_postgres`.
///
/// It shows:
/// 1. The connection pool injected into the [RequestContext] (no Zone).
/// 2. Parameterised routes on the radix/trie router, O(k) lookup.
/// 3. Cleanup hooks that run whether the request succeeds or fails.
/// 4. A transactional unit of work that rolls back on error.
void main(List<String> args) async {
  // 1. Configuration from environment variables
  final host = Platform.environment['POSTGRES_HOST'] ?? 'localhost';
  final dbPort = int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '') ?? 5432;
  final dbName = Platform.environment['POSTGRES_DB'] ?? 'teste';
  final user = Platform.environment['POSTGRES_USER'] ?? 'postgres';
  final password = Platform.environment['POSTGRES_PASSWORD'] ?? '123';
  final poolSize = int.tryParse(Platform.environment['POOL_SIZE'] ?? '') ?? 10;
  final serverPort = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  final connInfo = PostgresConnInfo(
    host: host,
    port: dbPort,
    database: dbName,
    user: user,
    password: password,
    sslMode: SslMode.disable,
  ).build();

  print('── Starting HTTP server & PostgreSQL ──');
  print('Host DB: $host:$dbPort | Database: $dbName | Pool: $poolSize conns');

  // 2. Native (FFI) connection pool
  final pool = PostgresConnectionPool(
    PoolConfig(
      connInfo: connInfo,
      minSize: poolSize,
      maxSize: poolSize,
    ),
  );

  try {
    await pool.start();
    print('✔ PostgreSQL pool connected.');
  } catch (e) {
    print('⚠ Could not connect to PostgreSQL ($e).');
    print('  Starting anyway, so routes without the database can be tried.');
  }

  // 3. Routes
  final router = Router();

  // GET /health — liveness and pool status
  router.get('/health', (request) {
    return Response.json({
      'status': 'healthy',
      'framework': 'orbiter',
      'pool': {
        'maxSize': poolSize,
      },
    });
  });

  // GET /api/v1/users — list users
  router.get('/api/v1/users', (request) async {
    final dbPool = request.context.getOrNull<PostgresConnectionPool>();
    if (dbPool == null) {
      return _error(503, 'Database unavailable');
    }

    try {
      final rows = await withPostgresConnection(dbPool, (exec) async {
        final result = await exec.execute(
          'SELECT id, name, email FROM users ORDER BY id ASC LIMIT 50',
        );
        final list = <Map<String, dynamic>>[];
        for (final row in result.rows) {
          list.add({
            'id': row[0],
            'name': row[1],
            'email': row[2],
          });
        }
        return list;
      });

      return Response.json({'users': rows});
    } catch (e, st) {
      return _failure('list users', e, st);
    }
  });

  // GET /api/v1/users/:id — fetch by path parameter
  router.get('/api/v1/users/:id', (request) async {
    final dbPool = request.context.getOrNull<PostgresConnectionPool>();
    if (dbPool == null) {
      return _error(503, 'Database unavailable');
    }

    final idStr = request.pathParam('id');
    final id = int.tryParse(idStr ?? '');
    if (id == null) {
      return _error(400, 'Invalid id');
    }

    try {
      final user = await withPostgresConnection(dbPool, (exec) async {
        final result = await exec.execute(
          'SELECT id, name, email FROM users WHERE id = \$1',
          params: [Param.int4(id)],
        );
        if (result.rowCount == 0) return null;
        final row = result.row(0);
        return {
          'id': row[0],
          'name': row[1],
          'email': row[2],
        };
      });

      if (user == null) {
        return _error(404, 'User not found');
      }

      return Response.json(user);
    } catch (e, st) {
      return _failure('fetch user', e, st);
    }
  });

  // POST /api/v1/users — create inside a transaction
  router.post('/api/v1/users', (request) async {
    final dbPool = request.context.getOrNull<PostgresConnectionPool>();
    if (dbPool == null) {
      return _error(503, 'Database unavailable');
    }

    // A body above `maxBodySize` throws PayloadTooLargeException, which the
    // default error boundary turns into a 413.
    final bodyStr = await request.readAsString();
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (_) {
      return _error(400, 'Invalid JSON payload');
    }

    final name = body['name'] as String?;
    final email = body['email'] as String?;

    if (name == null || name.isEmpty || email == null || email.isEmpty) {
      return _error(400, 'Fields name and email are required');
    }

    // Cleanup hooks run in LIFO order
    request.addCleanupHook(() async {
      // Runs at the end of every request (e.g. audit or resource release)
    });

    try {
      final createdUser = await withTransaction(dbPool, (uow) async {
        final result = await uow.execute(
          'INSERT INTO users (name, email) VALUES (\$1, \$2) RETURNING id',
          params: [Param.text(name), Param.text(email)],
        );
        final newId = result.row(0)[0];
        return {
          'id': newId,
          'name': name,
          'email': email,
        };
      });

      return Response.json(createdUser, statusCode: 201);
    } catch (e, st) {
      return _failure('insert user', e, st);
    }
  });

  // 4. Pipeline
  final app = Pipeline()
      .add(securityHeaders())
      .add(requestLogger())
      // Puts the pool into the RequestContext
      .add((request, next) {
        request.context.set<PostgresConnectionPool>(pool);
        return next(request);
      })
      .addHandler(router.handler);

  // 5. BackendServer over dart:io
  final server = await BackendServer.bind(
    handler: app,
    address: InternetAddress.anyIPv4,
    port: serverPort,
  );

  print('✔ Listening on http://0.0.0.0:${server.port}');
  print('Routes:');
  print('  • GET  /health');
  print('  • GET  /api/v1/users');
  print('  • GET  /api/v1/users/:id');
  print('  • POST /api/v1/users');
  print('\nPress Ctrl+C to shut down gracefully...');

  // 6. Graceful shutdown (SIGINT in a terminal, SIGTERM in a container)
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (shuttingDown) return;
    shuttingDown = true;
    print('\n$signal received. Shutting down...');
    await server.close(force: false);
    await pool.close();
    print('Server and pool closed.');
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}

/// JSON error response with a message that is safe for the client.
Response _error(int status, String message) =>
    Response.json({'error': message}, statusCode: status);

/// Logs the failure detail on the server and returns only a generic message to
/// the client: exception text and the Postgres `serverMessage` can carry table
/// names, constraints and values from other rows.
Response _failure(String operation, Object error, StackTrace stackTrace) {
  stderr.writeln('[orbiter_postgres example] failed to $operation: $error');
  return _error(500, 'Internal error: could not $operation');
}
