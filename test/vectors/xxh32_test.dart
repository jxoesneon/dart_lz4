import 'dart:typed_data';

import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

void main() {
  test('xxh32 reference vectors', () {
    const prime32_1 = 0x9E3779B1;

    final testData = Uint8List(101);
    var byteGen = prime32_1;
    for (var i = 0; i < testData.length; i++) {
      testData[i] = (byteGen >>> 24) & 0xff;
      byteGen = (byteGen * byteGen) & 0xffffffff;
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
