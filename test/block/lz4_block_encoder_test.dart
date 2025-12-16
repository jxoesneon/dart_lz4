import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

void main() {
  Uint8List roundTrip(Uint8List input, {int acceleration = 1}) {
    final compressed = lz4Compress(input, acceleration: acceleration);
    return lz4Decompress(compressed, decompressedSize: input.length);
  }

  test('roundtrip empty', () {
    final input = Uint8List(0);
    final compressed = lz4Compress(input);
    expect(compressed, isEmpty);

    final out = lz4Decompress(compressed, decompressedSize: 0);
    expect(out, isEmpty);
  });

  test('roundtrip small (<4 bytes)', () {
    final input = Uint8List.fromList([1, 2, 3]);
    expect(roundTrip(input), input);
  });

  test('roundtrip repeated pattern', () {
    final input = Uint8List.fromList(List<int>.filled(256, 0x41));
    expect(roundTrip(input), input);
  });

  test('roundtrip mixed data', () {
    final input = Uint8List.fromList([
      ...List<int>.generate(64, (i) => i),
      ...List<int>.filled(64, 0x00),
      ...List<int>.generate(64, (i) => 255 - i),
      ...List<int>.filled(64, 0x7f),
    ]);
    expect(roundTrip(input), input);
  });

  test('acceleration parameter accepted', () {
    final input = Uint8List.fromList(List<int>.generate(512, (i) => i & 0xff));
    expect(roundTrip(input, acceleration: 1), input);
    expect(roundTrip(input, acceleration: 2), input);
    expect(roundTrip(input, acceleration: 4), input);
  });

  test('acceleration < 1 throws', () {
    expect(
      () => lz4Compress(Uint8List(0), acceleration: 0),
      throwsA(isA<RangeError>()),
    );
  });

  test('hc mode roundtrips (or is unsupported)', () {
    final input = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

    try {
      final compressed = lz4Compress(input, level: Lz4CompressionLevel.hc);
      final out = lz4Decompress(compressed, decompressedSize: input.length);
      expect(out, input);
    } on Lz4UnsupportedFeatureException {
      // OK: HC is optional until implemented.
    }
  });
}
