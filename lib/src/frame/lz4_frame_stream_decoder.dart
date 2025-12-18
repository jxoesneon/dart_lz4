import 'dart:async';
import 'dart:typed_data';

import '../block/lz4_block_decoder.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';
import '../xxhash/xxh32.dart';

const _lz4FrameMagic = 0x184D2204;
const _lz4SkippableMagicBase = 0x184D2A50;
const _lz4SkippableMagicMask = 0xFFFFFFF0;
const _lz4LegacyFrameMagic = 0x184C2102;

StreamTransformer<List<int>, List<int>> lz4FrameDecoderTransformer({
  int? maxOutputBytes,
}) {
  return StreamTransformer.fromBind((input) async* {
    final decoder = _Lz4FrameStreamDecoder(maxOutputBytes: maxOutputBytes);

    await for (final chunk in input) {
      decoder.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      while (true) {
        final out = decoder.decodeNext();
        if (out == null) {
          break;
        }
        yield out;
      }
    }

    decoder.finish();
    while (true) {
      final out = decoder.decodeNext();
      if (out == null) {
        break;
      }
      yield out;
    }
  });
}

enum _State {
  magic,
  skippableSize,
  skippableSkip,
  frameDescriptor,
  headerChecksum,
  blockSize,
  blockData,
  blockChecksum,
  contentChecksum,
  legacyBlockSize,
  legacyBlockData,
  legacyAfterBlock,
}

final class _Lz4FrameStreamDecoder {
  final _ChunkBuffer _buf = _ChunkBuffer();
  final int? _maxOutputBytes;
  bool _finished = false;

  _State _state = _State.magic;

  int _skippableRemaining = 0;

  int _flg = 0;
  int _bd = 0;
  final List<int> _descriptorBytes = <int>[];

  bool _blockIndependence = true;
  bool _blockChecksum = false;
  bool _contentSizeFlag = false;
  bool _contentChecksumFlag = false;
  bool _dictIdFlag = false;

  int _blockMaxSize = 0;
  int? _contentSize;
  int? _dictId;

  int _currentBlockSize = 0;
  bool _currentBlockUncompressed = false;
  Uint8List? _currentBlockData;

  final Uint8List _history = Uint8List(64 * 1024);
  int _historyLen = 0;

  Xxh32? _contentHasher;

  int _frameProduced = 0;
  int _totalProduced = 0;

  int _legacyBlockCSize = 0;
  Uint8List? _legacyPending;
  int _legacyPendingLen = 0;

  _Lz4FrameStreamDecoder({int? maxOutputBytes})
      : _maxOutputBytes = maxOutputBytes;

  void add(Uint8List chunk) {
    _buf.add(chunk);
  }

