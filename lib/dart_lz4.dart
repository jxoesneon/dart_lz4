import 'dart:typed_data';

import 'src/block/lz4_block_decoder.dart';
import 'src/block/lz4_block_encoder.dart';
import 'src/frame/lz4_frame_decoder.dart';
import 'src/internal/lz4_exception.dart';

enum Lz4CompressionLevel {
  fast,
  hc,
}

Uint8List lz4Compress(
  Uint8List src, {
  Lz4CompressionLevel level = Lz4CompressionLevel.fast,
  int acceleration = 1,
}) {
  switch (level) {
    case Lz4CompressionLevel.fast:
      return lz4BlockCompress(src, acceleration: acceleration);
    case Lz4CompressionLevel.hc:
      throw const Lz4UnsupportedFeatureException('LZ4HC is not implemented');
  }
}

Uint8List lz4Decompress(
  Uint8List src, {
  required int decompressedSize,
}) {
  return lz4BlockDecompress(src, decompressedSize: decompressedSize);
}

Uint8List lz4FrameEncode(
  Uint8List src,
) {
  throw UnimplementedError();
}

Uint8List lz4FrameDecode(
  Uint8List src, {
  int? maxOutputBytes,
}) {
  return lz4FrameDecodeBytes(src, maxOutputBytes: maxOutputBytes);
}
