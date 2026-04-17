import 'dart:typed_data';

import '../block/lz4_block_decoder.dart';
import '../internal/byte_reader.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';
import '../xxhash/xxh32.dart';
import 'lz4_frame_options.dart';

const _lz4FrameMagic = 0x184D2204;
const _lz4SkippableMagicBase = 0x184D2A50;
const _lz4SkippableMagicMask = 0xFFFFFFF0;
const _lz4LegacyFrameMagic = 0x184C2102;

Uint8List lz4FrameDecodeBytes(
  Uint8List src, {
  int? maxOutputBytes,
  Lz4DictionaryResolver? dictionaryResolver,
}) {
  // If maxOutputBytes is omitted, we use a default limit of 256MB to prevent
  // decompression bombs from exhausting memory. Users can override this by
  // providing their own limit.
  const defaultMaxOutputBytes = 256 * 1024 * 1024;
  return _Lz4FrameDecoder(
    src,
    maxOutputBytes: maxOutputBytes ?? defaultMaxOutputBytes,
    dictionaryResolver: dictionaryResolver,
  ).decodeAll();
}

final class _Lz4FrameDecoder {
  final Uint8List _src;
  final ByteReader _reader;
  final ByteWriter _out;
  final int? _maxOutputBytes;
  final Lz4DictionaryResolver? _dictionaryResolver;

  Uint8List? _dict;

  _Lz4FrameDecoder(
    this._src, {
    int? maxOutputBytes,
    Lz4DictionaryResolver? dictionaryResolver,
  })  : _reader = ByteReader(_src),
        _out = ByteWriter(maxLength: maxOutputBytes),
        _maxOutputBytes = maxOutputBytes,
        _dictionaryResolver = dictionaryResolver;

  Uint8List decodeAll() {
    while (!_reader.isEOF) {
      _decodeNextFrameOrSkippable();
    }
    return _out.toBytes();
  }

  void _decodeNextFrameOrSkippable() {
    if (_reader.remaining < 4) {
      throw const Lz4FormatException('Unexpected end of input');
    }

    final magic = _reader.readUint32LE();

    if ((magic & _lz4SkippableMagicMask) == _lz4SkippableMagicBase) {
      _skipSkippableFrame();
      return;
    }

    if (magic == _lz4LegacyFrameMagic) {
      final decoded = _decodeLegacyFrame();
      _out.writeBytes(decoded);
      return;
    }

    if (magic != _lz4FrameMagic) {
      throw const Lz4FormatException('Invalid LZ4 frame magic number');
    }

    final decoded = _decodeFrame();
    _out.writeBytes(decoded);
  }

  void _skipSkippableFrame() {
    if (_reader.remaining < 4) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    final size = _reader.readUint32LE();
    // Reasonable upper bound for skippable frames (2GB)
    if (size > 0x7FFFFFFF) {
      throw const Lz4FormatException('Skippable frame size too large');
    }
    _reader.skip(size);
  }

  Uint8List _decodeLegacyFrame() {
    const legacyBlockMaxSize = 8 * 1024 * 1024;

    final remaining =
        _maxOutputBytes == null ? null : _maxOutputBytes - _out.length;
    if (remaining != null && remaining < 0) {
      throw const Lz4OutputLimitException('Output limit exceeded');
    }

    final frameOut = ByteWriter(maxLength: remaining);

    while (true) {
      if (_reader.remaining == 0) {
        break;
      }
      if (_reader.remaining < 4) {
        throw const Lz4FormatException('Unexpected end of input');
      }

      final next = _peekUint32LE();
      if (_isLegacyBoundary(next)) {
        break;
      }

      final blockCSize = _reader.readUint32LE();
      if (blockCSize == 0) {
        throw const Lz4CorruptDataException('Invalid legacy block size');
      }

      final blockData = _reader.readBytesView(blockCSize);
      final tmp = ByteWriter(maxLength: legacyBlockMaxSize);
      lz4BlockDecompressInto(blockData, tmp);
      final decoded = tmp.bytesView();
      frameOut.writeBytesView(decoded, 0, decoded.length);

      if (_reader.remaining == 0) {
        break;
      }
      if (_reader.remaining < 4) {
        throw const Lz4FormatException('Unexpected end of input');
      }

      final after = _peekUint32LE();
      final hasNextBlock = !_isLegacyBoundary(after);
      if (hasNextBlock && decoded.length != legacyBlockMaxSize) {
        throw const Lz4CorruptDataException('Legacy block is not full');
      }
    }

    return frameOut.toBytes();
  }

