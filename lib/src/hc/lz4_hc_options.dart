/// High-compression levels for LZ4 HC.
enum Lz4HcLevel {
  /// Level 1.
  level1,

  /// Level 2.
  level2,

  /// Level 3.
  level3,

  /// Level 4.
  level4,

  /// Level 5.
  level5,

  /// Level 6.
  level6,

  /// Level 7.
  level7,

  /// Level 8.
  level8,

  /// Level 9.
  level9,

  /// Level 10.
  level10,

  /// Level 11.
  level11,

  /// Level 12.
  level12,
}

/// Options for tuning LZ4 HC (High Compression) mode.
final class Lz4HcOptions {
  /// The compression level.
  ///
  /// If provided, this determines the [maxSearchDepth].
  final Lz4HcLevel? level;

  /// The maximum depth for chain searches.
  ///
  /// Higher values can improve compression ratio but decrease compression speed.
  /// Typical values range from 4 to 1024. Default is 64.
  ///
  /// If [level] is provided, this value is ignored.
  final int maxSearchDepth;

  /// Creates options for LZ4 HC compression.
  Lz4HcOptions({
    this.level,
    this.maxSearchDepth = 64,
  }) {
    if (maxSearchDepth < 1) {
      throw RangeError.value(maxSearchDepth, 'maxSearchDepth');
    }
  }

  /// Returns the effective search depth based on [level] or [maxSearchDepth].
  int get effectiveSearchDepth {
    final l = level;
    if (l == null) return maxSearchDepth;

    switch (l) {
      case Lz4HcLevel.level1:
        return 1;
      case Lz4HcLevel.level2:
        return 1;
      case Lz4HcLevel.level3:
        return 2;
      case Lz4HcLevel.level4:
        return 4;
      case Lz4HcLevel.level5:
        return 8;
      case Lz4HcLevel.level6:
        return 16;
      case Lz4HcLevel.level7:
        return 32;
      case Lz4HcLevel.level8:
        return 64;
      case Lz4HcLevel.level9:
        return 128;
      case Lz4HcLevel.level10:
        return 256;
      case Lz4HcLevel.level11:
        return 512;
      case Lz4HcLevel.level12:
        return 1024;
    }
  }
}
