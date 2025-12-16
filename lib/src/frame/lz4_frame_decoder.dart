import 'dart:typed_data';

import '../block/lz4_block_decoder.dart';
import '../internal/byte_reader.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';
import '../xxhash/xxh32.dart';

const _lz4FrameMagic = 0x184D2204;
const _lz4SkippableMagicBase = 0x184D2A50;
const _lz4SkippableMagicMask = 0xFFFFFFF0;

Uint8List lz4FrameDecodeBytes(
  Uint8List src, {
  int? maxOutputBytes,
}) {
  return _Lz4FrameDecoder(src, maxOutputBytes: maxOutputBytes).decodeAll();
}

final class _Lz4FrameDecoder {
  final Uint8List _src;
  final ByteReader _reader;
  final ByteWriter _out;
  final int? _maxOutputBytes;

  _Lz4FrameDecoder(this._src, {int? maxOutputBytes})
      : _reader = ByteReader(_src),
        _out = ByteWriter(maxLength: maxOutputBytes),
        _maxOutputBytes = maxOutputBytes;

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
    _reader.skip(size);
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
      contentSize = _readUint64LEAsInt(_reader);
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
      throw const Lz4UnsupportedFeatureException(
          'Dictionary ID is not supported');
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
        final tmp = ByteWriter(maxLength: blockMaxSize);
        lz4BlockDecompressInto(blockData, tmp);
        final decoded = tmp.bytesView();
        frameOut.writeBytesView(decoded, 0, decoded.length);
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
    final historyLen =
        frameOut.length < historyWindow ? frameOut.length : historyWindow;

    final historyStart = frameOut.length - historyLen;
    final history = Uint8List.sublistView(
        frameOut.bytesView(), historyStart, frameOut.length);

    final blockWriter = ByteWriter(maxLength: historyLen + blockMaxSize);
    if (historyLen != 0) {
      blockWriter.writeBytesView(history, 0, history.length);
    }

    lz4BlockDecompressInto(blockData, blockWriter);

    final produced = blockWriter.length - historyLen;
    if (produced > blockMaxSize) {
      throw const Lz4CorruptDataException('Block size exceeds maximum');
    }

    final decoded = blockWriter.bytesView();
    frameOut.writeBytesView(decoded, historyLen, decoded.length);
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

int _readUint64LEAsInt(ByteReader reader) {
  final low = reader.readUint32LE();
  final high = reader.readUint32LE();
  if (high != 0) {
    throw const Lz4UnsupportedFeatureException(
        'Content size > 4GiB is not supported');
  }
  return low;
}
