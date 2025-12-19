/// Pure Dart LZ4 and LZ4HC APIs.
///
/// This library provides:
/// - LZ4 block compression/decompression.
/// - LZ4 frame encode/decode (including skippable frames).
/// - Streaming frame encode/decode as `StreamTransformer`s.
///
/// All APIs are `Uint8List`-based and are intended to work on all Dart
/// platforms, including Web.
library dart_lz4;

import 'dart:async';
import 'dart:typed_data';

import 'src/frame/lz4_frame_options.dart'
    show Lz4FrameOptions, Lz4DictionaryResolver;

export 'src/internal/lz4_exception.dart';
export 'src/block/lz4_sized_block.dart';
export 'src/frame/lz4_frame_info.dart' show Lz4FrameInfo, lz4FrameInfo;
export 'src/frame/lz4_frame_options.dart'
    show
        Lz4FrameOptions,
        Lz4FrameBlockSize,
        Lz4FrameCompression,
        Lz4DictionaryResolver;
export 'src/hc/lz4_hc_options.dart' show Lz4HcOptions;

import 'src/block/lz4_block_decoder.dart';
import 'src/block/lz4_block_encoder.dart';
import 'src/frame/lz4_frame_decoder.dart';
import 'src/frame/lz4_frame_encoder.dart';
import 'src/frame/lz4_frame_stream_decoder.dart';
import 'src/frame/lz4_frame_stream_encoder.dart';
import 'src/hc/lz4_hc_block_encoder.dart';
import 'src/hc/lz4_hc_options.dart';

/// Compression level for [lz4Compress].
enum Lz4CompressionLevel {
  /// Fast compression (lower ratio, higher throughput).
  fast,

  /// High-compression mode (higher ratio, lower throughput).
  hc,
}

/// Compresses [src] into an LZ4 *block*.
///
/// The returned bytes are in the raw LZ4 block format. To decode, you must know
/// the decompressed size and pass it to [lz4Decompress].
///
/// The [level] selects between the fast and high-compression encoders.
///
/// When [level] is [Lz4CompressionLevel.fast], [acceleration] controls the
/// speed/ratio tradeoff: higher values usually increase speed at the cost of
/// compression ratio.
///
/// When [level] is [Lz4CompressionLevel.hc], [hcOptions] can be provided to
/// tune the compression (e.g. search depth).
Uint8List lz4Compress(
  Uint8List src, {
  Lz4CompressionLevel level = Lz4CompressionLevel.fast,
  int acceleration = 1,
  Lz4HcOptions? hcOptions,
}) {
  switch (level) {
    case Lz4CompressionLevel.fast:
      return lz4BlockCompress(src, acceleration: acceleration);
    case Lz4CompressionLevel.hc:
      return lz4HcBlockCompress(src, options: hcOptions);
  }
}

/// Decompresses an LZ4 *block* [src] into a new [Uint8List].
///
/// The [decompressedSize] must match the exact expected output size.
///
/// Throws an [Exception] if the input is malformed/truncated or if it attempts
/// to write beyond the expected output size.
Uint8List lz4Decompress(
  Uint8List src, {
  required int decompressedSize,
}) {
  return lz4BlockDecompress(src, decompressedSize: decompressedSize);
}

/// Encodes [src] as an LZ4 *frame*.
///
/// The output is a valid LZ4 frame (magic + header + one or more blocks + end
/// mark). Blocks are compressed with the LZ4 block encoder and may be stored as
/// uncompressed if that is smaller.
///
/// [acceleration] is forwarded to the underlying fast block compressor.
///
/// If [dictionary] is provided, it will be used to initialize the compression
/// context.
Uint8List lz4FrameEncode(
  Uint8List src, {
  int acceleration = 1,
  Uint8List? dictionary,
}) {
  return lz4FrameEncodeBytes(src,
      acceleration: acceleration, dictionary: dictionary);
}

/// Encodes [src] as an LZ4 *frame* using the provided [options].
///
/// If [dictionary] is provided, it will be used to initialize the compression
/// context.
Uint8List lz4FrameEncodeWithOptions(
  Uint8List src, {
  required Lz4FrameOptions options,
  Uint8List? dictionary,
}) {
  return lz4FrameEncodeBytesWithOptions(src,
      options: options, dictionary: dictionary);
}

