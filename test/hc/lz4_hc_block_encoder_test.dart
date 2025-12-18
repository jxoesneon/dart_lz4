import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/hc/lz4_hc_block_encoder.dart';
import 'package:test/test.dart';

void main() {
  Uint8List roundTripHc(Uint8List input) {
    final compressed = lz4Compress(input, level: Lz4CompressionLevel.hc);
    return lz4Decompress(compressed, decompressedSize: input.length);
  }

  test('hc block encoder round-trips small inputs', () {
    expect(roundTripHc(Uint8List(0)), Uint8List(0));
    expect(roundTripHc(Uint8List.fromList([1])), Uint8List.fromList([1]));
    expect(
      roundTripHc(Uint8List.fromList([1, 2, 3])),
      Uint8List.fromList([1, 2, 3]),
    );
  });

  test('hc block encoder round-trips mixed data', () {
    final input = Uint8List.fromList([
      ...List<int>.generate(128, (i) => i & 0xff),
      ...List<int>.filled(128, 0x00),
      ...List<int>.generate(128, (i) => 255 - (i & 0xff)),
      ...List<int>.filled(128, 0x7f),
    ]);
    expect(roundTripHc(input), input);
  });

  test('hc block encoder compresses repeated data (basic ratio sanity)', () {
    final input = Uint8List.fromList(List<int>.filled(64 * 1024, 0x41));
    final fast = lz4Compress(input, level: Lz4CompressionLevel.fast);
    final hc = lz4Compress(input, level: Lz4CompressionLevel.hc);

    expect(lz4Decompress(hc, decompressedSize: input.length), input);
    expect(hc.length, lessThan(input.length));

    expect(hc.length, lessThanOrEqualTo(fast.length));
  });

  test('hc block encoder round-trips random-ish data', () {
    final rng = Random(1);
    final input = Uint8List(32 * 1024);
    for (var i = 0; i < input.length; i++) {
      input[i] = rng.nextInt(256);
    }

    expect(roundTripHc(input), input);
  });

  test('Lz4HcOptions validates maxSearchDepth', () {
    expect(() => Lz4HcOptions(maxSearchDepth: 0), throwsA(isA<RangeError>()));
    expect(() => Lz4HcOptions(maxSearchDepth: 1), returnsNormally);
  });

  test('lz4HcBlockCompress accepts options and round-trips', () {
    final input = Uint8List.fromList(List<int>.filled(4096, 0x41));

    final compressed = lz4HcBlockCompress(
      input,
      options: Lz4HcOptions(maxSearchDepth: 8),
    );

    final out = lz4Decompress(compressed, decompressedSize: input.length);
    expect(out, input);
  });
}
