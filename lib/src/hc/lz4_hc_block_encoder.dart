import 'dart:typed_data';

import '../internal/byte_writer.dart';
import 'lz4_hc_options.dart';

Uint8List lz4HcBlockCompress(
  Uint8List src, {
  Lz4HcOptions? options,
}) {
  final opt = options ?? Lz4HcOptions();

  final inputLength = src.length;
  if (inputLength == 0) {
    return Uint8List(0);
  }

  final writer = ByteWriter(initialCapacity: inputLength);

  const minMatch = 4;
  if (inputLength < minMatch) {
    _writeLastLiterals(writer, src, 0, inputLength);
    return writer.toBytes();
  }

  const hashLog = 16;
  const hashSize = 1 << hashLog;
  const hashShift = 32 - hashLog;

  final hashTable = List<int>.filled(hashSize, -1, growable: false);
  final chain = List<int>.filled(inputLength, -1, growable: false);

  int insert(int pos) {
    final seq = _readUint32LE(src, pos);
    final h = _hash(seq, hashShift);
    final ref = hashTable[h];
    chain[pos] = ref;
    hashTable[h] = pos;
    return ref;
  }

  var anchor = 0;
  var i = 0;

  while (i <= inputLength - minMatch) {
    var candidate = insert(i);

    var bestLen = 0;
    var bestRef = -1;

    var depth = 0;
    while (candidate >= 0 && depth < opt.maxSearchDepth) {
      final distance = i - candidate;
      if (distance > 0xFFFF) {
        candidate = chain[candidate];
        depth++;
        continue;
      }

      if (_readUint32LE(src, candidate) == _readUint32LE(src, i)) {
        var matchLen = minMatch;
        while (i + matchLen < inputLength &&
            src[i + matchLen] == src[candidate + matchLen]) {
          matchLen++;
        }
        if (matchLen > bestLen) {
          bestLen = matchLen;
          bestRef = candidate;
          if (i + bestLen == inputLength) {
            break;
          }
        }
      }

      candidate = chain[candidate];
      depth++;
    }

    if (bestLen >= minMatch) {
      var matchStart = i;
      var refStart = bestRef;

      while (matchStart > anchor &&
          refStart > 0 &&
          src[matchStart - 1] == src[refStart - 1]) {
        matchStart--;
        refStart--;
        bestLen++;
      }

      var matchLen = bestLen;
      while (matchStart + matchLen < inputLength &&
          src[matchStart + matchLen] == src[refStart + matchLen]) {
        matchLen++;
      }

      final literalLength = matchStart - anchor;
      _writeSequence(
        writer,
        src,
        anchor,
        literalLength,
        matchStart - refStart,
        matchLen,
      );

      i = matchStart + matchLen;
      anchor = i;

      if (i > inputLength - minMatch) {
        break;
      }

      var j = i - matchLen + 1;
      final stop = i - minMatch;
      while (j <= stop) {
        insert(j);
        j++;
      }

      continue;
    }

    i++;
  }

  final lastLiterals = inputLength - anchor;
  if (lastLiterals != 0) {
    _writeLastLiterals(writer, src, anchor, lastLiterals);
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
  ByteWriter writer,
  Uint8List src,
  int start,
  int length,
) {
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
