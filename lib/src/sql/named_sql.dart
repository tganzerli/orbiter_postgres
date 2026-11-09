import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'param_inference.dart';

/// SQL with `@name` placeholders rewritten to PostgreSQL's positional `$N`.
///
/// Build it with [NamedSql.parse], or [NamedSql.cached] to reuse the
/// rewrite for a SQL text already seen in this isolate. The scanner leaves
/// untouched everything inside single-quoted literals (`''` escapes),
/// `E'...'` literals (backslash escapes), double-quoted identifiers, `--`
/// and nested `/* */` comments, and dollar-quoted bodies (`$$...$$`,
/// `$tag$...$tag$`).
///
/// Outside those, `@` starts a placeholder only when it is followed by a
/// letter, `_` or a non-ASCII character and does not close a built-in operator: it is not preceded
/// by a word character (`a@b`), by `<` (`<@`, so `a <@b` stays the
/// containment operator), by `@` (`@@`) or by `@-` (`@-@`). `@>` and `@ x`
/// are untouched because no letter follows. `x=@id`, `(@id`, `,@id` and
/// `-@id` are placeholders. The prefix absolute-value operator must be
/// written with a space (`@ x`) or as `abs(x)`; `@x` is read as a
/// placeholder.
///
/// A name used more than once maps to the same `$N`. SQL that mixes
/// positional `$N` with `@name` is rejected with a [FormatException].
final class NamedSql {
  /// The SQL with every `@name` replaced by its `$N`.
  final String sql;

  /// Distinct placeholder names in `$N` order: `names[0]` is `$1`.
  final List<String> names;

  const NamedSql._(this.sql, this.names);

  /// Maximum number of SQL texts kept by [cached] per isolate. When full,
  /// the oldest entry is dropped.
  static const int cacheCapacity = 256;

  static final Map<String, NamedSql> _cache = <String, NamedSql>{};

  /// Returns the rewrite of [sql], parsing it only the first time this
  /// isolate sees that exact text.
  static NamedSql cached(String sql) {
    final hit = _cache[sql];
    if (hit != null) return hit;
    final parsed = parse(sql);
    if (_cache.length >= cacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    _cache[sql] = parsed;
    return parsed;
  }

  /// Number of entries currently held by [cached] in this isolate.
  static int get cacheSize => _cache.length;

  /// Empties the [cached] store of this isolate.
  static void clearCache() => _cache.clear();

  /// Rewrites [sql] without touching the cache.
  static NamedSql parse(String sql) => _Scanner(sql).run();

  /// Builds the positional parameter list for [params], in `$N` order.
  ///
  /// Throws [ArgumentError] when a placeholder has no entry in [params], or
  /// when [params] is not empty but the SQL has no placeholder (usually
  /// `\$N` written where `@name` was meant). When the SQL has placeholders,
  /// extra keys are ignored, so one map can serve several queries. Values go through the inference documented on
  /// `SqlFirstQueries`.
  List<Param> bind(Map<String, Object?> params) {
    if (names.isEmpty) {
      if (params.isNotEmpty) {
        throw ArgumentError.value(
          params.keys.toList(),
          'params',
          'the SQL has no @name placeholder',
        );
      }
      return const <Param>[];
    }
    return [
      for (final name in names)
        if (params.containsKey(name))
          inferParam(name, params[name])
        else
          throw ArgumentError.value(
            name,
            'params',
            'no value for placeholder @$name',
          ),
    ];
  }
}

const int _quote = 0x27; // '
const int _dquote = 0x22; // "
const int _dollar = 0x24; // $
const int _at = 0x40; // @
const int _dash = 0x2D; // -
const int _lt = 0x3C; // <
const int _slash = 0x2F; // /
const int _star = 0x2A; // *
const int _backslash = 0x5C; // \
const int _newline = 0x0A;

bool _isLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Identifier characters, including any non-ASCII code unit.
bool _isWord(int c) => _isLetter(c) || _isDigit(c) || c >= 0x80;

final class _Scanner {
  final String src;
  final List<int> cu;
  final StringBuffer out = StringBuffer();
  final Map<String, int> index = <String, int>{};
  final List<String> order = <String>[];
  bool positional = false;

