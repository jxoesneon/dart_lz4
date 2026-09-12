import 'dart:typed_data';

import '../internal/byte_reader.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_buffer_pool.dart';
import '../internal/lz4_exception.dart';

Uint8List lz4BlockDecompress(
  Uint8List src, {
  required int decompressedSize,
  int? maxDecompressedSize,
  Lz4BufferPool? bufferPool,
}) {
  if (decompressedSize < 0) {
    throw RangeError.value(decompressedSize, 'decompressedSize');
  }
  if (maxDecompressedSize != null && decompressedSize > maxDecompressedSize) {
    throw Lz4FormatException(
        'Decompressed size ($decompressedSize) exceeds maxDecompressedSize ($maxDecompressedSize)');
  }

  final reader = ByteReader(src);
  final writer = ByteWriter(
    initialCapacity: decompressedSize,
    maxLength: decompressedSize,
    bufferPool: bufferPool,
  );

  try {
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
        throw const Lz4CorruptDataException(
            'Literal length exceeds output size');
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
  } on RangeError {
    throw const Lz4CorruptDataException('Data truncated or invalid offset');
  } on StateError {
    throw const Lz4CorruptDataException('Invalid decoder state');
  } on Lz4OutputLimitException {
    rethrow;
  } finally {
    writer.release();
  }
}

void lz4BlockDecompressInto(
  Uint8List src,
  ByteWriter writer,
) {
  final reader = ByteReader(src);

  try {
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
        if (reader.isEOF) {
          return;
        }
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
  } on RangeError {
    throw const Lz4CorruptDataException('Data truncated or invalid offset');
  } on StateError {
    throw const Lz4CorruptDataException('Invalid decoder state');
  } on Lz4OutputLimitException {
    rethrow;
  }
}

/// Decompresses an LZ4 block from [src] directly into the pre-allocated [dst]
/// buffer starting at [dstOffset].
///
/// Returns the number of decompressed bytes written to [dst].
///
/// Throws:
/// - [RangeError] if [dstOffset] is outside `[0, dst.length]`.
/// - [Lz4OutputLimitException] if [dst] has insufficient space for the decompressed data.
/// - [Lz4CorruptDataException] if the block data is malformed or corrupted.
/// - [Lz4FormatException] if the block format or tokens are invalid.
int lz4BlockDecompressIntoBuffer(
  Uint8List src,
  Uint8List dst, {
  int dstOffset = 0,
}) {
  if (dstOffset < 0 || dstOffset > dst.length) {
    throw RangeError.range(dstOffset, 0, dst.length, 'dstOffset');
  }

  final writer = ByteWriter.forBuffer(dst, offset: dstOffset);

  lz4BlockDecompressInto(src, writer);
  return writer.length - dstOffset;
}

int _readExtendedLength(ByteReader reader) {
  var total = 0;
  // Limit to prevent CPU exhaustion and potential overflow.
  // 0x10000000 is a very generous limit (256MB literal or match length),
  // which requires ~1M iterations of 255 bytes.
  var iterations = 0;
  while (true) {
    final b = reader.readUint8();
    total += b;
    if (b != 255) {
      return total;
    }
    iterations++;
    if (iterations > 0x1000000) {
      throw const Lz4FormatException('Extended length sequence too long');
    }
  }
}
