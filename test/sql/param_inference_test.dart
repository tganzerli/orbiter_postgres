import 'dart:typed_data';

import 'package:orbiter_postgres/orbiter_postgres.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:test/test.dart';

void main() {
  void expectSame(Param actual, Param expected) {
    expect(actual.oid, expected.oid);
    expect(actual.format, expected.format);
    expect(actual.encode(), expected.encode());
  }

  test('int is int8, including values outside int4', () {
    expectSame(inferParam('n', 5), Param.int8(5));
    expectSame(inferParam('n', 1 << 40), Param.int8(1 << 40));
    expectSame(inferParam('n', -1), Param.int8(-1));
  });

  test('double, bool, String, DateTime, Uint8List', () {
    expectSame(inferParam('d', 1.5), Param.float8(1.5));
    expectSame(inferParam('b', true), Param.bool(true));
    expectSame(inferParam('s', 'x'), Param.text('x'));
    final t = DateTime.utc(2026, 11, 9, 12);
    expectSame(inferParam('t', t), Param.timestamptz(t));
    final bytes = Uint8List.fromList([1, 2, 3]);
    expectSame(inferParam('y', bytes), Param.bytea(bytes));
  });

  test('null is NULL with type OID 0', () {
    final p = inferParam('x', null);
    expect(p.oid, 0);
    expect(p.encode(), isNull);
  });

  test('a Param passes through unchanged', () {
    const p = Param.uuid('00000000-0000-0000-0000-000000000001');
    expect(inferParam('id', p), same(p));
  });

  test('collections and other types throw ArgumentError naming the key', () {
    for (final v in <Object>[
      {'a': 1},
      [1, 2],
      {1},
      Object(),
      Duration.zero,
    ]) {
      expect(
        () => inferParam('payload', v),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'payload')),
        reason: '$v',
      );
    }
  });
}