  /// Start of the source span not yet copied to [out].
  int copied = 0;
  int i = 0;

  _Scanner(this.src) : cu = src.codeUnits;

  int at(int k) => k < cu.length ? cu[k] : -1;

  NamedSql run() {
    while (i < cu.length) {
      final c = cu[i];
      if (c == _quote) {
        final escapes = i > 0 &&
            (cu[i - 1] == 0x45 || cu[i - 1] == 0x65) &&
            (i < 2 || !_isWord(cu[i - 2]));
        i = _skipQuoted(i + 1, _quote, backslash: escapes);
      } else if (c == _dquote) {
        i = _skipQuoted(i + 1, _dquote, backslash: false);
      } else if (c == _dash && at(i + 1) == _dash) {
        while (i < cu.length && cu[i] != _newline) {
          i++;
        }
      } else if (c == _slash && at(i + 1) == _star) {
        i = _skipBlockComment(i);
      } else if (c == _dollar) {
        i = _scanDollar(i);
      } else if (c == _at) {
        i = _scanAt(i);
      } else {
        i++;
      }
    }
    if (order.isEmpty) return NamedSql._(src, const <String>[]);
    if (positional) {
      throw FormatException(
        'SQL mixes positional \$N parameters with @name placeholders',
        src,
      );
    }
    out.write(src.substring(copied));
    return NamedSql._(out.toString(), List.unmodifiable(order));
  }

  /// Returns the index after the closing [delim]; a doubled delimiter is an
  /// escaped one. Unterminated input runs to the end.
  int _skipQuoted(int k, int delim, {required bool backslash}) {
    while (k < cu.length) {
      final c = cu[k];
      if (backslash && c == _backslash) {
        k += 2;
      } else if (c == delim) {
        if (at(k + 1) == delim) {
          k += 2;
        } else {
          return k + 1;
        }
      } else {
        k++;
      }
    }
    return cu.length;
  }

  /// PostgreSQL block comments nest.
  int _skipBlockComment(int k) {
    var depth = 0;
    while (k < cu.length) {
      if (cu[k] == _slash && at(k + 1) == _star) {
        depth++;
        k += 2;
      } else if (cu[k] == _star && at(k + 1) == _slash) {
        depth--;
        k += 2;
        if (depth == 0) return k;
      } else {
        k++;
      }
    }
    return cu.length;
  }

  int _scanDollar(int k) {
    if (k > 0 && _isWord(cu[k - 1])) return k + 1; // inside an identifier
    if (_isDigit(at(k + 1))) {
      positional = true;
      return k + 1;
    }
    // Dollar-quote opening: `$$` or `$tag$`.
    var e = k + 1;
    if (_isLetter(at(e))) {
      while (e < cu.length && (_isLetter(cu[e]) || _isDigit(cu[e]))) {
        e++;
      }
    }
    if (at(e) != _dollar) return k + 1;
    final delim = src.substring(k, e + 1);
    final close = src.indexOf(delim, e + 1);
    return close < 0 ? cu.length : close + delim.length;
  }

  int _scanAt(int k) {
    final next = at(k + 1);
    if (next == _at) return k + 2; // `@@` text-search match
    final prev = k > 0 ? cu[k - 1] : -1;
    final closesOperator = prev == _lt ||
        prev == _at ||
        (prev == _dash && k > 1 && cu[k - 2] == _at);
    final startsName = _isLetter(next) || next >= 0x80;
    if (!startsName || _isWord(prev) || closesOperator) return k + 1;
    var e = k + 1;
    while (e < cu.length && _isWord(cu[e])) {
      e++;
    }
    final name = src.substring(k + 1, e);
    final n = index.putIfAbsent(name, () {
      order.add(name);
      return order.length;
    });
    out
      ..write(src.substring(copied, k))
      ..write('\$')
      ..write(n);
    copied = e;
    return e;
  }
}
