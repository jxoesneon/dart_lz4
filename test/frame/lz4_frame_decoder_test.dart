import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

typedef _Bytes = List<int>;

class _FrameBlock {
  final Uint8List payload;
  final Uint8List decoded;
  final bool isUncompressed;

  const _FrameBlock({
    required this.payload,
    required this.decoded,
    required this.isUncompressed,
  });
}

_Bytes _u32le(int v) =>
    <int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

Uint8List _buildFrame({
  required int flg,
  required int bd,
  required List<_FrameBlock> blocks,
  bool addContentChecksum = false,
}) {
  const magic = 0x184D2204;

  final descriptor = Uint8List.fromList([flg, bd]);
  final hc = (xxh32(descriptor, seed: 0) >> 8) & 0xff;

  final out = <int>[];
  out.addAll(_u32le(magic));
  out.add(flg);
  out.add(bd);
  out.add(hc);

  final decodedAll = <int>[];

  final blockChecksum = ((flg >> 4) & 0x01) != 0;

  for (final b in blocks) {
    final blockSizeRaw = (b.isUncompressed ? 0x80000000 : 0) | b.payload.length;
    out.addAll(_u32le(blockSizeRaw));
    out.addAll(b.payload);

    if (blockChecksum) {
      final checksum = xxh32(b.payload, seed: 0);
      out.addAll(_u32le(checksum));
    }

    decodedAll.addAll(b.decoded);
  }

  out.addAll(_u32le(0));

  if (addContentChecksum) {
    final checksum = xxh32(Uint8List.fromList(decodedAll), seed: 0);
    out.addAll(_u32le(checksum));
  }

  return Uint8List.fromList(out);
}

void main() {
  test('frame decodes uncompressed block', () {
    const flg = 0x60; // version=01, block independence=1
    const bd = 0x40; // 64KB max block size

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('Hello'.codeUnits),
          decoded: Uint8List.fromList('Hello'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    final out = lz4FrameDecode(frame);
    expect(out, Uint8List.fromList('Hello'.codeUnits));
  });

  test('frame decodes block with checksum enabled', () {
    const flg = 0x70; // version=01, block independence=1, block checksum=1
    const bd = 0x40; // 64KB

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('Hello'.codeUnits),
          decoded: Uint8List.fromList('Hello'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    final out = lz4FrameDecode(frame);
    expect(out, Uint8List.fromList('Hello'.codeUnits));
  });

  test('frame decodes with content checksum enabled', () {
    const flg = 0x64; // version=01, block independence=1, content checksum=1
    const bd = 0x40; // 64KB

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('Hello'.codeUnits),
          decoded: Uint8List.fromList('Hello'.codeUnits),
          isUncompressed: true,
        ),
      ],
      addContentChecksum: true,
    );

    final out = lz4FrameDecode(frame);
    expect(out, Uint8List.fromList('Hello'.codeUnits));
  });

  test('dependent blocks can reference history from previous block', () {
    const flg = 0x40; // version=01, block independence=0
    const bd = 0x40; // 64KB

    final block1 = Uint8List.fromList('abcd'.codeUnits);
    final block2Compressed = Uint8List.fromList([
      0x00, // token: 0 literals, matchlen base 0 => 4
      0x04, 0x00, // distance 4
    ]);

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: block1,
          decoded: block1,
          isUncompressed: true,
        ),
        _FrameBlock(
          payload: block2Compressed,
          decoded: Uint8List.fromList('abcd'.codeUnits),
          isUncompressed: false,
        ),
      ],
    );

    final out = lz4FrameDecode(frame);
    expect(out, Uint8List.fromList('abcdabcd'.codeUnits));
  });

  test('invalid header checksum throws', () {
    const flg = 0x60;
    const bd = 0x40;

    final good = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('Hello'.codeUnits),
          decoded: Uint8List.fromList('Hello'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    final bad = Uint8List.fromList(good);
    bad[6] ^= 0xff; // corrupt HC byte

    expect(() => lz4FrameDecode(bad), throwsA(isA<Lz4CorruptDataException>()));
  });

  test('skippable frames are skipped', () {
    const skippableMagic = 0x184D2A50;

    const flg = 0x60;
    const bd = 0x40;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('OK'.codeUnits),
          decoded: Uint8List.fromList('OK'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    final combined = <int>[];
    combined.addAll(_u32le(skippableMagic));
    combined.addAll(_u32le(4));
    combined.addAll(<int>[1, 2, 3, 4]);
    combined.addAll(frame);

    final out = lz4FrameDecode(Uint8List.fromList(combined));
    expect(out, Uint8List.fromList('OK'.codeUnits));
  });

  test('maxOutputBytes enforces output limit', () {
    const flg = 0x60;
    const bd = 0x40;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('Hello'.codeUnits),
          decoded: Uint8List.fromList('Hello'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(
      () => lz4FrameDecode(frame, maxOutputBytes: 4),
      throwsA(isA<Lz4OutputLimitException>()),
    );
  });
}
