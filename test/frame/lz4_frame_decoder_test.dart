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

_Bytes _u64le(int v) {
  return <int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
    0,
    0,
    0,
    0,
  ];
}

Uint8List _buildFrame({
  required int flg,
  required int bd,
  required List<_FrameBlock> blocks,
  bool addContentChecksum = false,
  int? contentSize,
  int? dictId,
}) {
  const magic = 0x184D2204;

  final descriptorBytes = <int>[flg, bd];
  final contentSizeFlag = ((flg >> 3) & 0x01) != 0;
  final dictIdFlag = (flg & 0x01) != 0;
  if (contentSizeFlag) {
    descriptorBytes.addAll(_u64le(contentSize ?? 0));
  }
  if (dictIdFlag) {
    descriptorBytes.addAll(_u32le(dictId ?? 0));
  }
  final hc = (xxh32(Uint8List.fromList(descriptorBytes), seed: 0) >> 8) & 0xff;

  final out = <int>[];
  out.addAll(_u32le(magic));
  out.add(flg);
  out.add(bd);

  if (contentSizeFlag) {
    out.addAll(_u64le(contentSize ?? 0));
  }
  if (dictIdFlag) {
    out.addAll(_u32le(dictId ?? 0));
  }

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

  test('unsupported frame version throws', () {
    const flg = 0x20;
    const bd = 0x40;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('A'.codeUnits),
          decoded: Uint8List.fromList('A'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(() => lz4FrameDecode(frame),
        throwsA(isA<Lz4UnsupportedFeatureException>()));
  });

  test('reserved FLG bit set throws', () {
    const flg = 0x62;
    const bd = 0x40;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('A'.codeUnits),
          decoded: Uint8List.fromList('A'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(() => lz4FrameDecode(frame), throwsA(isA<Lz4FormatException>()));
  });

  test('reserved BD bits set throws', () {
    const flg = 0x60;
    const bd = 0x41;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('A'.codeUnits),
          decoded: Uint8List.fromList('A'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(() => lz4FrameDecode(frame), throwsA(isA<Lz4FormatException>()));
  });

  test('invalid block maximum size throws', () {
    const flg = 0x60;
    const bd = 0x30;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('A'.codeUnits),
          decoded: Uint8List.fromList('A'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(() => lz4FrameDecode(frame), throwsA(isA<Lz4FormatException>()));
  });

  test('dictionary id flag throws unsupported', () {
    const flg = 0x61;
    const bd = 0x40;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      dictId: 0x12345678,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('A'.codeUnits),
          decoded: Uint8List.fromList('A'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(() => lz4FrameDecode(frame),
        throwsA(isA<Lz4UnsupportedFeatureException>()));
  });

  test('content size mismatch throws', () {
    const flg = 0x68;
    const bd = 0x40;

    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      contentSize: 6,
      blocks: [
        _FrameBlock(
          payload: Uint8List.fromList('Hello'.codeUnits),
          decoded: Uint8List.fromList('Hello'.codeUnits),
          isUncompressed: true,
        ),
      ],
    );

    expect(
        () => lz4FrameDecode(frame), throwsA(isA<Lz4CorruptDataException>()));
  });

  test('block checksum mismatch throws', () {
    const flg = 0x70;
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

    final bad = Uint8List.fromList(frame);
    final checksumOffset = 7 + 4 + 5;
    bad[checksumOffset] ^= 0xff;

    expect(() => lz4FrameDecode(bad), throwsA(isA<Lz4CorruptDataException>()));
  });

  test('content checksum mismatch throws', () {
    const flg = 0x64;
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
      addContentChecksum: true,
    );

    final bad = Uint8List.fromList(frame);
    bad[bad.length - 1] ^= 0xff;

    expect(() => lz4FrameDecode(bad), throwsA(isA<Lz4CorruptDataException>()));
  });

  test('block size exceeds maximum throws', () {
    const flg = 0x60;
    const bd = 0x40;

    final payload = Uint8List(65537);
    final frame = _buildFrame(
      flg: flg,
      bd: bd,
      blocks: [
        _FrameBlock(
          payload: payload,
          decoded: payload,
          isUncompressed: true,
        ),
      ],
    );

    expect(
        () => lz4FrameDecode(frame), throwsA(isA<Lz4CorruptDataException>()));
  });

  test('truncated frame throws', () {
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

    final truncated = Uint8List.sublistView(frame, 0, frame.length - 1);
    expect(() => lz4FrameDecode(truncated), throwsA(isA<Lz4FormatException>()));
  });
}
