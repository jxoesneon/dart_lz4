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
  test('xxh32 reference vectors', () {
    const prime32_1 = 0x9E3779B1;

    final testData = Uint8List(101);
    var byteGen = prime32_1;
    for (var i = 0; i < testData.length; i++) {
      testData[i] = (byteGen >>> 24) & 0xff;
      byteGen = _mul32(byteGen, byteGen);
    }

    expect(xxh32(Uint8List(0), seed: 0), 0x02CC5D05);
    expect(xxh32(Uint8List(0), seed: prime32_1), 0x36B78AE7);

    expect(xxh32(Uint8List.sublistView(testData, 0, 1), seed: 0), 0xB85CBEE5);
    expect(xxh32(Uint8List.sublistView(testData, 0, 1), seed: prime32_1),
        0xD5845D64);

    expect(xxh32(Uint8List.sublistView(testData, 0, 14), seed: 0), 0xE5AA0AB4);
    expect(xxh32(Uint8List.sublistView(testData, 0, 14), seed: prime32_1),
        0x4481951D);

    expect(xxh32(testData, seed: 0), 0x1F1AA412);
    expect(xxh32(testData, seed: prime32_1), 0x498EC8E2);
  });
}
