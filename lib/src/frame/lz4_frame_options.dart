import '../hc/lz4_hc_options.dart';

/// Maximum LZ4 frame block size.
///
/// This controls both the `BD` header field and the maximum size of each encoded
/// block.
enum Lz4FrameBlockSize {
  /// 64KiB blocks.
  k64KB,

  /// 256KiB blocks.
  k256KB,

  /// 1MiB blocks.
  k1MB,

  /// 4MiB blocks.
  k4MB,
}

/// Compression mode used for each LZ4 frame block.
enum Lz4FrameCompression {
  /// Fast compression.
  fast,

  /// High compression.
  hc,
}

/// Options controlling LZ4 frame encoding.
final class Lz4FrameOptions {
  /// The maximum block size for this frame.
  final Lz4FrameBlockSize blockSize;

  /// Whether blocks are independent.
  ///
  /// When `false`, blocks may reference up to 64KiB of history from prior blocks.
  final bool blockIndependence;

  /// Whether to include the per-block checksum field.
  final bool blockChecksum;

  /// Whether to include the final content checksum field.
  final bool contentChecksum;

  /// Optional uncompressed content size to include in the frame header.
  ///
  /// If set, it must fit within 32 bits.
  final int? contentSize;

  /// Which compressor to use for blocks.
  final Lz4FrameCompression compression;

  /// Acceleration for fast compression.
  ///
  /// Only used when [compression] is [Lz4FrameCompression.fast].
  final int acceleration;

  /// Optional HC tuning parameters.
  ///
  /// Only used when [compression] is [Lz4FrameCompression.hc].
  final Lz4HcOptions? hcOptions;

  /// Creates options for LZ4 frame encoding.
  Lz4FrameOptions({
    this.blockSize = Lz4FrameBlockSize.k4MB,
    this.blockIndependence = true,
    this.blockChecksum = false,
    this.contentChecksum = false,
    this.contentSize,
    this.compression = Lz4FrameCompression.fast,
    this.acceleration = 1,
    this.hcOptions,
  }) {
    if (acceleration < 1) {
      throw RangeError.value(acceleration, 'acceleration');
    }
    final cs = contentSize;
    if (cs != null && (cs < 0 || cs > 0xFFFFFFFF)) {
      throw RangeError.value(cs, 'contentSize');
    }
  }
}

extension Lz4FrameBlockSizeInternal on Lz4FrameBlockSize {
  int get bdId {
    switch (this) {
      case Lz4FrameBlockSize.k64KB:
        return 4;
      case Lz4FrameBlockSize.k256KB:
        return 5;
      case Lz4FrameBlockSize.k1MB:
        return 6;
      case Lz4FrameBlockSize.k4MB:
        return 7;
    }
  }

  int get maxBytes {
    switch (this) {
      case Lz4FrameBlockSize.k64KB:
        return 64 * 1024;
      case Lz4FrameBlockSize.k256KB:
        return 256 * 1024;
      case Lz4FrameBlockSize.k1MB:
        return 1024 * 1024;
      case Lz4FrameBlockSize.k4MB:
        return 4 * 1024 * 1024;
    }
  }
}
