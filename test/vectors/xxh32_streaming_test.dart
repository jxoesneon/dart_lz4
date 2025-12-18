import 'dart:typed_data';

import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

int _mul32(int a, int b) {
  final al = a & 0xffff;
  final ah = (a >>> 16) & 0xffff;
  final bl = b & 0xffff;
  final bh = (b >>> 16) & 0xffff;

  final lo = al * bl;
  final mid = (ah * bl + al * bh) & 0xffff;

  return (lo + (mid << 16)) & 0xffffffff;
}

void main() {
  test('Xxh32 streaming matches xxh32 one-shot', () {
    const prime32_1 = 0x9E3779B1;

    final testData = Uint8List(101);
    var byteGen = prime32_1;
    for (var i = 0; i < testData.length; i++) {
      testData[i] = (byteGen >>> 24) & 0xff;
      byteGen = _mul32(byteGen, byteGen);
    }

    for (final seed in [0, prime32_1]) {
      final expected = xxh32(testData, seed: seed);

      final h1 = Xxh32(seed: seed);
      h1.update(testData);
      expect(h1.digest(), expected);

      final h2 = Xxh32(seed: seed);
      for (var i = 0; i < testData.length; i++) {
        h2.update(testData, start: i, end: i + 1);
      }
      expect(h2.digest(), expected);

      final h3 = Xxh32(seed: seed);
      h3.update(testData, start: 0, end: 13);
      h3.update(testData, start: 13, end: 57);
      h3.update(testData, start: 57, end: testData.length);
      expect(h3.digest(), expected);

      final h4 = Xxh32(seed: seed);
      for (var i = 0; i < testData.length; i += 7) {
        final end = (i + 7) > testData.length ? testData.length : (i + 7);
        h4.update(testData, start: i, end: end);
      }
      expect(h4.digest(), expected);

      final emptyExpected = xxh32(Uint8List(0), seed: seed);
      final emptyHasher = Xxh32(seed: seed);
      expect(emptyHasher.digest(), emptyExpected);
    }
  });
}
