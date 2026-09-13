import 'dart:typed_data';

import '../internal/byte_writer.dart';
import '../internal/lz4_block_codec.dart';
import '../internal/lz4_engine.dart';

const _hashLog = 16;
const _hashSize = 1 << _hashLog;
const _hashShift = 32 - _hashLog;

/// Pure Dart implementation of the LZ4 fast compression engine.
final class PureDartLz4FastEngine implements Lz4CompressionEngine {
  /// Acceleration for fast compression.
  final int acceleration;

  final Int32List _hashTable = Int32List(_hashSize);

  /// Creates a fast compression engine with the given [acceleration].
  PureDartLz4FastEngine({this.acceleration = 1}) {
    if (acceleration < 1) {
      throw RangeError.value(acceleration, 'acceleration');
    }
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
      writeLastLiterals(writer, input, dictLength, inputLength);
      return;
    }

    final hashTable = _hashTable;

    // Reset hash table between calls to prevent stale entries from leaking
    // across blocks when the engine is reused (e.g. in frame encoding).
    hashTable.fillRange(0, _hashSize, -1);

    final inputData =
        ByteData.view(input.buffer, input.offsetInBytes, input.length);

    if (dictLength != 0) {
      for (var pos = 0; pos <= dictLength - minMatch; pos++) {
        final seq = _readUint32LE(inputData, pos);
        hashTable[_hash(seq)] = pos;
      }
    }

    var anchor = dictLength;
    var i = dictLength;

    final totalLength = input.length;

    final searchLimit = totalLength - 12;

    while (i <= searchLimit) {
      final seq = _readUint32LE(inputData, i);
      final h = _hash(seq);

      final ref = hashTable[h];
      hashTable[h] = i;

      final distance = i - ref;
      if (ref >= 0 &&
          ref < i &&
          distance <= 0xFFFF &&
          _readUint32LE(inputData, ref) == seq) {
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

        final matchLimit = totalLength - 5;
        while (matchStart + matchLength < matchLimit &&
            input[matchStart + matchLength] == input[refStart + matchLength]) {
          matchLength++;
        }

        writeSequence(
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
          final s = _readUint32LE(inputData, j);
          hashTable[_hash(s)] = j;
          j++;
        }

        continue;
      }

      i += 1 + ((i - anchor) >> acceleration);
    }

    final lastLiterals = totalLength - anchor;
    if (lastLiterals != 0) {
      writeLastLiterals(writer, input, anchor, lastLiterals);
    }
  }
}

Uint8List lz4BlockCompress(
  Uint8List src, {
  Uint8List? dictionary,
  int acceleration = 1,
}) {
  final writer = ByteWriter(initialCapacity: src.length);
  lz4BlockCompressToWriter(writer, src,
      dictionary: dictionary, acceleration: acceleration);
  return writer.toBytes();
}

void lz4BlockCompressToWriter(
  ByteWriter writer,
  Uint8List src, {
  Uint8List? dictionary,
  int acceleration = 1,
}) {
  PureDartLz4FastEngine(acceleration: acceleration)
      .compress(writer, src, dictionary: dictionary);
}

@pragma('vm:prefer-inline')
int _readUint32LE(ByteData data, int offset) =>
    data.getUint32(offset, Endian.little);

@pragma('vm:prefer-inline')
int _hash(int value) => (value * 2654435761 & 0xffffffff) >>> _hashShift;
