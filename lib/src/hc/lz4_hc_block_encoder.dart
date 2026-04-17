import 'dart:typed_data';

import '../internal/byte_writer.dart';
import 'lz4_hc_options.dart';

const _hashLog = 16;
const _hashSize = 1 << _hashLog;
const _hashShift = 32 - _hashLog;

Uint8List lz4HcBlockCompress(
  Uint8List src, {
  Uint8List? dictionary,
  Lz4HcOptions? options,
}) {
  final writer = ByteWriter(initialCapacity: src.length);
  lz4HcBlockCompressToWriter(writer, src,
      dictionary: dictionary, options: options);
  return writer.toBytes();
}

void lz4HcBlockCompressToWriter(
  ByteWriter writer,
  Uint8List src, {
  Uint8List? dictionary,
  Lz4HcOptions? options,
}) {
  final opt = options ?? Lz4HcOptions();

  final inputLength = src.length;
  if (inputLength == 0) {
    return;
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
    final totalLength = dictLength + inputLength;
    final scratch = Uint8List(totalLength);
    scratch.setRange(0, dictLength, dict!);
    scratch.setRange(dictLength, totalLength, src);
    input = scratch;
  }

  const minMatch = 4;
  if (inputLength < minMatch) {
    _writeLastLiterals(writer, input, dictLength, inputLength);
    return;
  }

  final hashTable = Int32List(_hashSize);
  hashTable.fillRange(0, _hashSize, -1);
  final chain = Int32List(input.length);
  chain.fillRange(0, input.length, -1);

  int insert(int pos) {
    final seq = _readUint32LE(input, pos);
    final h = _hash(seq, _hashShift);
    final ref = hashTable[h];
    if (ref < pos) {
      chain[pos] = ref;
      hashTable[h] = pos;
    }
    return ref;
  }

  if (dictLength != 0) {
    for (var pos = 0; pos <= dictLength - minMatch; pos++) {
      insert(pos);
    }
  }

  var anchor = dictLength;
  var i = dictLength;

  final totalLength = input.length;
  final searchLimit = totalLength - 12;

  while (i <= searchLimit) {
    var candidate = insert(i);

    var bestLen = 0;
    var bestRef = -1;

    var depth = 0;
    while (candidate >= 0 && depth < opt.maxSearchDepth) {
      final distance = i - candidate;
      if (distance > 0xFFFF) {
        break;
      }

      if (_readUint32LE(input, candidate) == _readUint32LE(input, i)) {
        var matchLen = minMatch;
        while (i + matchLen < totalLength - 5 &&
            input[i + matchLen] == input[candidate + matchLen]) {
          matchLen++;
        }
        if (matchLen > bestLen) {
          bestLen = matchLen;
          bestRef = candidate;
          if (i + bestLen >= totalLength - 5) {
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
      var actualLen = bestLen;

      while (matchStart > anchor &&
          refStart > 0 &&
          input[matchStart - 1] == input[refStart - 1]) {
        matchStart--;
        refStart--;
        actualLen++;
      }

      final literalLength = matchStart - anchor;
      _writeSequence(
        writer,
        input,
        anchor,
        literalLength,
        matchStart - refStart,
        actualLen,
      );

      i = matchStart + actualLen;
      anchor = i;

      if (i > totalLength - minMatch) {
        break;
      }

      var j = i - actualLen + 1;
      final stop = i - minMatch;
      while (j <= stop) {
        insert(j);
        j++;
      }

      continue;
    }

    i++;
  }

  final lastLiterals = totalLength - anchor;
  if (lastLiterals != 0) {
    _writeLastLiterals(writer, input, anchor, lastLiterals);
  }
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
