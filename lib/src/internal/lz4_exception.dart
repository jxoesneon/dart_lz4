/// Base class for all LZ4-related exceptions.
class Lz4Exception implements Exception {
  /// The error message associated with this exception.
  final String message;

  /// Creates a new [Lz4Exception] with the given [message].
  const Lz4Exception(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when the LZ4 frame format is invalid (e.g. bad magic number, invalid header).
class Lz4FormatException extends Lz4Exception {
  /// Creates a new [Lz4FormatException] with the given [message].
  const Lz4FormatException(super.message);
}

/// Thrown when the compressed data is corrupt (e.g. checksum mismatch, invalid block).
class Lz4CorruptDataException extends Lz4Exception {
  /// Creates a new [Lz4CorruptDataException] with the given [message].
  const Lz4CorruptDataException(super.message);
}

/// Thrown when the output buffer is too small to contain the uncompressed data.
class Lz4OutputLimitException extends Lz4Exception {
  /// Creates a new [Lz4OutputLimitException] with the given [message].
  const Lz4OutputLimitException(super.message);
}

/// Thrown when a feature is not supported by this implementation (e.g. unknown version).
class Lz4UnsupportedFeatureException extends Lz4Exception {
  /// Creates a new [Lz4UnsupportedFeatureException] with the given [message].
  const Lz4UnsupportedFeatureException(super.message);
}