  Uint8List? decodeNext() {
    while (true) {
      switch (_state) {
        case _State.magic:
          if (!_buf.has(4)) {
            return null;
          }
          final magic = _buf.readUint32LE();
          if ((magic & _lz4SkippableMagicMask) == _lz4SkippableMagicBase) {
            _state = _State.skippableSize;
            continue;
          }
          if (magic == _lz4LegacyFrameMagic) {
            _resetFrameState();
            _state = _State.legacyBlockSize;
            continue;
          }
          if (magic != _lz4FrameMagic) {
            throw const Lz4FormatException('Invalid LZ4 frame magic number');
          }
          _resetFrameState();
          _state = _State.frameDescriptor;
          continue;

        case _State.skippableSize:
          if (!_buf.has(4)) {
            return null;
          }
          _skippableRemaining = _buf.readUint32LE();
          _state = _State.skippableSkip;
          continue;

        case _State.skippableSkip:
          if (_skippableRemaining == 0) {
            _state = _State.magic;
            continue;
          }
          final skipped = _buf.skip(_skippableRemaining);
          _skippableRemaining -= skipped;
          if (_skippableRemaining != 0) {
            return null;
          }
          _state = _State.magic;
          continue;

        case _State.frameDescriptor:
          if (!_buf.has(2)) {
            return null;
          }

          final flg = _buf.peekUint8At(0);

          final contentSizeFlag = ((flg >> 3) & 0x01) != 0;
          final dictIdFlag = (flg & 0x01) != 0;
          final required = 2 + (contentSizeFlag ? 8 : 0) + (dictIdFlag ? 4 : 0);
          if (!_buf.has(required)) {
            return null;
          }

          _flg = _buf.readUint8();
          _bd = _buf.readUint8();
          _descriptorBytes
            ..clear()
            ..add(_flg)
            ..add(_bd);

          final version = (_flg >> 6) & 0x03;
          if (version != 0x01) {
            throw const Lz4UnsupportedFeatureException(
                'Unsupported LZ4 frame version');
          }

          _blockIndependence = ((_flg >> 5) & 0x01) != 0;
          _blockChecksum = ((_flg >> 4) & 0x01) != 0;
          _contentSizeFlag = ((_flg >> 3) & 0x01) != 0;
          _contentChecksumFlag = ((_flg >> 2) & 0x01) != 0;
          final reserved = (_flg >> 1) & 0x01;
          _dictIdFlag = (_flg & 0x01) != 0;

          if (reserved != 0) {
            throw const Lz4FormatException('Reserved FLG bit is set');
          }

          if ((_bd & 0x8F) != 0) {
            throw const Lz4FormatException('Reserved BD bits are set');
          }

          _blockMaxSize = _decodeBlockMaxSize((_bd >> 4) & 0x07);

          if (_contentSizeFlag) {
            final low = _buf.readUint32LE();
            final high = _buf.readUint32LE();
            _descriptorBytes.addAll(_u32le(low));
            _descriptorBytes.addAll(_u32le(high));
            if (high != 0) {
              throw const Lz4UnsupportedFeatureException(
                  'Content size > 4GiB is not supported');
            }
            _contentSize = low;
          }

          if (_dictIdFlag) {
            final id = _buf.readUint32LE();
            _descriptorBytes.addAll(_u32le(id));
            _dictId = id;
          }

          _state = _State.headerChecksum;
          continue;

        case _State.headerChecksum:
          if (!_buf.has(1)) {
            return null;
          }
          final hc = _buf.readUint8();
          final expectedHc =
              (xxh32(Uint8List.fromList(_descriptorBytes), seed: 0) >> 8) &
                  0xFF;
          if (hc != expectedHc) {
            throw const Lz4CorruptDataException('Header checksum mismatch');
          }

          if (_dictId != null) {
            throw const Lz4UnsupportedFeatureException(
                'Dictionary ID is not supported');
          }

          _contentHasher = _contentChecksumFlag ? Xxh32(seed: 0) : null;

          _state = _State.blockSize;
          continue;

        case _State.blockSize:
          if (!_buf.has(4)) {
            return null;
          }
          final blockSizeRaw = _buf.readUint32LE();
          if (blockSizeRaw == 0) {
            if (_contentChecksumFlag) {
              _state = _State.contentChecksum;
              continue;
            }
            _finishFrame();
            _state = _State.magic;
            continue;
          }

          _currentBlockUncompressed = (blockSizeRaw & 0x80000000) != 0;
          _currentBlockSize = blockSizeRaw & 0x7FFFFFFF;

          if (_currentBlockSize > _blockMaxSize) {
            throw const Lz4CorruptDataException('Block size exceeds maximum');
          }

          _state = _State.blockData;
          continue;

        case _State.blockData:
          if (!_buf.has(_currentBlockSize)) {
            return null;
          }
          _currentBlockData = _buf.readBytes(_currentBlockSize);

          if (_blockChecksum) {
            _state = _State.blockChecksum;
            continue;
          }

          final out = _decodeCurrentBlockAndUpdateState();
          if (out.isNotEmpty) {
            return out;
          }
          continue;

        case _State.blockChecksum:
          if (!_buf.has(4)) {
            return null;
          }
          final expected = _buf.readUint32LE();
          final blockData = _currentBlockData!;
          final actual = xxh32(blockData, seed: 0);
          if (actual != expected) {
            throw const Lz4CorruptDataException('Block checksum mismatch');
          }

          final out = _decodeCurrentBlockAndUpdateState();
          if (out.isNotEmpty) {
            return out;
          }
          continue;

        case _State.contentChecksum:
          if (!_buf.has(4)) {
            return null;
          }
          final expected = _buf.readUint32LE();
          final hasher = _contentHasher;
          final actual = hasher == null ? 0 : hasher.digest();
          if (actual != expected) {
            throw const Lz4CorruptDataException('Content checksum mismatch');
          }
          _finishFrame();
          _state = _State.magic;
          continue;

        case _State.legacyBlockSize:
          if (_legacyPending != null) {
            _state = _State.legacyAfterBlock;
            continue;
          }

          if (!_buf.has(4)) {
            if (_finished) {
              _state = _State.magic;
              continue;
            }
            return null;
          }

          final next = _buf.peekUint32LE();
          if (_isLegacyBoundary(next)) {
            _state = _State.magic;
            continue;
          }

          final cSize = _buf.readUint32LE();
          if (cSize == 0) {
            throw const Lz4CorruptDataException('Invalid legacy block size');
          }
          _legacyBlockCSize = cSize;
          _state = _State.legacyBlockData;
          continue;

        case _State.legacyBlockData:
          if (!_buf.has(_legacyBlockCSize)) {
            return null;
          }

          const legacyBlockMaxSize = 8 * 1024 * 1024;
          final blockData = _buf.readBytes(_legacyBlockCSize);
          final tmp = ByteWriter(maxLength: legacyBlockMaxSize);
          lz4BlockDecompressInto(blockData, tmp);
          final produced = tmp.toBytes();

          final maxOut = _maxOutputBytes;
          if (maxOut != null && _totalProduced + produced.length > maxOut) {
            throw const Lz4OutputLimitException('Output limit exceeded');
          }
          _totalProduced += produced.length;

          _legacyPending = produced;
          _legacyPendingLen = produced.length;
          _state = _State.legacyAfterBlock;
          continue;

        case _State.legacyAfterBlock:
          final pending = _legacyPending;
          if (pending == null) {
            _state = _State.legacyBlockSize;
            continue;
          }

          if (!_buf.has(4)) {
            if (!_finished) {
              return null;
            }
            _legacyPending = null;
            _legacyPendingLen = 0;
            _state = _State.magic;
            return pending;
          }

          final next = _buf.peekUint32LE();
          if (_isLegacyBoundary(next)) {
            _legacyPending = null;
            _legacyPendingLen = 0;
            _state = _State.magic;
            return pending;
          }

          if (_legacyPendingLen != 8 * 1024 * 1024) {
            throw const Lz4CorruptDataException('Legacy block is not full');
          }

          _legacyPending = null;
          _legacyPendingLen = 0;
          _state = _State.legacyBlockSize;
          return pending;
      }
    }
  }

