/// Options for tuning LZ4 HC (High Compression) mode.
final class Lz4HcOptions {
  /// The maximum depth for chain searches.
  ///
  /// Higher values can improve compression ratio but decrease compression speed.
  /// Typical values range from 4 to 1024. Default is 64.
  final int searchDepth;

  /// Creates options for LZ4 HC compression.
  Lz4HcOptions({
    this.searchDepth = 64,
  }) {
    if (searchDepth < 1) {
      throw RangeError.value(searchDepth, 'searchDepth');
    }
  }
}
