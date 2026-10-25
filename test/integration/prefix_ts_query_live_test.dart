/// Integration tests against PostgreSQL at localhost:5432 (database `teste`,
/// superuser `postgres`; see the README, "Tests"):
/// every output of `prefixTsQuery`, including for hostile input, is accepted
/// by `to_tsquery`, and it matches by prefix per word with `&` between words.
///
/// Creates no schema or role. Reads results as `::text`.
///
/// Skips when the native library is not built or Postgres is unreachable.
library;

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

import '../prefix_ts_query_test.dart' show propertyInputs, propertySeed;

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const hostile = [
  'jo sil',
  '& | ! ( ) : * <-> \' " \\',
  'a&b',
  'a|b',
  '!a',
  '(a)',
  'a:*',
  'a<->b',
  'a:A',
  "d'avila",
  "o'brien",
  r'ab\',
  'João',
  'João',
  'abc123',
  'a_b',
  '東京',
];

Future<String?> tsquery(PostgresQueryExecutorContract exec, String q) async {
  final rs = await exec.execute(
    "SELECT to_tsquery('simple', \$1)::text AS v",
    params: [Param.text(q)],
  );
  try {
    return rs.row(0).getString('v');
  } finally {
    rs.release();
  }
}

Future<String?> matchesDoc(
    PostgresQueryExecutorContract exec, String q, String doc) async {
  final rs = await exec.execute(
    "SELECT (to_tsvector('simple', \$2) @@ to_tsquery('simple', \$1))::text AS v",
    params: [Param.text(q), Param.text(doc)],
  );
  try {
    return rs.row(0).getString('v');
  } finally {
    rs.release();
  }
}

void main() {
  PostgresConnectionPool? pool;
  String? skipReason;

  setUpAll(() async {
    try {
      final p = PostgresConnectionPool(PoolConfig(
        connInfo: _connInfo,
        minSize: 1,
        maxSize: 1,
        acquireTimeout: const Duration(seconds: 5),
      ));
      await p.start();
      pool = p;
    } on Object catch (e) {
      skipReason =
          'Postgres or native library unavailable ($e) — start PostgreSQL at localhost:5432';
    }
  });

  tearDownAll(() async => pool?.close());

  /// Registers [body] as a test that is skipped when Postgres is unavailable.
  void liveTest(String description,
      Future<void> Function(PostgresQueryExecutorContract) body) {
    test(description, () async {
      if (skipReason != null) {
        markTestSkipped(skipReason!);
        return;
      }
      await withPostgresConnection<void>(pool!, body);
    });
  }

  group('prefixTsQuery against PostgreSQL (live)', () {
    liveTest('to_tsquery accepts every output for hostile input', (exec) async {
      for (final s in hostile) {
        final q = prefixTsQuery(s);
        if (q != null) await tsquery(exec, q);
      }
    });

    liveTest(
        'to_tsquery accepts every output for random input (seed $propertySeed)',
        (exec) async {
      for (final s in propertyInputs()) {
        final q = prefixTsQuery(s);
        if (q != null) await tsquery(exec, q);
      }
    });

    liveTest('PostgreSQL reads the query as prefix lexemes', (exec) async {
      expect(await tsquery(exec, prefixTsQuery('jo sil')!), "'jo':* & 'sil':*");
      expect(await tsquery(exec, prefixTsQuery(r'ab\')!), "'ab':*");
    });

    liveTest('matches by prefix per word, with & between words', (exec) async {
      expect(await matchesDoc(exec, prefixTsQuery('jo sil')!, 'Joao da Silva'),
          'true');
      expect(
          await matchesDoc(
              exec, prefixTsQuery('ana sil')!, 'Ana Maria da Silva'),
          'true');
      expect(await matchesDoc(exec, prefixTsQuery('jo xyz')!, 'Joao da Silva'),
          'false');
    });

    liveTest('control: doubling quotes alone breaks on a trailing backslash',
        (exec) async {
      String naive(String s) => "'${s.replaceAll("'", "''")}':*";
      await expectLater(
          tsquery(exec, naive(r'ab\')), throwsA(isA<QueryFailedException>()));
    });
  });
}
