import '../internal/lz4_exception.dart';

/// LZ4 frame magic number (current format).
const lz4FrameMagic = 0x184D2204;

/// Base magic number for skippable frames (`0x184D2A50`–`0x184D2A5F`).
const lz4SkippableMagicBase = 0x184D2A50;

/// Mask used to test whether a magic number falls in the skippable range.
const lz4SkippableMagicMask = 0xFFFFFFF0;

/// Legacy frame magic number (`0x184C2102`), produced by `lz4 -l`.
const lz4LegacyFrameMagic = 0x184C2102;

/// Decodes the block maximum size from the BD field's bits 4–6.
///
/// Throws [Lz4FormatException] for invalid size IDs.
int decodeBlockMaxSize(int id) {
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

/// Returns `true` if [magic] is a frame boundary (start of a new frame or
/// skippable frame), used when scanning concatenated legacy blocks.
bool isLegacyBoundary(int magic) {
  if (magic == lz4FrameMagic || magic == lz4LegacyFrameMagic) {
    return true;
  }
  return (magic & lz4SkippableMagicMask) == lz4SkippableMagicBase;
}
