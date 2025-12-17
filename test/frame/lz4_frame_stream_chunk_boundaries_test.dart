import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:test/test.dart';

Iterable<List<int>> _randomChunk(Uint8List bytes, Random r,
    {int maxSize = 8192}) sync* {
  var offset = 0;
  while (offset < bytes.length) {
    final size = 1 + r.nextInt(maxSize);
    final end = min(bytes.length, offset + size);
    yield bytes.sublist(offset, end);
    offset = end;
  }
}

Uint8List _concat(List<List<int>> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final c in chunks) {
    builder.add(c);
  }
  return builder.takeBytes();
}

Uint8List _makeDependentFriendlyPayload({required int blockSize}) {
  final block = Uint8List(blockSize);
  for (var i = 0; i < block.length; i++) {
    block[i] = (i * 31) & 0xff;
  }

  final shifted1 = Uint8List(blockSize);
  shifted1.setRange(0, blockSize - 1, block, 1);
  shifted1[blockSize - 1] = block[blockSize - 1];

  final shifted2 = Uint8List(blockSize);
  shifted2.setRange(0, blockSize - 2, block, 2);
  shifted2[blockSize - 2] = block[blockSize - 2];
  shifted2[blockSize - 1] = block[blockSize - 1];

  final src = Uint8List(blockSize * 3);
  src.setRange(0, blockSize, block);
  src.setRange(blockSize, blockSize * 2, shifted1);
  src.setRange(blockSize * 2, blockSize * 3, shifted2);
  return src;
}

Future<Uint8List> _encodeStreaming({
  required Uint8List src,
  required Lz4FrameOptions options,
  required Random r,
}) async {
  final encodedChunks = await Stream<List<int>>.fromIterable(
    _randomChunk(src, r, maxSize: 8192),
  ).transform(lz4FrameEncoderWithOptions(options: options)).toList();

  return _concat(encodedChunks);
}

Future<Uint8List> _decodeStreaming({
  required Uint8List encoded,
  required Random r,
}) async {
  final outChunks = await Stream<List<int>>.fromIterable(
    _randomChunk(encoded, r, maxSize: 1024),
  ).transform(lz4FrameDecoder()).toList();

  return _concat(outChunks);
}

void main() {
  test('streaming encode/decode round-trips across random chunk boundaries',
      () async {
    final src = _makeDependentFriendlyPayload(blockSize: 64 * 1024);

    for (var i = 0; i < 25; i++) {
      final independent = await _encodeStreaming(
        src: src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: true,
        ),
        r: Random(1000 + i),
      );

      final dependent = await _encodeStreaming(
        src: src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: false,
        ),
        r: Random(2000 + i),
      );

      final decodedIndependent = await _decodeStreaming(
        encoded: independent,
        r: Random(3000 + i),
      );
      final decodedDependent = await _decodeStreaming(
        encoded: dependent,
        r: Random(4000 + i),
      );

      expect(decodedIndependent, src);
      expect(decodedDependent, src);
    }
  });

  test('streaming decoder handles concatenated frames with random boundaries',
      () async {
    final a = Uint8List.fromList('A'.codeUnits);
    final b = Uint8List.fromList(List<int>.filled(128 * 1024, 0x42));

    final encA = await _encodeStreaming(
      src: a,
      options: Lz4FrameOptions(),
      r: Random(5000),
    );
    final encB = await _encodeStreaming(
      src: b,
      options: Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        blockIndependence: false,
      ),
      r: Random(6000),
    );

    final combined = Uint8List(encA.length + encB.length);
    combined.setRange(0, encA.length, encA);
    combined.setRange(encA.length, combined.length, encB);

    final decoded = await _decodeStreaming(encoded: combined, r: Random(7000));
    expect(decoded, Uint8List.fromList([...a, ...b]));
  });
}
