import 'dart:typed_data';

import 'lz4_exception.dart';

final class ByteWriter {
  Uint8List _buffer;
  int _length;
  final int? _maxLength;

  ByteWriter({int initialCapacity = 0, int? maxLength})
      : _buffer = Uint8List(initialCapacity < 0 ? 0 : initialCapacity),
        _length = 0,
        _maxLength = maxLength {
    if (initialCapacity < 0) {
      throw RangeError.value(initialCapacity, 'initialCapacity');
    }
    if (maxLength != null && maxLength < 0) {
      throw RangeError.value(maxLength, 'maxLength');
    }
  }

  int get length => _length;

  set length(int newLength) {
    if (newLength < 0 || newLength > _buffer.length) {
      throw RangeError.range(newLength, 0, _buffer.length, 'newLength');
    }
    _length = newLength;
  }

  int get remainingCapacity => _buffer.length - _length;

  Uint8List bytesView() => Uint8List.sublistView(_buffer, 0, _length);

  Uint8List toBytes() => Uint8List.fromList(_buffer.sublist(0, _length));

  void clear() {
    _length = 0;
  }

  void writeUint8(int value) {
    _ensureCapacity(1);
    _buffer[_length++] = value & 0xff;
  }

  void writeUint16LE(int value) {
    _ensureCapacity(2);
    _buffer[_length++] = value & 0xff;
    _buffer[_length++] = (value >> 8) & 0xff;
  }

  void writeUint32LE(int value) {
    _ensureCapacity(4);
    _buffer[_length++] = value & 0xff;
    _buffer[_length++] = (value >> 8) & 0xff;
    _buffer[_length++] = (value >> 16) & 0xff;
    _buffer[_length++] = (value >> 24) & 0xff;
  }

  void writeUint32LEAt(int index, int value) {
    if (index < 0 || index + 4 > _length) {
      throw RangeError.range(index, 0, _length - 4, 'index');
    }
    _buffer[index] = value & 0xff;
    _buffer[index + 1] = (value >> 8) & 0xff;
    _buffer[index + 2] = (value >> 16) & 0xff;
    _buffer[index + 3] = (value >> 24) & 0xff;
  }

  void writeBytes(Uint8List bytes) {
    writeBytesView(bytes, 0, bytes.length);
  }

  void writeBytesView(Uint8List bytes, int start, int end) {
    if (start < 0 || end < start || end > bytes.length) {
      throw RangeError.range(start, 0, bytes.length, 'start');
    }
    final count = end - start;
    _ensureCapacity(count);
    _buffer.setRange(_length, _length + count, bytes, start);
    _length += count;
  }

  void writeRepeatedByte(int byte, int count) {
    if (count < 0) {
      throw RangeError.value(count, 'count');
    }
    _ensureCapacity(count);
    _buffer.fillRange(_length, _length + count, byte & 0xff);
    _length += count;
  }

  void copyMatch(int distance, int matchLength) {
    if (matchLength < 0) {
      throw RangeError.value(matchLength, 'matchLength');
    }
    if (distance <= 0 || distance > _length) {
      throw const Lz4CorruptDataException('Invalid match distance');
    }
    if (matchLength == 0) {
      return;
    }

    _ensureCapacity(matchLength);

    final destStart = _length;
    final end = destStart + matchLength;

    if (distance == 1) {
      final value = _buffer[destStart - 1];
      _buffer.fillRange(destStart, end, value);
      _length = end;
      return;
    }

    for (var dest = destStart; dest < end; dest++) {
      _buffer[dest] = _buffer[dest - distance];
    }

    _length = end;
  }

  void _ensureCapacity(int additional) {
    if (additional < 0) {
      throw RangeError.value(additional, 'additional');
    }

    final newLength = _length + additional;
    final maxLength = _maxLength;
    if (maxLength != null && newLength > maxLength) {
      throw const Lz4OutputLimitException('Output limit exceeded');
    }

    if (newLength <= _buffer.length) {
      return;
    }

    var newCapacity = _buffer.isEmpty ? 64 : _buffer.length;
    while (newCapacity < newLength) {
      newCapacity *= 2;
    }

    if (maxLength != null && newCapacity > maxLength) {
      newCapacity = maxLength;
      if (newCapacity < newLength) {
        throw const Lz4OutputLimitException('Output limit exceeded');
      }
    }

    final next = Uint8List(newCapacity);
    next.setRange(0, _length, _buffer);
    _buffer = next;
  }
}
