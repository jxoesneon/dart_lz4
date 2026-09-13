import 'dart:convert';
import 'dart:typed_data';

import 'frame/lz4_frame_decoder.dart';
import 'frame/lz4_frame_encoder.dart';

/// Default output limit (256 MiB) enforced by [Lz4Codec] to prevent
/// decompression bombs when decoding untrusted input.
const _defaultMaxOutputBytes = 256 * 1024 * 1024;

/// A [Codec] that compresses [List<int>] data using the LZ4 frame format.
///
/// This provides a `dart:convert`-compatible interface for LZ4 frame
/// compression/decompression, enabling composition with other codecs:
///
/// ```dart
/// final codec = Lz4Codec();
/// final compressed = codec.encode(data);
/// final decompressed = codec.decode(compressed);
///
/// // Fuse with other codecs:
/// final jsonLz4 = json.fuse(codec);
/// ```
///
/// Decoding enforces a default [maxOutputBytes] limit of 256 MiB to
/// mitigate decompression bombs. Pass an explicit [maxOutputBytes] to
/// [decode] to override.
class Lz4Codec extends Codec<List<int>, List<int>> {
  /// Acceleration for the fast compressor (higher = faster, lower ratio).
  final int acceleration;

  /// Maximum decompressed output bytes when [decode] is called without an
  /// explicit limit. Defaults to 256 MiB.
  final int maxOutputBytes;

  /// Creates an LZ4 frame codec.
  ///
  /// [acceleration] controls the speed/ratio tradeoff of the fast compressor.
  /// [maxOutputBytes] sets the default decompression bomb protection limit.
  const Lz4Codec({
    this.acceleration = 1,
    this.maxOutputBytes = _defaultMaxOutputBytes,
  });

  @override
  Converter<List<int>, List<int>> get encoder =>
      _Lz4Encoder(acceleration: acceleration);

  @override
  Converter<List<int>, List<int>> get decoder =>
      _Lz4Decoder(maxOutputBytes: maxOutputBytes);
}

class _Lz4Encoder extends Converter<List<int>, List<int>> {
  final int acceleration;

  const _Lz4Encoder({this.acceleration = 1});

  @override
  List<int> convert(List<int> input, [int? start, int? end]) {
    final s = start ?? 0;
    final e = end ?? input.length;
    final src = input is Uint8List
        ? Uint8List.sublistView(input, s, e)
        : Uint8List.fromList(input.sublist(s, e));
    return lz4FrameEncodeBytes(src, acceleration: acceleration);
  }
}

class _Lz4Decoder extends Converter<List<int>, List<int>> {
  final int maxOutputBytes;

  const _Lz4Decoder({this.maxOutputBytes = _defaultMaxOutputBytes});

  @override
  List<int> convert(List<int> input, [int? start, int? end]) {
    final s = start ?? 0;
    final e = end ?? input.length;
    final src = input is Uint8List
        ? Uint8List.sublistView(input, s, e)
        : Uint8List.fromList(input.sublist(s, e));
    return lz4FrameDecodeBytes(src, maxOutputBytes: maxOutputBytes);
  }
}
