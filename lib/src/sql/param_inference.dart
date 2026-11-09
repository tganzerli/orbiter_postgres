import 'dart:typed_data';

import 'package:slingshot_postgres/slingshot_postgres.dart';

/// Converts a Dart value bound to placeholder `@name` into a [Param].
///
/// | Dart value  | Parameter                                   |
/// |-------------|---------------------------------------------|
/// | `Param`     | itself (explicit type: uuid, jsonb, numeric) |
/// | `int`       | `int8`                                      |
/// | `double`    | `float8`                                    |
/// | `bool`      | `bool`                                      |
/// | `String`    | `text`                                      |
/// | `DateTime`  | `timestamptz`                               |
/// | `Uint8List` | `bytea`                                     |
/// | `null`      | NULL with type OID 0 (type taken from context) |
///
/// A `String` travels as `text`: a `uuid`, `jsonb`, `numeric`, `inet` or
/// enum column needs a cast in the SQL (`@id::uuid`) or an explicit `Param`
/// (`Param.uuid(id)`). A `null` gets its type from where it is used (an
/// `INSERT` column, a comparison, an operator); where nothing fixes it
/// (`@x IS NULL`, a polymorphic argument such as `pg_typeof(@x)`) the server
/// refuses with "could not determine data type": cast it (`@x::int8`) or pass
/// `Param.nullValue(PostgresOid.int8)`. Any other type throws
/// [ArgumentError].
Param inferParam(String name, Object? value) => switch (value) {
      Param() => value,
      int() => Param.int8(value),
      double() => Param.float8(value),
      bool() => Param.bool(value),
      String() => Param.text(value),
      DateTime() => Param.timestamptz(value),
      Uint8List() => Param.bytea(value),
      null => const Param.nullValue(0),
      Map() || Iterable() => throw ArgumentError.value(
          value,
          name,
          'collections are not inferred; pass Param.jsonb(jsonEncode(value)) '
          'or Param.json(...)',
        ),
      _ => throw ArgumentError.value(
          value,
          name,
          'no parameter type is inferred for ${value.runtimeType}; '
          'pass an explicit Param',
        ),
    };
