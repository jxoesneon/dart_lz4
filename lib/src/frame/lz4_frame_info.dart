import 'dart:typed_data';

import '../internal/byte_reader.dart';
import '../internal/lz4_exception.dart';
import '../xxhash/xxh32.dart';

const _lz4FrameMagic = 0x184D2204;
const _lz4SkippableMagicBase = 0x184D2A50;
const _lz4SkippableMagicMask = 0xFFFFFFF0;
const _lz4LegacyFrameMagic = 0x184C2102;

/// Metadata about an LZ4 frame.
class Lz4FrameInfo {
  /// The magic number identifying the frame type.
  final int magic;

  /// Whether this is a skippable frame.
  final bool isSkippable;

  /// Whether this is a legacy frame.
  final bool isLegacy;

  /// The size of the skippable frame data (if [isSkippable] is true).
  final int? skippableSize;

  /// Whether blocks are independent (if standard frame).
  final bool blockIndependence;

  /// Whether blocks have checksums (if standard frame).
  final bool blockChecksum;

  /// Whether the frame has a content checksum (if standard frame).
  final bool contentChecksum;

  /// The declared content size, if present.
  final int? contentSize;

  /// The dictionary ID, if present.
  final int? dictId;

  /// The maximum block size (if standard frame).
  final int blockMaxSize;

  /// The number of bytes consumed by the frame header (including magic).
  ///
  /// For skippable frames, this is 8 bytes (magic + size).
  /// For legacy frames, this is 4 bytes (magic).
  /// For standard frames, this is the magic + descriptor + header checksum.
  final int headerSize;

  const Lz4FrameInfo._({
    required this.magic,
    required this.isSkippable,
    required this.isLegacy,
    this.skippableSize,
    this.blockIndependence = true,
    this.blockChecksum = false,
    this.contentChecksum = false,
    this.contentSize,
    this.dictId,
    this.blockMaxSize = 0,
    required this.headerSize,
  });

  @override
  String toString() {
    if (isSkippable) {
      return 'Lz4FrameInfo(type: skippable, size: $skippableSize)';
    }
    if (isLegacy) {
      return 'Lz4FrameInfo(type: legacy)';
    }
    return 'Lz4FrameInfo(type: standard, '
        'independent: $blockIndependence, '
        'blockChecksum: $blockChecksum, '
        'contentChecksum: $contentChecksum, '
        'contentSize: $contentSize, '
        'dictId: $dictId, '
        'blockMaxSize: $blockMaxSize)';
  }
}

/// Parses the header of an LZ4 frame from [src] and returns its metadata.
///
/// This does not decode the frame content. It only reads the magic number
/// and the frame descriptor (if present).
///
/// Throws [Lz4FormatException] if the header is malformed.
Lz4FrameInfo lz4FrameInfo(Uint8List src) {
  final reader = ByteReader(src);

  if (reader.remaining < 4) {
    throw const Lz4FormatException('Unexpected end of input');
  }

  final magic = reader.readUint32LE();

  // Skippable Frame
  if ((magic & _lz4SkippableMagicMask) == _lz4SkippableMagicBase) {
    if (reader.remaining < 4) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    final size = reader.readUint32LE();
    // Reasonable upper bound for skippable frames (2GB)
    if (size > 0x7FFFFFFF) {
      throw const Lz4FormatException('Skippable frame size too large');
    }
    return Lz4FrameInfo._(
      magic: magic,
      isSkippable: true,
      isLegacy: false,
      skippableSize: size,
      headerSize: 8,
    );
  }

  // Legacy Frame
  if (magic == _lz4LegacyFrameMagic) {
    return Lz4FrameInfo._(
      magic: magic,
      isSkippable: false,
      isLegacy: true,
      headerSize: 4,
    );
  }

  // Standard Frame
  if (magic != _lz4FrameMagic) {
    throw const Lz4FormatException('Invalid LZ4 frame magic number');
  }

  final descriptorStart = reader.offset;

  if (reader.remaining < 3) {
    throw const Lz4FormatException('Unexpected end of input');
  }

  final flg = reader.readUint8();
  final bd = reader.readUint8();

  final version = (flg >> 6) & 0x03;
  if (version != 0x01) {
    throw const Lz4UnsupportedFeatureException('Unsupported LZ4 frame version');
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
    if (reader.remaining < 8) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    contentSize = reader.readUint64LE();
  }

  int? dictId;
  if (dictIdFlag) {
    if (reader.remaining < 4) {
      throw const Lz4FormatException('Unexpected end of input');
    }
    dictId = reader.readUint32LE();
  }

  final descriptorEnd = reader.offset;

  final hc = reader.readUint8();
  final descriptorBytes =
      Uint8List.sublistView(src, descriptorStart, descriptorEnd);
  final expectedHc = (xxh32(descriptorBytes, seed: 0) >> 8) & 0xFF;

  if (hc != expectedHc) {
    throw const Lz4CorruptDataException('Header checksum mismatch');
  }

  return Lz4FrameInfo._(
    magic: magic,
    isSkippable: false,
    isLegacy: false,
    blockIndependence: blockIndependence,
    blockChecksum: blockChecksum,
    contentChecksum: contentChecksumFlag,
    contentSize: contentSize,
    dictId: dictId,
    blockMaxSize: blockMaxSize,
    headerSize: reader.offset,
  );
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