  int _peekUint32LE() {
    if (_reader.remaining < 4) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    final o = _reader.offset;
    final b0 = _src[o];
    final b1 = _src[o + 1];
    final b2 = _src[o + 2];
    final b3 = _src[o + 3];
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
  }

  bool _isLegacyBoundary(int magic) {
    if (magic == _lz4FrameMagic || magic == _lz4LegacyFrameMagic) {
      return true;
    }
    return (magic & _lz4SkippableMagicMask) == _lz4SkippableMagicBase;
  }

  Uint8List _decodeFrame() {
    final remaining =
        _maxOutputBytes == null ? null : _maxOutputBytes - _out.length;
    if (remaining != null && remaining < 0) {
      throw const Lz4OutputLimitException('Output limit exceeded');
    }

    final frameOut = ByteWriter(maxLength: remaining);

    final descriptorStart = _reader.offset;

    if (_reader.remaining < 3) {
      throw const Lz4FormatException('Unexpected end of input');
    }

    final flg = _reader.readUint8();
    final bd = _reader.readUint8();

    final version = (flg >> 6) & 0x03;
    if (version != 0x01) {
      throw const Lz4UnsupportedFeatureException(
          'Unsupported LZ4 frame version');
    }

    final blockIndependence = ((flg >> 5) & 0x01) != 0;
    final blockChecksum = ((flg >> 4) & 0x01) != 0;
    final contentSizeFlag = ((flg >> 3) & 0x01) != 0;
    final contentChecksumFlag = ((flg >> 2) & 0x01) != 0;
    final reserved = (flg >> 1) & 0x01;
    final dictIdFlag = (flg & 0x01) != 0;

    if (reserved != 0) {
      throw const Lz4FormatException('Reserved FLG bit is set');
    }

    if ((bd & 0x8F) != 0) {
      throw const Lz4FormatException('Reserved BD bits are set');
    }

    final blockMaxSizeId = (bd >> 4) & 0x07;
    final blockMaxSize = _decodeBlockMaxSize(blockMaxSizeId);

    int? contentSize;
    if (contentSizeFlag) {
      if (_reader.remaining < 8) {
        throw const Lz4FormatException('Unexpected end of input');
      }
      contentSize = _reader.readUint64LE();
      if (_maxOutputBytes != null && contentSize > _maxOutputBytes) {
        throw const Lz4OutputLimitException(
            'Content size exceeds output limit');
      }
    }

    int? dictId;
    if (dictIdFlag) {
      if (_reader.remaining < 4) {
        throw const Lz4FormatException('Unexpected end of input');
      }
      dictId = _reader.readUint32LE();
    }

    final descriptorEnd = _reader.offset;

    final hc = _reader.readUint8();
    final descriptorBytes =
        Uint8List.sublistView(_src, descriptorStart, descriptorEnd);
    final expectedHc = (xxh32(descriptorBytes, seed: 0) >> 8) & 0xFF;
    if (hc != expectedHc) {
      throw const Lz4CorruptDataException('Header checksum mismatch');
    }

    if (dictId != null) {
      final resolver = _dictionaryResolver;
      if (resolver == null) {
        throw const Lz4UnsupportedFeatureException(
            'Dictionary ID present but no dictionary resolver provided');
      }
      final dict = resolver(dictId);
      if (dict == null) {
        throw Lz4Exception('Dictionary not found for ID: $dictId');
      }
      _dict = dict;
    }

    while (true) {
      if (_reader.remaining < 4) {
        throw const Lz4FormatException('Unexpected end of input');
      }

      final blockSizeRaw = _reader.readUint32LE();
      if (blockSizeRaw == 0) {
        break;
      }

      final isUncompressed = (blockSizeRaw & 0x80000000) != 0;
      final blockSize = blockSizeRaw & 0x7FFFFFFF;

      if (blockSize > blockMaxSize) {
        throw const Lz4CorruptDataException('Block size exceeds maximum');
      }

      final blockData = _reader.readBytesView(blockSize);

      if (blockChecksum) {
        if (_reader.remaining < 4) {
          throw const Lz4FormatException('Unexpected end of input');
        }
        final expected = _reader.readUint32LE();
        final actual = xxh32(blockData, seed: 0);
        if (actual != expected) {
          throw const Lz4CorruptDataException('Block checksum mismatch');
        }
      }

      if (isUncompressed) {
        frameOut.writeBytesView(blockData, 0, blockData.length);
        continue;
      }

      if (blockIndependence) {
        final dict = _dict;
        if (dict != null) {
          // Independent blocks with dictionary:
          // The dictionary is used as history for THIS block only.
          const historyWindow = 64 * 1024;
          final dictLen = dict.length;
          final effectiveDictLen =
              dictLen > historyWindow ? historyWindow : dictLen;
          final effectiveDictStart = dictLen - effectiveDictLen;

          final tmp = ByteWriter(maxLength: effectiveDictLen + blockMaxSize);
          tmp.writeBytesView(dict, effectiveDictStart, dictLen);
          lz4BlockDecompressInto(blockData, tmp);
          final decodedFull = tmp.bytesView();
          // Skip the dictionary part
          final decoded = Uint8List.sublistView(decodedFull, effectiveDictLen);
          frameOut.writeBytesView(decoded, 0, decoded.length);
        } else {
          final tmp = ByteWriter(maxLength: blockMaxSize);
          lz4BlockDecompressInto(blockData, tmp);
          final decoded = tmp.bytesView();
          frameOut.writeBytesView(decoded, 0, decoded.length);
        }
      } else {
        _decodeDependentBlock(
          blockData,
          frameOut,
          blockMaxSize: blockMaxSize,
        );
      }
    }

    if (contentChecksumFlag) {
      if (_reader.remaining < 4) {
        throw const Lz4FormatException('Unexpected end of input');
      }
      final expected = _reader.readUint32LE();
      final actual = xxh32(frameOut.bytesView(), seed: 0);
      if (actual != expected) {
        throw const Lz4CorruptDataException('Content checksum mismatch');
      }
    }

    if (contentSize != null) {
      if (frameOut.length != contentSize) {
        throw const Lz4CorruptDataException('Content size mismatch');
      }
    }

    return frameOut.toBytes();
  }

