import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:test/test.dart';

void expectRewrite(String sql, String expected, [List<String>? names]) {
  final r = NamedSql.parse(sql);
  expect(r.sql, expected);
  if (names != null) expect(r.names, names);
}

void expectUntouched(String sql) {
  final r = NamedSql.parse(sql);
  expect(r.sql, same(sql));
  expect(r.names, isEmpty);
}

void main() {
  group('placeholders', () {
    test('numbers names in order of first use', () {
      expectRewrite(
        'SELECT * FROM t WHERE a = @a AND b = @b',
        r'SELECT * FROM t WHERE a = $1 AND b = $2',
        ['a', 'b'],
      );
    });

    test('a repeated name reuses its number', () {
      expectRewrite(
        'SELECT @p, @zz, @p',
        r'SELECT $1, $2, $1',
        ['p', 'zz'],
      );
    });

    test('names with digits and underscores; placeholder at the edges', () {
      expectRewrite('@a_1', r'$1', ['a_1']);
      expectRewrite('x=@_x2;', r'x=$1;', ['_x2']);
    });

    test('placeholder right after =, (, comma, minus and comparison', () {
      expectRewrite(
        'WHERE a=@a AND b<>@b AND c<=@c AND d>@d AND e IN(@e,@f) AND g=-@g',
        r'WHERE a=$1 AND b<>$2 AND c<=$3 AND d>$4 AND e IN($5,$6) AND g=-$7',
      );
    });

    test('non-ASCII names are read whole', () {
      expectRewrite('SELECT @café, @ação', r'SELECT $1, $2', ['café', 'ação']);
    });

    test('a cast right after the placeholder is kept', () {
      expectRewrite(
        'WHERE id = @id::uuid AND n = @n::int',
        r'WHERE id = $1::uuid AND n = $2::int',
      );
    });

    test('inside parentheses, lists and after commas', () {
      expectRewrite(
        'INSERT INTO t (a, b) VALUES (@a,@b)',
        r'INSERT INTO t (a, b) VALUES ($1,$2)',
      );
    });

    test('SQL without placeholders is returned as the same string', () {
      expectUntouched('SELECT 1');
      expectUntouched(r'SELECT * FROM t WHERE id = $1');
    });
  });

  group('lexical contexts are left alone', () {
    test('e-mail inside a single-quoted literal', () {
      expectRewrite(
        "SELECT * FROM u WHERE mail = 'ana@example.com' AND id = @id",
        r"SELECT * FROM u WHERE mail = 'ana@example.com' AND id = $1",
        ['id'],
      );
    });

    test("doubled quote inside a literal", () {
      expectRewrite(
        "SELECT 'it''s @x', @y",
        r"SELECT 'it''s @x', $1",
        ['y'],
      );
    });

    test('backslash does not escape in a standard literal', () {
      expectRewrite(r"SELECT 'C:\', @x", r"SELECT 'C:\', $1", ['x']);
    });

    test("E'...' literal with backslash-escaped quote", () {
      expectRewrite(
          r"SELECT E'it\'s @x', @y", r"SELECT E'it\'s @x', $1", ['y']);
      expectRewrite(r"SELECT e'\\', @y", r"SELECT e'\\', $1", ['y']);
    });

    test("identifier ending in e before a quote is not an E'' prefix", () {
      // `type'...'` is a typed literal; the backslash does not escape.
      expectRewrite(
          r"SELECT date'2020\', @x", r"SELECT date'2020\', $1", ['x']);
    });

    test('double-quoted identifier, with doubled quote', () {
      expectRewrite(
        'SELECT "@col", "a""@b", @c FROM t',
        r'SELECT "@col", "a""@b", $1 FROM t',
        ['c'],
      );
    });

    test('line comment', () {
      expectRewrite(
        'SELECT @a -- ignore @b\n, @c',
        'SELECT \$1 -- ignore @b\n, \$2',
        ['a', 'c'],
      );
    });

    test('nested block comment', () {
      expectRewrite(
        'SELECT /* a /* @x */ @y */ @z',
        r'SELECT /* a /* @x */ @y */ $1',
        ['z'],
      );
    });

    test(r'dollar quote, empty tag and named tag', () {
      expectRewrite(
        r'SELECT $$ @x $$, @y',
        r'SELECT $$ @x $$, $1',
        ['y'],
      );
      expectRewrite(
        r'DO $fn$ BEGIN PERFORM @x; $$ inner $$; END $fn$; SELECT @y',
        r'DO $fn$ BEGIN PERFORM @x; $$ inner $$; END $fn$; SELECT $1',
        ['y'],
      );
    });

    test(r'$ inside an identifier is not a dollar quote', () {
      expectRewrite(r'SELECT foo$bar, @x', r'SELECT foo$bar, $1', ['x']);
    });

    test('unterminated literal or comment runs to the end without error', () {
      expectUntouched("SELECT 'open @x");
      expectUntouched('SELECT /* open @x');
      expectUntouched(r'SELECT $q$ open @x');
    });

    test('multibyte text around placeholders', () {
      expectRewrite(
        "SELECT 'ação @x', @nome, ünï",
        r"SELECT 'ação @x', $1, ünï",
        ['nome'],
      );
    });
  });

  group('operators containing @ are not placeholders', () {
    for (final sql in [
      'SELECT a @> b',
      'SELECT a <@ b',
      'SELECT a <@b',
      'SELECT a @@ q',
      'SELECT v @@to_tsquery(q)',
      'SELECT p @-@ q',
      'SELECT @ -5',
      'SELECT @ x',
      'SELECT a@b',
      'SELECT p @-@q',
      'SELECT a @@@b',
    ]) {
      test(sql, () => expectUntouched(sql));
    }
  });

  group('errors', () {
    test(r'mixing $N and @name is rejected', () {
      expect(
        () => NamedSql.parse(r'SELECT $1, @x'),
        throwsA(isA<FormatException>()),
      );
    });

    test(r'$N inside a literal does not count as positional', () {
      expectRewrite(r"SELECT '$1', @x", r"SELECT '$1', $1", ['x']);
    });
  });

  group('bind', () {
    test('values follow \$N order and repeated names bind once', () {
      final r = NamedSql.parse('SELECT @b, @a, @b');
      final params = r.bind({'a': 1, 'b': 'x', 'extra': true});
      expect(params, hasLength(2));
      expect(params[0].oid, inferParam('b', 'x').oid);
      expect(params[1].oid, inferParam('a', 1).oid);
    });

    test('missing value throws ArgumentError naming the placeholder', () {
      final r = NamedSql.parse('SELECT @a, @b');
      expect(
        () => r.bind({'a': 1}),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('@b'))),
      );
    });

    test('explicit null is a value, not a missing one', () {
      final r = NamedSql.parse('SELECT @a');
      expect(r.bind({'a': null}), hasLength(1));
    });

    test('params given to SQL without placeholders throw', () {
      expect(
        () => NamedSql.parse('SELECT 1').bind({'a': 1}),
        throwsArgumentError,
      );
      expect(NamedSql.parse('SELECT 1').bind(const {}), isEmpty);
    });
  });

  group('cache', () {
    setUp(NamedSql.clearCache);

    test('returns the same instance for the same text', () {
      final a = NamedSql.cached('SELECT @x');
      final b = NamedSql.cached('SELECT @x');
      expect(b, same(a));
      expect(NamedSql.cacheSize, 1);
    });

    test('is bounded and drops the oldest entry', () {
      final first = NamedSql.cached('SELECT @k0');
      for (var i = 1; i <= NamedSql.cacheCapacity; i++) {
        NamedSql.cached('SELECT @k$i');
      }
      expect(NamedSql.cacheSize, NamedSql.cacheCapacity);
      expect(NamedSql.cached('SELECT @k0'), isNot(same(first)));
    });
  });
}
