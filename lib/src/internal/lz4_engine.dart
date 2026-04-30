import 'dart:typed_data';
import 'byte_writer.dart';

/// Interface for LZ4 compression engines.
abstract interface class Lz4CompressionEngine {
  /// Compresses [src] into [writer].
  ///
  /// If [dictionary] is provided, it is used for prefix/dictionary compression.
  void compress(
    ByteWriter writer,
    Uint8List src, {
    Uint8List? dictionary,
  });
}
