import 'dart:typed_data';

import '../internal/byte_reader.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';

Uint8List lz4BlockDecompress(
  Uint8List src, {
  required int decompressedSize,
}) {
  if (decompressedSize < 0) {
    throw RangeError.value(decompressedSize, 'decompressedSize');
  }

  final reader = ByteReader(src);
  final writer = ByteWriter(
    initialCapacity: decompressedSize,
    maxLength: decompressedSize,
  );

  while (writer.length < decompressedSize) {
    if (reader.isEOF) {
      throw const Lz4FormatException('Unexpected end of input');
    }

    final token = reader.readUint8();

    var literalLength = token >> 4;
    if (literalLength == 15) {
      literalLength += _readExtendedLength(reader);
    }

    if (literalLength > decompressedSize - writer.length) {
      throw const Lz4CorruptDataException('Literal length exceeds output size');
    }

    if (literalLength != 0) {
      final literals = reader.readBytesView(literalLength);
      writer.writeBytesView(literals, 0, literals.length);
    }

    if (writer.length == decompressedSize) {
      if (!reader.isEOF) {
        throw const Lz4CorruptDataException(
            'Trailing bytes after end of block');
      }
      return writer.toBytes();
    }

    if (reader.remaining < 2) {
      throw const Lz4FormatException('Unexpected end of input');
    }

    final distance = reader.readUint16LE();

    var matchLength = (token & 0x0f) + 4;
    if ((token & 0x0f) == 15) {
      matchLength += _readExtendedLength(reader);
    }

    if (matchLength > decompressedSize - writer.length) {
      throw const Lz4CorruptDataException('Match length exceeds output size');
    }

    try {
      writer.copyMatch(distance, matchLength);
    } on Lz4OutputLimitException {
      throw const Lz4CorruptDataException('Match length exceeds output size');
    }
  }

  if (!reader.isEOF) {
    throw const Lz4CorruptDataException('Trailing bytes after end of block');
  }

  return writer.toBytes();
}

void lz4BlockDecompressInto(
  Uint8List src,
  ByteWriter writer,
) {
  final reader = ByteReader(src);

  while (true) {
    if (reader.isEOF) {
      return;
    }

    final token = reader.readUint8();

    var literalLength = token >> 4;
    if (literalLength == 15) {
      literalLength += _readExtendedLength(reader);
    }

    if (literalLength != 0) {
      final literals = reader.readBytesView(literalLength);
      writer.writeBytesView(literals, 0, literals.length);
    }

    if (reader.isEOF) {
      return;
    }

    if (reader.remaining < 2) {
      throw const Lz4FormatException('Unexpected end of input');
    }

    final distance = reader.readUint16LE();

    var matchLength = (token & 0x0f) + 4;
    if ((token & 0x0f) == 15) {
      matchLength += _readExtendedLength(reader);
    }

    writer.copyMatch(distance, matchLength);
  }
}

int _readExtendedLength(ByteReader reader) {
  var total = 0;
  while (true) {
    final b = reader.readUint8();
    total += b;
    if (b != 255) {
      return total;
    }
  }
}