  void _decodeDependentBlock(
    Uint8List blockData,
    ByteWriter frameOut, {
    required int blockMaxSize,
  }) {
    const historyWindow = 64 * 1024;

    // Calculate available history from output
    final outLen = frameOut.length;
    final outHistoryLen = outLen < historyWindow ? outLen : historyWindow;

    final ByteWriter blockWriter;
    int prefixLen;

    final dict = _dict;
    // If output history is insufficient and we have a dictionary, use it.
    if (outHistoryLen < historyWindow && dict != null) {
      // We need to fill the gap with dictionary data.
      final needed = historyWindow - outHistoryLen;
      final dictLen = dict.length;
      final copyLen = dictLen < needed ? dictLen : needed;
      final copyStart = dictLen - copyLen;

      prefixLen = copyLen + outHistoryLen;
      blockWriter = ByteWriter(maxLength: prefixLen + blockMaxSize);

      // Write dictionary part
      blockWriter.writeBytesView(dict, copyStart, dictLen);

      // Write output history part
      final outHistoryStart = outLen - outHistoryLen;
      final outHistory =
          Uint8List.sublistView(frameOut.bytesView(), outHistoryStart, outLen);
      blockWriter.writeBytesView(outHistory, 0, outHistory.length);
    } else {
      // Standard dependent block (or sufficient history)
      prefixLen = outHistoryLen;
      blockWriter = ByteWriter(maxLength: prefixLen + blockMaxSize);

      final outHistoryStart = outLen - outHistoryLen;
      final outHistory =
          Uint8List.sublistView(frameOut.bytesView(), outHistoryStart, outLen);
      if (prefixLen > 0) {
        blockWriter.writeBytesView(outHistory, 0, outHistory.length);
      }
    }

    lz4BlockDecompressInto(blockData, blockWriter);

    final produced = blockWriter.length - prefixLen;
    if (produced > blockMaxSize) {
      throw const Lz4CorruptDataException('Block size exceeds maximum');
    }

    final decoded = blockWriter.bytesView();
    frameOut.writeBytesView(decoded, prefixLen, decoded.length);
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
