import 'dart:typed_data';

import '_wildcopy_stub.dart'
    if (dart.library.io) '_wildcopy_vm.dart'
    if (dart.library.js_interop) '_wildcopy_web.dart'
    if (dart.library.html) '_wildcopy_web.dart';
import 'lz4_buffer_pool.dart';
import 'lz4_exception.dart';

final class ByteWriter {
  Uint8List _buffer;
  int _length;
  int _blockStartOffset;
  final int? _maxLength;
  final Lz4BufferPool? _bufferPool;
  final bool _isFixed;

  ByteWriter({
    int initialCapacity = 0,
    int? maxLength,
    Lz4BufferPool? bufferPool,
    int blockStartOffset = 0,
  })  : _bufferPool = bufferPool,
        _buffer =
            bufferPool?.checkout(initialCapacity < 0 ? 0 : initialCapacity) ??
                Uint8List(initialCapacity < 0 ? 0 : initialCapacity),
        _length = 0,
        _blockStartOffset = blockStartOffset,
        _maxLength = maxLength,
        _isFixed = false {
    if (initialCapacity < 0) {
      throw RangeError.value(initialCapacity, 'initialCapacity');
    }
    if (maxLength != null && maxLength < 0) {
      throw RangeError.value(maxLength, 'maxLength');
    }
    if (blockStartOffset < 0) {
      throw RangeError.value(blockStartOffset, 'blockStartOffset');
    }
  }

  ByteWriter.forBuffer(
    Uint8List buffer, {
    int offset = 0,
    int? maxLength,
  })  : _buffer = buffer,
        _length = offset,
        _blockStartOffset = offset,
        _maxLength = maxLength,
        _bufferPool = null,
        _isFixed = true {
    if (offset < 0 || offset > buffer.length) {
      throw RangeError.range(offset, 0, buffer.length, 'offset');
    }
    if (maxLength != null && maxLength < 0) {
      throw RangeError.value(maxLength, 'maxLength');
    }
  }

  bool get isFixed => _isFixed;

  int get blockStartOffset => _blockStartOffset;

  set blockStartOffset(int offset) {
    if (offset < 0 || offset > _length) {
      throw RangeError.range(offset, 0, _length, 'blockStartOffset');
    }
    _blockStartOffset = offset;
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

  Uint8List toBytes() => _buffer.sublist(0, _length);

  void clear() {
    _length = _isFixed ? _blockStartOffset : 0;
  }

  /// Releases the internal buffer back to the pool if one is used.
  /// After calling this, the [ByteWriter] should no longer be used.
  void release() {
    final bufferPool = _bufferPool;
    if (bufferPool != null) {
      bufferPool.checkin(_buffer);
      _buffer = Uint8List(0);
      _length = 0;
    }
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

  void copyMatch(int distance, int matchLength, [int? blockStartOffset]) {
    if (matchLength < 0) {
      throw RangeError.value(matchLength, 'matchLength');
    }
    final start = blockStartOffset ?? _blockStartOffset;
    if (start < 0 || start > _length) {
      throw RangeError.range(start, 0, _length, 'blockStartOffset');
    }
    if (distance <= 0 || distance > _length - start) {
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

    if (distance >= matchLength) {
      _buffer.setRange(destStart, end, _buffer, destStart - distance);
      _length = end;
      return;
    }

    var dest = destStart;

    if (distance >= wildCopyMinDistance && matchLength >= wildCopyMinDistance) {
      final bd = ByteData.view(_buffer.buffer, _buffer.offsetInBytes);
      final limit = end - wildCopyLimitOffset;
      dest = wildCopy(bd, dest, distance, limit);
    }

    for (; dest < end; dest++) {
      _buffer[dest] = _buffer[dest - distance];
    }

    _length = end;
  }

  static const int _maxSafeCapacity = 0x7FFFFFFF; // 2GB

  void _ensureCapacity(int additional) {
    assert(additional >= 0);

    final newLength = _length + additional;
    if (_isFixed) {
      if (newLength > _buffer.length) {
        throw const Lz4OutputLimitException('Destination buffer too small');
      }
      final maxLen = _maxLength;
      if (maxLen != null && newLength > maxLen) {
        throw const Lz4OutputLimitException('Output limit exceeded');
      }
      return;
    }

    final maxLength = _maxLength ?? _maxSafeCapacity;
    if (newLength > maxLength) {
      throw const Lz4OutputLimitException('Output limit exceeded');
    }

    if (newLength <= _buffer.length) {
      return;
    }

    var newCapacity = _buffer.isEmpty ? 64 : _buffer.length;
    while (newCapacity < newLength) {
      if (newCapacity <= _maxSafeCapacity ~/ 2) {
        newCapacity *= 2;
      } else {
        newCapacity = _maxSafeCapacity;
      }
    }

    if (newCapacity > maxLength) {
      newCapacity = maxLength;
    }

    final next = _bufferPool?.checkout(newCapacity) ?? Uint8List(newCapacity);
    next.setRange(0, _length, _buffer);
    final bufferPool = _bufferPool;
    if (bufferPool != null) {
      bufferPool.checkin(_buffer);
    }
    _buffer = next;
  }
}
