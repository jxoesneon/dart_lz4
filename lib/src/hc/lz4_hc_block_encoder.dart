import 'dart:typed_data';

import '../internal/byte_writer.dart';
import '../internal/lz4_engine.dart';
import 'lz4_hc_options.dart';

const _hashLog = 16;
const _hashSize = 1 << _hashLog;
const _hashShift = 32 - _hashLog;

/// Pure Dart implementation of the LZ4 HC compression engine.
final class PureDartLz4HcEngine implements Lz4CompressionEngine {
  /// Options for tuning the HC compression.
  final Lz4HcOptions options;

  final Int32List _hashTable = Int32List(_hashSize);
  Int32List _chain = Int32List(0);

  /// Creates an HC compression engine with the given [options].
  PureDartLz4HcEngine({required this.options}) {
    _hashTable.fillRange(0, _hashSize, -1);
  }

  @override
  void compress(
    ByteWriter writer,
    Uint8List src, {
    Uint8List? dictionary,
  }) {
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

    final hashTable = _hashTable;

    if (_chain.length < input.length) {
      _chain = Int32List(input.length);
      _chain.fillRange(0, _chain.length, -1);
    }
    final chain = _chain;

    final inputData =
        ByteData.view(input.buffer, input.offsetInBytes, input.length);

    int insert(int pos) {
      final seq = _readUint32LE(inputData, pos);
      final h = _hash(seq);
      var ref = hashTable[h];
      if (ref >= pos) {
        ref = -1;
      }
      chain[pos] = ref;
      hashTable[h] = pos;
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

    final maxSearchDepth = options.searchDepth;

    while (i <= searchLimit) {
      var candidate = insert(i);

      var bestLen = 0;
      var bestRef = -1;

      var depth = 0;
      while (candidate >= 0 && candidate < i && depth < maxSearchDepth) {
        final distance = i - candidate;
        if (distance > 0xFFFF) {
          break;
        }

        if (_readUint32LE(inputData, candidate) ==
            _readUint32LE(inputData, i)) {
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
}

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
  PureDartLz4HcEngine(options: options ?? Lz4HcOptions())
      .compress(writer, src, dictionary: dictionary);
}

@pragma('vm:prefer-inline')
int _readUint32LE(ByteData data, int offset) =>
    data.getUint32(offset, Endian.little);

@pragma('vm:prefer-inline')
int _hash(int value) => (value * 2654435761 & 0xffffffff) >>> _hashShift;

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
