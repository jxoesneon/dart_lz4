import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

Iterable<List<int>> _chunk(Uint8List bytes, List<int> sizes) sync* {
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

List<int> _u32le(int v) =>
    <int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

Uint8List _frameWithDictId({required int dictId}) {
  const magic = 0x184D2204;
  const flg = 0x61;
  const bd = 0x40;

  final descriptorBytes = <int>[flg, bd, ..._u32le(dictId)];
  final hc = (xxh32(Uint8List.fromList(descriptorBytes), seed: 0) >> 8) & 0xff;

  return Uint8List.fromList(<int>[
    ..._u32le(magic),
    flg,
    bd,
    ..._u32le(dictId),
    hc,
    ..._u32le(0),
  ]);
}

void main() {
  test('lz4FrameDecoder transformer decodes chunked input', () async {
    final src = Uint8List.fromList('Hello streaming frame decode'.codeUnits);
    final encoded = lz4FrameEncode(src);

    final outChunks = await Stream<List<int>>.fromIterable(
      _chunk(encoded, [1, 2, 3, 1, 5, 8]),
    ).transform(lz4FrameDecoder()).toList();

    expect(_concat(outChunks), src);
  });

  test('lz4FrameDecoder transformer decodes multiple concatenated frames',
      () async {
    final a = Uint8List.fromList('A'.codeUnits);
    final b = Uint8List.fromList('B'.codeUnits);

    final encA = lz4FrameEncode(a);
    final encB = lz4FrameEncode(b);

    final combined = Uint8List(encA.length + encB.length);
    combined.setRange(0, encA.length, encA);
    combined.setRange(encA.length, combined.length, encB);

    final outChunks = await Stream<List<int>>.fromIterable(
      _chunk(combined, [1, 1, 2, 1, 3]),
    ).transform(lz4FrameDecoder()).toList();

    expect(_concat(outChunks), Uint8List.fromList([...a, ...b]));
  });

  test('lz4FrameDecoder transformer enforces maxOutputBytes', () async {
    final src = Uint8List.fromList('Hello'.codeUnits);
    final encoded = lz4FrameEncode(src);

    final future = Stream<List<int>>.fromIterable(
      _chunk(encoded, [1, 2, 1, 4]),
    ).transform(lz4FrameDecoder(maxOutputBytes: 4)).toList();

    await expectLater(future, throwsA(isA<Lz4OutputLimitException>()));
  });

  test('lz4FrameDecoder transformer rejects truncated input', () async {
    final src = Uint8List.fromList('Hello'.codeUnits);
    final encoded = lz4FrameEncode(src);
    final truncated = Uint8List.sublistView(encoded, 0, encoded.length - 1);

    final future = Stream<List<int>>.fromIterable(
      _chunk(truncated, [2, 1, 1]),
    ).transform(lz4FrameDecoder()).toList();

    await expectLater(future, throwsA(isA<Lz4FormatException>()));
  });

  test('lz4FrameDecoder transformer rejects frames with dictId flag', () async {
    final encoded = _frameWithDictId(dictId: 0x12345678);

    final future = Stream<List<int>>.fromIterable(
      _chunk(encoded, [1, 2, 1, 3, 1, 5]),
    ).transform(lz4FrameDecoder()).toList();

    await expectLater(
      future,
      throwsA(
        isA<Lz4UnsupportedFeatureException>().having(
          (e) => e.message,
          'message',
          'Dictionary ID present but no dictionary resolver provided',
        ),
      ),
    );
  });
}
