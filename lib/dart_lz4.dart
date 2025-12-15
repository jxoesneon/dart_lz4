import 'dart:typed_data';

import 'src/block/lz4_block_decoder.dart';

enum Lz4CompressionLevel {
  fast,
  hc,
}

Uint8List lz4Compress(
  Uint8List src, {
  Lz4CompressionLevel level = Lz4CompressionLevel.fast,
  int acceleration = 1,
}) {
  throw UnimplementedError();
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
  Uint8List src,
) {
  throw UnimplementedError();
}
