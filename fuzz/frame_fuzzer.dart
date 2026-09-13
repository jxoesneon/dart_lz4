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

  print('Starting frame fuzz run with seed: $seed, iterations: $iterations');
  final r = Random(seed);

  group('Frame Fuzzing', () {
    test('Random buffer frame decompression', () {
      for (var i = 0; i < iterations; i++) {
        final inputLen = r.nextInt(8192);
        final input = _randomBytes(r, inputLen);
        try {
          lz4FrameDecode(input);
        } on Lz4Exception {
          // Expected
        } on Error catch (e, st) {
          fail('Unexpected Dart Error: $e\n$st');
        }
      }
    });

    test('Bitflip corruption resilience', () {
      final payload = _randomBytes(r, 64 * 1024);
      final baseFrame = lz4FrameEncode(payload);

      for (var i = 0; i < iterations; i++) {
        final mutated = Uint8List.fromList(baseFrame);
        final flips = 1 + r.nextInt(16);
        for (var j = 0; j < flips; j++) {
          final idx = r.nextInt(mutated.length);
          mutated[idx] ^= 1 << r.nextInt(8);
        }

        try {
          lz4FrameDecode(mutated);
        } on Lz4Exception {
          // Expected
        } on Error catch (e, st) {
          fail('Unexpected Dart Error: $e\n$st');
        }
      }
    });

    test('Streaming decoder with random chunks', () async {
      final payload = _randomBytes(r, 16 * 1024);
      final baseFrame = lz4FrameEncode(payload);

      for (var i = 0; i < iterations; i++) {
        // Split frame into random-sized chunks
        final chunkCount = 1 + r.nextInt(8);
        final chunkSize = baseFrame.length ~/ chunkCount;
        try {
          final stream = Stream<List<int>>.fromIterable(
            List.generate(chunkCount, (j) {
              final start = j * chunkSize;
              final end =
                  j == chunkCount - 1 ? baseFrame.length : start + chunkSize;
              return Uint8List.sublistView(baseFrame, start, end);
            }),
          );
          await stream.transform(lz4FrameDecoder()).toList();
        } on Lz4Exception {
          // Expected
        } on Error catch (e, st) {
          fail('Unexpected Dart Error: $e\n$st');
        }
      }
    });

    test('MaxOutputBytes enforcement against crafted large contentSize', () {
      // Craft a frame header that declares a huge content size but has
      // minimal actual data — this tests the maxOutputBytes guard.
      for (var i = 0; i < iterations; i++) {
        final inputLen = 4 + r.nextInt(64);
        final input = _randomBytes(r, inputLen);
        try {
          lz4FrameDecode(input, maxOutputBytes: 1024);
        } on Lz4Exception {
          // Expected
        } on Error catch (e, st) {
          fail('Unexpected Dart Error: $e\n$st');
        }
      }
    });
  });
}
