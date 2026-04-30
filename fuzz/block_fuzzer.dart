import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(Random r, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

void main() {
  final seed = int.tryParse(const String.fromEnvironment('FUZZ_SEED')) ??
      DateTime.now().millisecondsSinceEpoch;
  final iterations =
      int.tryParse(const String.fromEnvironment('FUZZ_ITERATIONS')) ?? 1000;

  print('Starting fuzz run with seed: $seed, iterations: $iterations');
  final r = Random(seed);

  group('Block Fuzzing', () {
    test('Random buffer decompression', () {
      for (var i = 0; i < iterations; i++) {
        final inputLen = r.nextInt(8192);
        final input = _randomBytes(r, inputLen);
        final decompressedSize = r.nextInt(16384);
        try {
          lz4Decompress(input, decompressedSize: decompressedSize);
        } on Lz4Exception {
          // Expected
        } on Error catch (e, st) {
          fail('Unexpected Dart Error: $e\n$st');
        }
      }
    });

    test('Bitflip corruption resilience', () {
      final payload = _randomBytes(r, 64 * 1024);
      final baseBlock = lz4Compress(payload);

      for (var i = 0; i < iterations; i++) {
        final mutated = Uint8List.fromList(baseBlock);
        final flips = 1 + r.nextInt(16);
        for (var j = 0; j < flips; j++) {
          final idx = r.nextInt(mutated.length);
          mutated[idx] ^= 1 << r.nextInt(8);
        }

        try {
          lz4Decompress(mutated, decompressedSize: payload.length);
        } on Lz4Exception {
          // Expected
        } on Error catch (e, st) {
          fail('Unexpected Dart Error: $e\n$st');
        }
      }
    });
  });
}