  void finish() {
    _finished = true;
    if (_buf.length == 0 && _state == _State.magic) {
      return;
    }
    if (_state == _State.legacyAfterBlock && _legacyPending != null) {
      if (_buf.length == 0) {
        return;
      }
    }
    throw const Lz4FormatException('Unexpected end of input');
  }

  Uint8List _decodeCurrentBlockAndUpdateState() {
    final blockData = _currentBlockData!;

    Uint8List produced;
    if (_currentBlockUncompressed) {
      produced = blockData;
    } else {
      if (_blockIndependence) {
        final tmp = ByteWriter(maxLength: _blockMaxSize);
        lz4BlockDecompressInto(blockData, tmp);
        produced = tmp.toBytes();
      } else {
        final historyLen = _historyLen;
        final blockWriter = ByteWriter(maxLength: historyLen + _blockMaxSize);
        if (historyLen != 0) {
          blockWriter.writeBytesView(_history, 0, historyLen);
        }
        lz4BlockDecompressInto(blockData, blockWriter);

        final producedLen = blockWriter.length - historyLen;
        if (producedLen > _blockMaxSize) {
          throw const Lz4CorruptDataException('Block size exceeds maximum');
        }

        final decoded = blockWriter.bytesView();
        produced = Uint8List.fromList(decoded.sublist(historyLen));
      }
    }

    _currentBlockData = null;
    _state = _State.blockSize;

    if (produced.isEmpty) {
      return Uint8List(0);
    }

    final maxOut = _maxOutputBytes;
    if (maxOut != null && _totalProduced + produced.length > maxOut) {
      throw const Lz4OutputLimitException('Output limit exceeded');
    }

    _totalProduced += produced.length;
    _frameProduced += produced.length;

    _contentHasher?.update(produced);

    if (!_blockIndependence) {
      _appendHistory(produced);
    }

    return produced;
  }

