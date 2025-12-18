import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
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

Uint8List _payload({required int size, required int seed}) {
  final r = Random(seed);
  final out = Uint8List(size);
  for (var i = 0; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

Iterable<List<int>> _chunk(Uint8List bytes) sync* {
  const sizes = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610];
  var offset = 0;
  var i = 0;
  while (offset < bytes.length) {
    final size = sizes[i % sizes.length];
    final end = (offset + size) > bytes.length ? bytes.length : (offset + size);
    yield bytes.sublist(offset, end);
    offset = end;
    i++;
  }
}

Uint8List _concat(List<List<int>> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final c in chunks) {
    builder.add(c);
  }
  return builder.takeBytes();
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
    expect(
      xxh32(Uint8List.sublistView(testData, 0, 1), seed: prime32_1),
      0xD5845D64,
    );

    expect(xxh32(Uint8List.sublistView(testData, 0, 14), seed: 0), 0xE5AA0AB4);
    expect(
      xxh32(Uint8List.sublistView(testData, 0, 14), seed: prime32_1),
      0x4481951D,
    );

    expect(xxh32(testData, seed: 0), 0x1F1AA412);
    expect(xxh32(testData, seed: prime32_1), 0x498EC8E2);
  });

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

  test('block round-trips', () {
    final src = _payload(size: 64 * 1024 + 7, seed: 1);

    final compressed = lz4Compress(src, level: Lz4CompressionLevel.fast);
    final decoded = lz4Decompress(compressed, decompressedSize: src.length);

    expect(decoded, src);
  });

  test('frame round-trips with dependent blocks', () {
    final src = _payload(size: 128 * 1024 + 123, seed: 2);

    final frame = lz4FrameEncodeWithOptions(
      src,
      options: Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        blockIndependence: false,
        blockChecksum: true,
        contentChecksum: true,
        contentSize: src.length,
        compression: Lz4FrameCompression.fast,
        acceleration: 1,
      ),
    );

    final decoded = lz4FrameDecode(frame, maxOutputBytes: src.length);
    expect(decoded, src);
  });

  test('frame (hc) round-trips with dependent blocks', () {
    final src = _payload(size: 96 * 1024 + 9, seed: 4);

    final frame = lz4FrameEncodeWithOptions(
      src,
      options: Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        blockIndependence: false,
        blockChecksum: true,
        contentChecksum: true,
        contentSize: src.length,
        compression: Lz4FrameCompression.hc,
      ),
    );

    final decoded = lz4FrameDecode(frame, maxOutputBytes: src.length);
    expect(decoded, src);
  });

  test('streaming frame encode/decode round-trips', () async {
    final src = _payload(size: 96 * 1024 + 11, seed: 3);

    final encodedChunks = await Stream<List<int>>.fromIterable(_chunk(src))
        .transform(
          lz4FrameEncoderWithOptions(
            options: Lz4FrameOptions(
              blockSize: Lz4FrameBlockSize.k64KB,
              blockIndependence: false,
              contentChecksum: true,
            ),
          ),
        )
        .toList();

    final decodedChunks = await Stream<List<int>>.fromIterable(encodedChunks)
        .transform(lz4FrameDecoder(maxOutputBytes: src.length))
        .toList();

    expect(_concat(decodedChunks), src);
  });
}
