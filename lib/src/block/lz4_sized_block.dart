import 'dart:typed_data';

import '../../dart_lz4.dart';

/// Compresses [src] into an LZ4 block with the decompressed size prepended.
///
/// The output format is:
/// - 4 bytes: Little-endian unsigned 32-bit integer representing the length of [src].
/// - N bytes: LZ4 compressed block data.
///
/// This allows [lz4DecompressWithSize] to decompress the block without needing
/// to know the decompressed size beforehand.
///
/// [level] and [acceleration] behave the same as in [lz4Compress].
Uint8List lz4CompressWithSize(
  Uint8List src, {
  Lz4CompressionLevel level = Lz4CompressionLevel.fast,
  int acceleration = 1,
}) {
  final compressed = lz4Compress(
    src,
    level: level,
    acceleration: acceleration,
  );

  final out = Uint8List(4 + compressed.length);
  final view = ByteData.view(out.buffer);
  view.setUint32(0, src.length, Endian.little);
  out.setRange(4, out.length, compressed);
  return out;
}

/// Decompresses an LZ4 block that was compressed with [lz4CompressWithSize].
///
/// Reads the prepended 4-byte decompressed size and uses it to decompress the
/// remaining data.
///
/// If [maxDecompressedSize] is provided, throws [Lz4FormatException] if the
/// header size exceeds the limit.
///
/// Throws [Lz4FormatException] if [src] is too short.
Uint8List lz4DecompressWithSize(Uint8List src, {int? maxDecompressedSize}) {
  if (src.length < 4) {
    throw const Lz4FormatException('Input too short for size header');
  }

  final view = ByteData.view(src.buffer, src.offsetInBytes, src.length);
  final decompressedSize = view.getUint32(0, Endian.little);

  if (maxDecompressedSize != null && decompressedSize > maxDecompressedSize) {
    throw Lz4FormatException(
        'Decompressed size ($decompressedSize) from header exceeds maxDecompressedSize ($maxDecompressedSize)');
  }

  // We use sublistView to avoid copying the compressed data again,
  // passing a view to the decoder.
  final compressedData = Uint8List.sublistView(src, 4);

  return lz4Decompress(
    compressedData,
    decompressedSize: decompressedSize,
  );
}
