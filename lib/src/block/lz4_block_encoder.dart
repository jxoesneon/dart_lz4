import 'dart:typed_data';

import '../internal/byte_writer.dart';

Uint8List lz4BlockCompress(
  Uint8List src, {
  Uint8List? dictionary,
  int acceleration = 1,
}) {
  if (acceleration < 1) {
    throw RangeError.value(acceleration, 'acceleration');
  }

  final inputLength = src.length;
  if (inputLength == 0) {
    return Uint8List(0);
  }

  const historyWindow = 64 * 1024;
  const dictionaryWindow = historyWindow - 1;
  final dictFull = dictionary;
  final dict = (dictFull != null && dictFull.isNotEmpty)
      ? (dictFull.length > dictionaryWindow
          ? Uint8List.sublistView(
              dictFull,
              dictFull.length - dictionaryWindow,
            )
          : dictFull)
      : null;
  final dictLength = dict?.length ?? 0;

  final Uint8List input;
  if (dictLength == 0) {
    input = src;
  } else {
    input = Uint8List(dictLength + inputLength);
    input.setRange(0, dictLength, dict!);
    input.setRange(dictLength, dictLength + inputLength, src);
  }

  final writer = ByteWriter(initialCapacity: inputLength);

  const minMatch = 4;
  if (inputLength < minMatch) {
    _writeLastLiterals(writer, input, dictLength, inputLength);
    return writer.toBytes();
  }

  const hashLog = 16;
  const hashSize = 1 << hashLog;
  const hashShift = 32 - hashLog;

  final hashTable = List<int>.filled(hashSize, -1, growable: false);

  if (dictLength != 0) {
    for (var pos = 0; pos <= dictLength - minMatch; pos++) {
      final seq = _readUint32LE(input, pos);
      hashTable[_hash(seq, hashShift)] = pos;
    }
  }

  var anchor = dictLength;
  var i = dictLength;

  final totalLength = input.length;

  while (i <= totalLength - minMatch) {
    final seq = _readUint32LE(input, i);
    final h = _hash(seq, hashShift);

    final ref = hashTable[h];
    hashTable[h] = i;

    final distance = i - ref;
    if (ref >= 0 && distance <= 0xFFFF && _readUint32LE(input, ref) == seq) {
      var matchStart = i;
      var refStart = ref;

      while (matchStart > anchor && refStart > 0) {
        if (input[matchStart - 1] != input[refStart - 1]) {
          break;
        }
        matchStart--;
        refStart--;
      }

      final literalLength = matchStart - anchor;

      var matchLength = minMatch;
      while (matchStart + matchLength < totalLength &&
          input[matchStart + matchLength] == input[refStart + matchLength]) {
        matchLength++;
      }

      _writeSequence(
        writer,
        input,
        anchor,
        literalLength,
        matchStart - refStart,
        matchLength,
      );

      i = matchStart + matchLength;
      anchor = i;

      if (i > totalLength - minMatch) {
        break;
      }

      var j = i - matchLength + 1;
      final stop = i - minMatch;
      while (j <= stop) {
        final s = _readUint32LE(input, j);
        hashTable[_hash(s, hashShift)] = j;
        j++;
      }

      continue;
    }

    i += 1 + ((i - anchor) >> acceleration);
  }

  final lastLiterals = totalLength - anchor;
  if (lastLiterals != 0) {
    _writeLastLiterals(writer, input, anchor, lastLiterals);
  }

  return writer.toBytes();
}

int _readUint32LE(Uint8List bytes, int offset) {
  final b0 = bytes[offset];
  final b1 = bytes[offset + 1];
  final b2 = bytes[offset + 2];
  final b3 = bytes[offset + 3];
  return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & 0xffffffff;
}

int _hash(int value, int shift) {
  const prime = 2654435761;
  return ((value * prime) & 0xffffffff) >>> shift;
}

void _writeSequence(
  ByteWriter writer,
  Uint8List src,
  int literalStart,
  int literalLength,
  int matchDistance,
  int matchLength,
) {
  final matchLenMinus4 = matchLength - 4;

  final tokenLiteral = literalLength < 15 ? literalLength : 15;
  final tokenMatch = matchLenMinus4 < 15 ? matchLenMinus4 : 15;

  writer.writeUint8((tokenLiteral << 4) | tokenMatch);

  if (literalLength >= 15) {
    _writeLength(writer, literalLength - 15);
  }

  if (literalLength != 0) {
    writer.writeBytesView(src, literalStart, literalStart + literalLength);
  }

  writer.writeUint16LE(matchDistance);

  if (matchLenMinus4 >= 15) {
    _writeLength(writer, matchLenMinus4 - 15);
  }
}

void _writeLastLiterals(
    ByteWriter writer, Uint8List src, int start, int length) {
  final tokenLiteral = length < 15 ? length : 15;
  writer.writeUint8(tokenLiteral << 4);

  if (length >= 15) {
    _writeLength(writer, length - 15);
  }

  if (length != 0) {
    writer.writeBytesView(src, start, start + length);
  }
}

void _writeLength(ByteWriter writer, int length) {
  var remaining = length;
  while (remaining >= 255) {
    writer.writeUint8(255);
    remaining -= 255;
  }
  writer.writeUint8(remaining);
}
