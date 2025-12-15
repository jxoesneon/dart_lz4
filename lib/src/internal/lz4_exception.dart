class Lz4Exception implements Exception {
  final String message;

  const Lz4Exception(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

class Lz4FormatException extends Lz4Exception {
  const Lz4FormatException(super.message);
}

class Lz4CorruptDataException extends Lz4Exception {
  const Lz4CorruptDataException(super.message);
}

class Lz4OutputLimitException extends Lz4Exception {
  const Lz4OutputLimitException(super.message);
}

class Lz4UnsupportedFeatureException extends Lz4Exception {
  const Lz4UnsupportedFeatureException(super.message);
}
