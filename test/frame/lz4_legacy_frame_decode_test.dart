import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

typedef _Bytes = List<int>;

_Bytes _u32le(int v) =>
    <int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

Uint8List _buildLegacyFrame(List<Uint8List> compressedBlocks) {
  const magic = 0x184C2102;

  final out = BytesBuilder(copy: false);
  out.add(_u32le(magic));

  for (final block in compressedBlocks) {
    out.add(_u32le(block.length));
    out.add(block);
  }

  return out.takeBytes();
}

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

Uint8List _filled(int length, int byte) {
  final out = Uint8List(length);
  out.fillRange(0, length, byte & 0xff);
  return out;
}

void main() {
  late final Uint8List legacyTwoBlockFrame;
  late final Uint8List legacyBlock0;
  late final Uint8List legacyBlock1;

  setUpAll(() {
    legacyBlock0 = _filled(8 * 1024 * 1024, 0x41);
    legacyBlock1 = Uint8List.fromList('tail'.codeUnits);

    final c0 = lz4Compress(legacyBlock0);
    final c1 = lz4Compress(legacyBlock1);

    legacyTwoBlockFrame = _buildLegacyFrame([c0, c1]);
  });

  test('legacy frame decodes (sync)', () {
    final out = lz4FrameDecode(legacyTwoBlockFrame);

    expect(out.length, legacyBlock0.length + legacyBlock1.length);
    expect(Uint8List.sublistView(out, 0, legacyBlock0.length), legacyBlock0);
    expect(
      Uint8List.sublistView(out, legacyBlock0.length, out.length),
      legacyBlock1,
    );
  });

  test('legacy frame decodes (streaming)', () async {
    final outChunks = await Stream<List<int>>.fromIterable(
      _chunk(legacyTwoBlockFrame, [1, 2, 3, 5, 8, 13, 21]),
    ).transform(lz4FrameDecoder()).toList();

    final out = _concat(outChunks);

    expect(out.length, legacyBlock0.length + legacyBlock1.length);
    expect(Uint8List.sublistView(out, 0, legacyBlock0.length), legacyBlock0);
    expect(
      Uint8List.sublistView(out, legacyBlock0.length, out.length),
      legacyBlock1,
    );
  });

  test('legacy frame rejects non-full block before another block', () {
    final a = _filled(1024, 0x42);
    final b = Uint8List.fromList([0x00]);

    final frame = _buildLegacyFrame([lz4Compress(a), lz4Compress(b)]);

    expect(
      () => lz4FrameDecode(frame),
      throwsA(isA<Lz4CorruptDataException>()),
    );
  });

  test('legacy frame can be followed by current frame', () {
    final legacy = _buildLegacyFrame([
      lz4Compress(Uint8List.fromList('legacy'.codeUnits)),
    ]);
    final current = lz4FrameEncode(Uint8List.fromList('current'.codeUnits));

    final combined = Uint8List(legacy.length + current.length);
    combined.setRange(0, legacy.length, legacy);
    combined.setRange(legacy.length, combined.length, current);

    final out = lz4FrameDecode(combined);
    expect(out, Uint8List.fromList('legacycurrent'.codeUnits));
  });
}
