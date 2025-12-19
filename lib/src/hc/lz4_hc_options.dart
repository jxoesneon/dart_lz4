/// Options for tuning LZ4 HC (High Compression) mode.
final class Lz4HcOptions {
  /// The maximum depth for chain searches.
  ///
  /// Higher values can improve compression ratio but decrease compression speed.
  /// Typical values range from 4 to 128. Default is 64.
  final int maxSearchDepth;

  /// Creates options for LZ4 HC compression.
  Lz4HcOptions({
    this.maxSearchDepth = 64,
  }) {
    if (maxSearchDepth < 1) {
      throw RangeError.value(maxSearchDepth, 'maxSearchDepth');
    }
  }
}
