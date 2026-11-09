import 'dart:convert';

/// CRC-32 (IEEE 802.3, reflected polynomial `0xEDB88320`) of [text] as
/// UTF-8, after normalising `\r\n` to `\n` so a checkout with
/// `core.autocrlf` does not look like an edited file.
///
/// Detects accidental edits of an applied script; it is not a
/// cryptographic hash.
int scriptChecksum(String text) =>
    crc32(utf8.encode(text.replaceAll('\r\n', '\n')));

/// CRC-32 of [bytes].
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final List<int> _table = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
}, growable: false);