/// Decodes one or more concatenated LZ4 frames from [src].
///
/// If [maxOutputBytes] is provided, decoding will stop with an [Exception] if
/// the decompressed output would exceed that limit.
///
/// If the frame requires a dictionary (indicated by a dictionary ID),
/// [dictionaryResolver] must be provided to look up the dictionary bytes.
Uint8List lz4FrameDecode(
  Uint8List src, {
  int? maxOutputBytes,
  Lz4DictionaryResolver? dictionaryResolver,
}) {
  return lz4FrameDecodeBytes(
    src,
    maxOutputBytes: maxOutputBytes,
    dictionaryResolver: dictionaryResolver,
  );
}

/// Returns a `StreamTransformer` that decodes LZ4 frames from a byte stream.
///
/// This is useful when the frame arrives in chunks (e.g. network/file streams).
///
/// If [maxOutputBytes] is provided, decoding will stop with an [Exception] if
/// the decompressed output would exceed that limit.
///
/// If the frame requires a dictionary (indicated by a dictionary ID),
/// [dictionaryResolver] must be provided to look up the dictionary bytes.
StreamTransformer<List<int>, List<int>> lz4FrameDecoder({
  int? maxOutputBytes,
  Lz4DictionaryResolver? dictionaryResolver,
}) {
  return lz4FrameDecoderTransformer(
    maxOutputBytes: maxOutputBytes,
    dictionaryResolver: dictionaryResolver,
  );
}

/// Returns a `StreamTransformer` that encodes bytes into a single LZ4 frame.
///
/// The transformer buffers up to the maximum frame block size (4MiB) and emits
/// one or more encoded blocks, plus the final end mark.
///
/// [acceleration] is forwarded to the underlying fast block compressor.
///
/// If [dictionary] is provided, it will be used to initialize the compression
/// context.
StreamTransformer<List<int>, List<int>> lz4FrameEncoder({
  int acceleration = 1,
  Uint8List? dictionary,
}) {
  return lz4FrameEncoderTransformer(
      acceleration: acceleration, dictionary: dictionary);
}

/// Returns a `StreamTransformer` that encodes bytes into a single LZ4 frame
/// using the provided [options].
///
/// If [dictionary] is provided, it will be used to initialize the compression
/// context.
StreamTransformer<List<int>, List<int>> lz4FrameEncoderWithOptions({
  required Lz4FrameOptions options,
  Uint8List? dictionary,
}) {
  return lz4FrameEncoderTransformerWithOptions(
      options: options, dictionary: dictionary);
}

/// Encodes a skippable frame containing [data].
///
/// Skippable frames are used to embed user-defined metadata within an LZ4
/// stream. Decoders that don't recognize the frame type will skip over it.
///
/// The [index] (0–15) selects which skippable magic number to use:
/// `0x184D2A50` through `0x184D2A5F`. Different indices can be used to
/// distinguish different types of metadata.
///
/// The [data] can be up to 4 GiB in size (2^32 - 1 bytes).
///
/// Returns the encoded skippable frame (8 bytes header + data).
///
/// Example:
/// ```dart
/// final metadata = Uint8List.fromList(utf8.encode('{"version": 1}'));
/// final skippable = lz4SkippableEncode(metadata, index: 0);
/// // Concatenate with a regular frame:
/// final combined = Uint8List.fromList([...skippable, ...lz4FrameEncode(data)]);
/// ```
Uint8List lz4SkippableEncode(Uint8List data, {int index = 0}) {
  return lz4SkippableFrameEncode(data, index: index);
}

/// Encodes [src] as a legacy LZ4 frame (magic `0x184C2102`).
///
/// Legacy frames use 8 MiB blocks without checksums or content size headers.
/// This format is produced by `lz4 -l` and is rarely needed for new data.
/// Prefer the modern frame format ([lz4FrameEncode]) for new applications.
///
/// [acceleration] controls the speed/ratio tradeoff (higher = faster, lower ratio).
Uint8List lz4LegacyEncode(Uint8List src, {int acceleration = 1}) {
  return lz4LegacyFrameEncode(src, acceleration: acceleration);
}
