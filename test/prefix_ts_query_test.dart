/// Unit tests for `prefixTsQuery`, without a database: operators, quotes and
/// backslashes never reach the query, and every non-null output has the shape
/// `'w':* & 'w':*`.
library;

import 'dart:math';

import 'package:orbiter_postgres/src/fts/prefix_ts_query.dart';
import 'package:test/test.dart';

/// Every non-null output must match this: quoted prefix lexemes joined by
/// ` & `, with no quote, backslash or whitespace inside a lexeme.
final safeShape = RegExp(r"^'[^'\\\s]+':\*( & '[^'\\\s]+':\*)*$");

const propertySeed = 20261014;
const propertyCount = 2000;
const propertyAlphabet = 'abcXYZ019 &|!():*<->\'"\\';

/// Random strings over letters, digits, space and every `tsquery` operator,
/// quote and backslash; shared with the live test.
List<String> propertyInputs() {
  final rnd = Random(propertySeed);
  return List.generate(propertyCount, (_) {
    final len = rnd.nextInt(12);
    return String.fromCharCodes(List.generate(
        len,
        (_) =>
            propertyAlphabet.codeUnitAt(rnd.nextInt(propertyAlphabet.length))));
  });
}

void main() {
  test('words become prefix lexemes joined by &', () {
    expect(prefixTsQuery('jo sil'), "'jo':* & 'sil':*");
  });

  test('no word gives null', () {
    for (final s in ['', '   ', '\t\n', '& | ! ( ) : * <-> \' " \\']) {
      expect(prefixTsQuery(s), isNull, reason: 'input: $s');
    }
  });

  test('operators are separators, never part of the query', () {
    expect(prefixTsQuery('a&b'), "'a':* & 'b':*");
    expect(prefixTsQuery('a|b'), "'a':* & 'b':*");
    expect(prefixTsQuery('!a'), "'a':*");
    expect(prefixTsQuery('(a)'), "'a':*");
    expect(prefixTsQuery('a:*'), "'a':*");
    expect(prefixTsQuery('a<->b'), "'a':* & 'b':*");
    expect(prefixTsQuery('a:A'), "'a':* & 'A':*");
  });

  test('quotes and backslashes are separators', () {
    expect(prefixTsQuery("d'avila"), "'d':* & 'avila':*");
    expect(prefixTsQuery("o'brien"), "'o':* & 'brien':*");
    expect(prefixTsQuery(r'ab\'), "'ab':*");
  });

  test('case and accents are kept', () {
    expect(prefixTsQuery('João'), "'João':*");
  });

  test('a decomposed accent stays in the word', () {
    const nfd = 'João';
    expect(prefixTsQuery(nfd), "'$nfd':*");
  });

  test('digits and non-Latin letters are word characters; _ is not', () {
    expect(prefixTsQuery('abc123'), "'abc123':*");
    expect(prefixTsQuery('a_b'), "'a':* & 'b':*");
    expect(prefixTsQuery('東京'), "'東京':*");
  });

  test('quoteTsLexeme doubles quotes and escapes backslashes', () {
    expect(quoteTsLexeme("o'b\\"), r"'o''b\\'");
  });

  test('random input over the operator alphabet (seed $propertySeed)', () {
    for (final s in propertyInputs()) {
      final q = prefixTsQuery(s);
      if (q != null) expect(q, matches(safeShape), reason: 'input: $s');
    }
  });
}
