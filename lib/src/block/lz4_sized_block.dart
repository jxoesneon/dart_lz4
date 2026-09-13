import 'dart:typed_data';

import '../internal/lz4_exception.dart';
import 'lz4_block_decoder.dart';
import 'lz4_block_encoder.dart';
import '../hc/lz4_hc_block_encoder.dart';
import '../hc/lz4_hc_options.dart';

/// Compression level for [lz4CompressWithSize].
///
/// Re-exported from the public barrel as [Lz4CompressionLevel].
enum Lz4CompressionLevel {
  /// Fast compression (lower ratio, higher throughput).
  fast,

  /// High-compression mode (higher ratio, lower throughput).
  hc,
}

/// Compresses [src] into an LZ4 block with the decompressed size prepended.
///
/// The output format is:
/// - 4 bytes: Little-endian unsigned 32-bit integer representing the length of [src].
/// - N bytes: LZ4 compressed block data.
///
/// This allows [lz4DecompressWithSize] to decompress the block without needing
/// to know the decompressed size beforehand.
///
/// [level] and [acceleration] behave the same as in the public [lz4Compress].
Uint8List lz4CompressWithSize(
  Uint8List src, {
  Lz4CompressionLevel level = Lz4CompressionLevel.fast,
  int acceleration = 1,
  Lz4HcOptions? hcOptions,
}) {
  final Uint8List compressed;
  switch (level) {
    case Lz4CompressionLevel.fast:
      compressed = lz4BlockCompress(src, acceleration: acceleration);
    case Lz4CompressionLevel.hc:
      compressed = lz4HcBlockCompress(src, options: hcOptions);
  }

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

  return lz4BlockDecompress(
    compressedData,
    decompressedSize: decompressedSize,
  );
}
