import 'dart:typed_data';

import 'lz4_exception.dart';

final class ByteReader {
  final Uint8List _bytes;
  int _offset;

  ByteReader(Uint8List bytes, {int offset = 0})
      : _bytes = bytes,
        _offset = offset {
    if (offset < 0 || offset > bytes.length) {
      throw RangeError.range(offset, 0, bytes.length, 'offset');
    }
  }

  int get offset => _offset;

  int get length => _bytes.length;

  int get remaining => _bytes.length - _offset;

  bool get isEOF => _offset >= _bytes.length;

  void skip(int count) {
    if (count < 0) {
      throw RangeError.value(count, 'count');
    }
    _require(count);
    _offset += count;
  }

  int readUint8() {
    _require(1);
    return _bytes[_offset++];
  }

  int readUint16LE() {
    _require(2);
    final b0 = _bytes[_offset++];
    final b1 = _bytes[_offset++];
    return b0 | (b1 << 8);
  }

  int readUint32LE() {
    _require(4);
    final b0 = _bytes[_offset++];
    final b1 = _bytes[_offset++];
    final b2 = _bytes[_offset++];
    final b3 = _bytes[_offset++];
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
  }

  int readUint64LE() {
    _require(8);
    final b0 = _bytes[_offset++];
    final b1 = _bytes[_offset++];
    final b2 = _bytes[_offset++];
    final b3 = _bytes[_offset++];
    final b4 = _bytes[_offset++];
    final b5 = _bytes[_offset++];
    final b6 = _bytes[_offset++];
    final b7 = _bytes[_offset++];

    final low = (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
    final high = (b4 | (b5 << 8) | (b6 << 16) | (b7 << 24)) & 0xffffffff;

    // Check for potential precision loss on Web (JS 53-bit integers).
    // 2^53 - 1 = 9007199254740991
    if (high > 0x1FFFFF || (high == 0x200000 && low > 0)) {
      if (identical(0, 0.0)) {
        throw const Lz4FormatException(
            '64-bit content size overflow/Web precision loss');
      }
    }

    // Use arithmetic to combine high and low to support > 2^32 on Web (up to 2^53).
    // On VM, this works for the full signed 64-bit range.
    final value = (high * 4294967296) + low;

    // If the value is negative, it means it exceeded the positive range of Dart's int
    // (63 bits on VM).
    if (value < 0) {
      throw const Lz4FormatException(
          '64-bit content size overflow/Web precision loss');
    }

    return value;
  }

  Uint8List readBytesView(int count) {
    if (count < 0) {
      throw RangeError.value(count, 'count');
    }
    _require(count);
    final start = _offset;
    _offset += count;
    return Uint8List.sublistView(_bytes, start, _offset);
  }

  int peekUint8([int lookahead = 0]) {
    final index = _offset + lookahead;
    if (lookahead < 0) {
      throw RangeError.value(lookahead, 'lookahead');
    }
    if (index < 0 || index >= _bytes.length) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    return _bytes[index];
  }

  void _require(int count) {
    if (_offset + count > _bytes.length) {
      throw const Lz4FormatException('Unexpected end of input');
    }
  }
}