  void _appendHistory(Uint8List bytes) {
    const window = 64 * 1024;

    if (bytes.length >= window) {
      final start = bytes.length - window;
      _history.setRange(0, window, bytes, start);
      _historyLen = window;
      return;
    }

    final required = _historyLen + bytes.length;
    if (required <= window) {
      _history.setRange(_historyLen, required, bytes);
      _historyLen = required;
      return;
    }

    final drop = required - window;
    final keep = _historyLen - drop;
    for (var i = 0; i < keep; i++) {
      _history[i] = _history[i + drop];
    }
    _historyLen -= drop;
    _history.setRange(_historyLen, _historyLen + bytes.length, bytes);
    _historyLen += bytes.length;
  }

  void _finishFrame() {
    final expectedSize = _contentSize;
    if (expectedSize != null && _frameProduced != expectedSize) {
      throw const Lz4CorruptDataException('Content size mismatch');
    }
  }

  void _resetFrameState() {
    _skippableRemaining = 0;

    _flg = 0;
    _bd = 0;
    _descriptorBytes.clear();

    _blockIndependence = true;
    _blockChecksum = false;
    _contentSizeFlag = false;
    _contentChecksumFlag = false;
    _dictIdFlag = false;

    _blockMaxSize = 0;
    _contentSize = null;
    _dictId = null;

    _currentBlockSize = 0;
    _currentBlockUncompressed = false;
    _currentBlockData = null;

    _historyLen = 0;

    _contentHasher = null;
    _frameProduced = 0;

    _legacyBlockCSize = 0;
    _legacyPending = null;
    _legacyPendingLen = 0;
  }
}

final class _ChunkBuffer {
  Uint8List _buffer;
  int _start;
  int _end;

  _ChunkBuffer({int initialCapacity = 1024})
      : _buffer = Uint8List(initialCapacity),
        _start = 0,
        _end = 0;

  int get length => _end - _start;

  bool has(int n) => length >= n;

  void add(Uint8List bytes) {
    if (bytes.isEmpty) {
      return;
    }
    _ensureCapacity(bytes.length);
    _buffer.setRange(_end, _end + bytes.length, bytes);
    _end += bytes.length;
  }

  int skip(int n) {
    final available = length;
    final toSkip = available < n ? available : n;
    _start += toSkip;
    return toSkip;
  }

  int readUint8() {
    if (!has(1)) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    return _buffer[_start++];
  }

  int readUint32LE() {
    if (!has(4)) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    final b0 = _buffer[_start];
    final b1 = _buffer[_start + 1];
    final b2 = _buffer[_start + 2];
    final b3 = _buffer[_start + 3];
    _start += 4;
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
  }

  int peekUint32LE() {
    if (!has(4)) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    final b0 = _buffer[_start];
    final b1 = _buffer[_start + 1];
    final b2 = _buffer[_start + 2];
    final b3 = _buffer[_start + 3];
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
  }

  int peekUint8At(int offset) {
    if (offset < 0) {
      throw RangeError.value(offset, 'offset');
    }
    final needed = offset + 1;
    if (!has(needed)) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    return _buffer[_start + offset];
  }

  Uint8List readBytes(int n) {
    if (n < 0) {
      throw RangeError.value(n, 'n');
    }
    if (!has(n)) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    final out = Uint8List.fromList(_buffer.sublist(_start, _start + n));
    _start += n;
    return out;
  }

  void _ensureCapacity(int additional) {
    final remaining = length;

    if (_start != 0 && (_end + additional > _buffer.length)) {
      for (var i = 0; i < remaining; i++) {
        _buffer[i] = _buffer[_start + i];
      }
      _start = 0;
      _end = remaining;
    }

    final needed = _end + additional;
    if (needed <= _buffer.length) {
      return;
    }

    var newCap = _buffer.length;
    while (newCap < needed) {
      newCap *= 2;
    }

    final next = Uint8List(newCap);
    next.setRange(0, remaining, _buffer, _start);
    _buffer = next;
    _start = 0;
    _end = remaining;
  }
}

int _decodeBlockMaxSize(int id) {
  switch (id) {
    case 4:
      return 64 * 1024;
    case 5:
      return 256 * 1024;
    case 6:
      return 1024 * 1024;
    case 7:
      return 4 * 1024 * 1024;
    default:
      throw const Lz4FormatException('Invalid block maximum size');
  }
}

List<int> _u32le(int v) =>
    <int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

bool _isLegacyBoundary(int magic) {
  if (magic == _lz4FrameMagic || magic == _lz4LegacyFrameMagic) {
    return true;
  }
  return (magic & _lz4SkippableMagicMask) == _lz4SkippableMagicBase;
}
