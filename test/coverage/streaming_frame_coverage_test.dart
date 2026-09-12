import 'dart:async';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/internal/byte_writer.dart';
import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

List<int> _u32le(int v) => <int>[
      v & 0xff,
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ];

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

Uint8List _buildCustomFrame({
  int magic = 0x184D2204,
  int flg = 0x60, // version=1, blockIndependence=1
  int bd = 0x40, // 64KB
  int? contentSizeLow,
  int? contentSizeHigh,
  int? dictId,
  int? customHc,
  List<Uint8List> blocks = const [],
  bool uncompressedBlocks = false,
  bool blockChecksum = false,
  int? customBlockChecksum,
  bool endMark = true,
  int? contentChecksum,
}) {
  final writer = ByteWriter(initialCapacity: 128);
  writer.writeUint32LE(magic);

  final descWriter = ByteWriter(initialCapacity: 32);
  descWriter.writeUint8(flg);
  descWriter.writeUint8(bd);

  if (contentSizeLow != null && contentSizeHigh != null) {
    descWriter.writeUint32LE(contentSizeLow);
    descWriter.writeUint32LE(contentSizeHigh);
  }

  if (dictId != null) {
    descWriter.writeUint32LE(dictId);
  }

  final descBytes = descWriter.toBytes();
  writer.writeBytes(descBytes);

  if (customHc != null) {
    writer.writeUint8(customHc);
  } else {
    final hc = (xxh32(descBytes, seed: 0) >> 8) & 0xff;
    writer.writeUint8(hc);
  }

  for (final block in blocks) {
    final rawSize =
        uncompressedBlocks ? (0x80000000 | block.length) : block.length;
    writer.writeUint32LE(rawSize);
    writer.writeBytes(block);
    if (blockChecksum) {
      if (customBlockChecksum != null) {
        writer.writeUint32LE(customBlockChecksum);
      } else {
        writer.writeUint32LE(xxh32(block, seed: 0));
      }
    }
  }

  if (endMark) {
    writer.writeUint32LE(0);
  }

  if (contentChecksum != null) {
    writer.writeUint32LE(contentChecksum);
  }

  return writer.toBytes();
}

void main() {
  group('LZ4 Stream Decoder - Skippable Frames', () {
    test(
        'skips frames for all skippable magic numbers (0x184D2A50 - 0x184D2A5F)',
        () async {
      final payload = Uint8List.fromList('Regular frame data'.codeUnits);
      final regular = lz4FrameEncode(payload);

      for (var magic = 0x184D2A50; magic <= 0x184D2A5F; magic++) {
        final skippableMeta =
            Uint8List.fromList('Meta for magic $magic'.codeUnits);
        final skippable = BytesBuilder(copy: false);
        skippable.add(_u32le(magic));
        skippable.add(_u32le(skippableMeta.length));
        skippable.add(skippableMeta);
        final skippableBytes = skippable.takeBytes();

        final combined = Uint8List(skippableBytes.length + regular.length);
        combined.setRange(0, skippableBytes.length, skippableBytes);
        combined.setRange(skippableBytes.length, combined.length, regular);

        final outChunks = await Stream<List<int>>.fromIterable(
          _chunk(combined, [1, 3, 7, 2]),
        ).transform(lz4FrameDecoder()).toList();

        expect(_concat(outChunks), equals(payload));
      }
    });

    test('skips empty skippable frame (size = 0)', () async {
      final payload = Uint8List.fromList('Payload after 0-byte skip'.codeUnits);
      final regular = lz4FrameEncode(payload);

      final skippable = BytesBuilder(copy: false);
      skippable.add(_u32le(0x184D2A50));
      skippable.add(_u32le(0)); // size = 0
      final skippableBytes = skippable.takeBytes();

      final combined = Uint8List(skippableBytes.length + regular.length);
      combined.setRange(0, skippableBytes.length, skippableBytes);
      combined.setRange(skippableBytes.length, combined.length, regular);

      final outChunks = await Stream<List<int>>.fromIterable([combined])
          .transform(lz4FrameDecoder())
          .toList();

      expect(_concat(outChunks), equals(payload));
    });

    test('skips standalone skippable frame yielding empty stream', () async {
      final skippable = BytesBuilder(copy: false);
      skippable.add(_u32le(0x184D2A55));
      skippable.add(_u32le(4));
      skippable.add(Uint8List.fromList([10, 20, 30, 40]));

      final outChunks =
          await Stream<List<int>>.fromIterable([skippable.takeBytes()])
              .transform(lz4FrameDecoder())
              .toList();

      expect(_concat(outChunks), isEmpty);
    });

    test('skips trailing skippable frame after regular frame', () async {
      final payload = Uint8List.fromList('Payload before skip'.codeUnits);
      final regular = lz4FrameEncode(payload);

      final skippable = BytesBuilder(copy: false);
      skippable.add(_u32le(0x184D2A58));
      skippable.add(_u32le(8));
      skippable.add(Uint8List(8));
      final skippableBytes = skippable.takeBytes();

      final combined = Uint8List(regular.length + skippableBytes.length);
      combined.setRange(0, regular.length, regular);
      combined.setRange(regular.length, combined.length, skippableBytes);

      final outChunks = await Stream<List<int>>.fromIterable(
        _chunk(combined, [2, 1, 4]),
      ).transform(lz4FrameDecoder()).toList();

      expect(_concat(outChunks), equals(payload));
    });

    test('skips consecutive skippable frames in 1-byte chunks', () async {
      final payload = Uint8List.fromList('Interleaved content'.codeUnits);
      final regular = lz4FrameEncode(payload);

      final b = BytesBuilder(copy: false);
      // Skippable 1
      b.add(_u32le(0x184D2A51));
      b.add(_u32le(3));
      b.add(Uint8List.fromList([1, 2, 3]));
      // Skippable 2 (size 0)
      b.add(_u32le(0x184D2A52));
      b.add(_u32le(0));
      // Regular
      b.add(regular);
      // Skippable 3
      b.add(_u32le(0x184D2A5F));
      b.add(_u32le(2));
      b.add(Uint8List.fromList([4, 5]));

      final allBytes = b.takeBytes();
      final outChunks = await Stream<List<int>>.fromIterable(
        _chunk(allBytes, [1]),
      ).transform(lz4FrameDecoder()).toList();

      expect(_concat(outChunks), equals(payload));
    });

    test('rejects skippable frame with size > 0x7FFFFFFF (2GB limit)',
        () async {
      final b = BytesBuilder(copy: false);
      b.add(_u32le(0x184D2A50));
      b.add(_u32le(0x80000000)); // 2GB + 1 / exceeds 0x7FFFFFFF

      final future = Stream<List<int>>.fromIterable([b.takeBytes()])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Skippable frame size too large',
          ),
        ),
      );
    });
  });

  group('LZ4 Stream Decoder - Legacy Frames', () {
    test('decodes full 8MB legacy block alone at EOF (line 347)', () async {
      const legacyBlockMaxSize = 8 * 1024 * 1024;
      final raw = Uint8List(legacyBlockMaxSize);
      raw.fillRange(0, raw.length, 0x42);
      final compressed = lz4Compress(raw);
      final legacyFrame = _buildLegacyFrame([compressed]);

      final outChunks = await Stream<List<int>>.fromIterable([legacyFrame])
          .transform(lz4FrameDecoder())
          .toList();

      final out = _concat(outChunks);
      expect(out.length, equals(legacyBlockMaxSize));
      expect(out, equals(raw));
    });

    test('decodes full 8MB legacy block followed by standard frame (line 355)',
        () async {
      const legacyBlockMaxSize = 8 * 1024 * 1024;
      final legacyRaw = Uint8List(legacyBlockMaxSize);
      legacyRaw.fillRange(0, legacyRaw.length, 0x43);
      final compressed = lz4Compress(legacyRaw);
      final legacyFrame = _buildLegacyFrame([compressed]);

      final standardRaw =
          Uint8List.fromList('Standard frame following legacy'.codeUnits);
      final standardFrame = lz4FrameEncode(standardRaw);

      final combined = Uint8List(legacyFrame.length + standardFrame.length);
      combined.setRange(0, legacyFrame.length, legacyFrame);
      combined.setRange(legacyFrame.length, combined.length, standardFrame);

      final outChunks = await Stream<List<int>>.fromIterable(
        _chunk(combined, [64 * 1024, 128 * 1024]),
      ).transform(lz4FrameDecoder()).toList();

      final out = _concat(outChunks);
      expect(out.length, equals(legacyBlockMaxSize + standardRaw.length));
      expect(
          Uint8List.sublistView(out, 0, legacyBlockMaxSize), equals(legacyRaw));
      expect(
          Uint8List.sublistView(out, legacyBlockMaxSize), equals(standardRaw));
    });

    test('decodes full 8MB legacy block followed by skippable frame (line 355)',
        () async {
      const legacyBlockMaxSize = 8 * 1024 * 1024;
      final legacyRaw = Uint8List(legacyBlockMaxSize);
      legacyRaw.fillRange(0, legacyRaw.length, 0x44);
      final compressed = lz4Compress(legacyRaw);
      final legacyFrame = _buildLegacyFrame([compressed]);

      final skippable = BytesBuilder(copy: false);
      skippable.add(_u32le(0x184D2A52));
      skippable.add(_u32le(4));
      skippable.add(Uint8List.fromList([1, 2, 3, 4]));
      final skippableBytes = skippable.takeBytes();

      final standardRaw = Uint8List.fromList('After skippable'.codeUnits);
      final standardFrame = lz4FrameEncode(standardRaw);

      final b = BytesBuilder(copy: false);
      b.add(legacyFrame);
      b.add(skippableBytes);
      b.add(standardFrame);
      final combined = b.takeBytes();

      final outChunks = await Stream<List<int>>.fromIterable([combined])
          .transform(lz4FrameDecoder())
          .toList();

      final out = _concat(outChunks);
      expect(out.length, equals(legacyBlockMaxSize + standardRaw.length));
      expect(
          Uint8List.sublistView(out, 0, legacyBlockMaxSize), equals(legacyRaw));
      expect(
          Uint8List.sublistView(out, legacyBlockMaxSize), equals(standardRaw));
    });

    test('decodes partial legacy block (<8MB) followed by standard frame',
        () async {
      final legacyRaw = Uint8List.fromList('Short legacy payload'.codeUnits);
      final legacyFrame = _buildLegacyFrame([lz4Compress(legacyRaw)]);

      final standardRaw =
          Uint8List.fromList('Standard frame following'.codeUnits);
      final standardFrame = lz4FrameEncode(standardRaw);

      final combined = Uint8List(legacyFrame.length + standardFrame.length);
      combined.setRange(0, legacyFrame.length, legacyFrame);
      combined.setRange(legacyFrame.length, combined.length, standardFrame);

      final outChunks = await Stream<List<int>>.fromIterable(
        _chunk(combined, [1, 2, 5]),
      ).transform(lz4FrameDecoder()).toList();

      final out = _concat(outChunks);
      expect(out, equals(Uint8List.fromList([...legacyRaw, ...standardRaw])));
    });

    test('rejects legacy partial block followed by non-boundary data',
        () async {
      final legacyRaw = Uint8List.fromList('Partial legacy'.codeUnits);
      final legacyFrame = _buildLegacyFrame([lz4Compress(legacyRaw)]);

      // Append invalid 4 bytes (not a frame magic, not a skippable frame)
      final corrupt =
          Uint8List.fromList([...legacyFrame, 0x11, 0x22, 0x33, 0x44]);

      final future = Stream<List<int>>.fromIterable([corrupt])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Legacy block is not full',
          ),
        ),
      );
    });

    test('rejects legacy frame with cSize == 0', () async {
      final b = BytesBuilder(copy: false);
      b.add(_u32le(0x184C2102)); // Legacy magic
      b.add(_u32le(0)); // cSize = 0

      final future = Stream<List<int>>.fromIterable([b.takeBytes()])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Invalid legacy block size',
          ),
        ),
      );
    });

    test('rejects legacy frame with cSize > 8MB', () async {
      final b = BytesBuilder(copy: false);
      b.add(_u32le(0x184C2102));
      b.add(_u32le(8 * 1024 * 1024 + 1));

      final future = Stream<List<int>>.fromIterable([b.takeBytes()])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Legacy block size exceeds maximum',
          ),
        ),
      );
    });

    test('enforces maxOutputBytes on legacy frame decode', () async {
      final raw = Uint8List(1024);
      final legacyFrame = _buildLegacyFrame([lz4Compress(raw)]);

      final future = Stream<List<int>>.fromIterable([legacyFrame])
          .transform(lz4FrameDecoder(maxOutputBytes: 500))
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4OutputLimitException>().having(
            (e) => e.message,
            'message',
            'Output limit exceeded',
          ),
        ),
      );
    });
  });

  group('LZ4 Stream Decoder - 64-bit Content Size and Limits', () {
    test('rejects 64-bit content size resulting in negative val (overflow)',
        () async {
      // high = 0x80000000 causes (high * 4294967296) + low to overflow to negative in 64-bit int
      final frame = _buildCustomFrame(
        flg: 0x68, // version=1, blockIndependence=1, contentSize=1
        contentSizeLow: 0,
        contentSizeHigh: 0x80000000,
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            '64-bit content size overflow/Web precision loss',
          ),
        ),
      );
    });

    test('evaluates JS precision check branch when high > 0x1FFFFF', () async {
      // high = 0x200001, low = 0: Exercises line 219 (high > 0x1FFFFF)
      final frame = _buildCustomFrame(
        flg: 0x68,
        contentSizeLow: 0,
        contentSizeHigh: 0x200001,
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder(maxOutputBytes: 100))
          .toList();

      if (identical(0, 0.0)) {
        await expectLater(
          future,
          throwsA(
            isA<Lz4FormatException>().having(
              (e) => e.message,
              'message',
              '64-bit content size overflow/Web precision loss',
            ),
          ),
        );
      } else {
        await expectLater(
          future,
          throwsA(
            isA<Lz4OutputLimitException>().having(
              (e) => e.message,
              'message',
              'Content size exceeds output limit',
            ),
          ),
        );
      }
    });

    test('rejects frame descriptor if content size exceeds maxOutputBytes',
        () async {
      final frame = _buildCustomFrame(
        flg: 0x68,
        contentSizeLow: 2000,
        contentSizeHigh: 0,
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder(maxOutputBytes: 1000))
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4OutputLimitException>().having(
            (e) => e.message,
            'message',
            'Content size exceeds output limit',
          ),
        ),
      );
    });

    test('valid 64-bit content size decodes correctly', () async {
      final src = Uint8List.fromList('Content size in header'.codeUnits);
      final compressed = lz4Compress(src);
      final frame = _buildCustomFrame(
        flg: 0x68,
        contentSizeLow: src.length,
        contentSizeHigh: 0,
        blocks: [compressed],
        endMark: true,
      );

      final outChunks = await Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      expect(_concat(outChunks), equals(src));
    });
  });

  group('LZ4 Stream Decoder - Header Validation & Checksum', () {
    test('rejects frame with header checksum mismatch (line 252)', () async {
      final frame = _buildCustomFrame(
        flg: 0x60,
        bd: 0x40,
        customHc: 0x55, // corrupt HC
        endMark: true,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Header checksum mismatch',
          ),
        ),
      );
    });

    test(
        'rejects frame when dictId present but no dictionary resolver provided (line 258)',
        () async {
      final frame = _buildCustomFrame(
        flg: 0x61, // dictId flag set
        dictId: 0x12345678,
        endMark: true,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder(dictionaryResolver: null))
          .toList();

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

    test('rejects frame when dictionary resolver returns null (line 263)',
        () async {
      const dictId = 0x12345678;
      final frame = _buildCustomFrame(
        flg: 0x61,
        dictId: dictId,
        endMark: true,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder(dictionaryResolver: (id) => null))
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4Exception>().having(
            (e) => e.message,
            'message',
            'Dictionary not found for ID: $dictId',
          ),
        ),
      );
    });

    test('rejects frame with reserved FLG bit set', () async {
      final frame = _buildCustomFrame(
        flg: 0x62, // bit 1 set
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Reserved FLG bit is set',
          ),
        ),
      );
    });

    test('rejects frame with reserved BD bits set', () async {
      final frame = _buildCustomFrame(
        flg: 0x60,
        bd: 0x41, // lower reserved bits set
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Reserved BD bits are set',
          ),
        ),
      );
    });

    test('rejects frame with invalid BD block size index', () async {
      final frame = _buildCustomFrame(
        flg: 0x60,
        bd: 0x30, // 3 is not a valid block size index (4..7)
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Invalid block maximum size',
          ),
        ),
      );
    });

    test('rejects frame with unsupported version', () async {
      final frame = _buildCustomFrame(
        flg: 0x80, // version 2
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4UnsupportedFeatureException>().having(
            (e) => e.message,
            'message',
            'Unsupported LZ4 frame version',
          ),
        ),
      );
    });

    test('rejects invalid LZ4 frame magic number', () async {
      final frame = _buildCustomFrame(
        magic: 0x184D2205, // invalid magic
        endMark: false,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Invalid LZ4 frame magic number',
          ),
        ),
      );
    });
  });

  group('LZ4 Stream Decoder - Block & Content Checksums and Sizing', () {
    test('rejects block checksum mismatch in stream (line 309)', () async {
      final src = Uint8List.fromList('Test block checksum'.codeUnits);
      final compressed = lz4Compress(src);

      final frame = _buildCustomFrame(
        flg: 0x70, // blockIndependence=1, blockChecksum=1
        blocks: [compressed],
        blockChecksum: true,
        customBlockChecksum: 0xDEADBEEF, // corrupt block checksum
        endMark: true,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Block checksum mismatch',
          ),
        ),
      );
    });

    test('rejects content checksum mismatch in stream (line 327)', () async {
      final src = Uint8List.fromList('Test content checksum'.codeUnits);
      final compressed = lz4Compress(src);

      final frame = _buildCustomFrame(
        flg: 0x64, // blockIndependence=1, contentChecksum=1
        blocks: [compressed],
        endMark: true,
        contentChecksum: 0xCAFEBABE, // corrupt content checksum
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Content checksum mismatch',
          ),
        ),
      );
    });

    test('rejects content size mismatch in stream (line 572/613)', () async {
      final src = Uint8List.fromList('Hello'.codeUnits);
      final compressed = lz4Compress(src);

      // Declares 100 bytes in header, but only decompresses 5 bytes
      final frame = _buildCustomFrame(
        flg: 0x68, // contentSizeFlag=1
        contentSizeLow: 100,
        contentSizeHigh: 0,
        blocks: [compressed],
        endMark: true,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Content size mismatch',
          ),
        ),
      );
    });

    test('rejects block size exceeding block maximum size', () async {
      final oversized = Uint8List(64 * 1024 + 1);
      final b = BytesBuilder(copy: false);
      // Header with 64KB BD (0x40)
      b.add(_buildCustomFrame(
        flg: 0x60,
        bd: 0x40, // 64KB max
        endMark: false,
      ));
      // Write a block with size > 64KB
      b.add(_u32le(oversized.length));
      b.add(oversized);

      final future = Stream<List<int>>.fromIterable([b.takeBytes()])
          .transform(lz4FrameDecoder())
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            'Block size exceeds maximum',
          ),
        ),
      );
    });

    test('enforces maxOutputBytes exceeded mid-stream (line 527/567)',
        () async {
      final src =
          Uint8List.fromList('01234567890123456789'.codeUnits); // 20 bytes
      final compressed = lz4Compress(src);

      // Frame WITHOUT contentSize in header, so header check does not trigger
      final frame = _buildCustomFrame(
        flg: 0x60, // no contentSize flag
        blocks: [compressed],
        endMark: true,
      );

      final future = Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder(maxOutputBytes: 15))
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4OutputLimitException>().having(
            (e) => e.message,
            'message',
            'Output limit exceeded',
          ),
        ),
      );
    });

    test('decodes uncompressed block in stream', () async {
      final src = Uint8List.fromList('Uncompressed raw block bytes'.codeUnits);

      final frame = _buildCustomFrame(
        flg: 0x60,
        blocks: [src],
        uncompressedBlocks: true,
        endMark: true,
      );

      final outChunks = await Stream<List<int>>.fromIterable(
        _chunk(frame, [1, 4, 2]),
      ).transform(lz4FrameDecoder()).toList();

      expect(_concat(outChunks), equals(src));
    });
  });

  group('LZ4 Stream Decoder - Linked Blocks & History Roll-over', () {
    test(
        'decodes linked blocks (blockIndependence: false) with history window > 64KB roll-over',
        () async {
      // Create test data that spans multiple blocks and exceeds the 64KB history window:
      // Block 1: 40KB
      // Block 2: 40KB (total 80KB > 64KB, triggers history roll-over drop & keep)
      // Block 3: 40KB (triggers history roll-over again)
      // Block 4: 10KB (final block)
      final part1 = Uint8List(40 * 1024);
      for (var i = 0; i < part1.length; i++) {
        part1[i] = (i * 17) & 0xff;
      }
      final part2 = Uint8List(40 * 1024);
      for (var i = 0; i < part2.length; i++) {
        part2[i] = ((i + 100) * 19) & 0xff;
      }
      final part3 = Uint8List(40 * 1024);
      for (var i = 0; i < part3.length; i++) {
        part3[i] = ((i + 200) * 23) & 0xff;
      }
      final part4 = Uint8List(10 * 1024);
      for (var i = 0; i < part4.length; i++) {
        part4[i] = ((i + 300) * 29) & 0xff;
      }

      final totalSrc =
          Uint8List(part1.length + part2.length + part3.length + part4.length);
      var pos = 0;
      totalSrc.setRange(pos, pos + part1.length, part1);
      pos += part1.length;
      totalSrc.setRange(pos, pos + part2.length, part2);
      pos += part2.length;
      totalSrc.setRange(pos, pos + part3.length, part3);
      pos += part3.length;
      totalSrc.setRange(pos, pos + part4.length, part4);

      final encodedChunks = await Stream<List<int>>.fromIterable([totalSrc])
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
                blockChecksum: true,
                contentChecksum: true,
              ),
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);

      final decodedChunks = await Stream<List<int>>.fromIterable(
        _chunk(encoded, [512, 1024, 2048, 777]),
      ).transform(lz4FrameDecoder()).toList();

      final decoded = _concat(decodedChunks);
      expect(decoded, equals(totalSrc));
    });

    test(
        'decodes linked blocks with full 64KB block history update (bytes.length >= window)',
        () async {
      const blockSize = 64 * 1024;
      final src = Uint8List(blockSize * 3);
      for (var i = 0; i < src.length; i++) {
        src[i] = (i * 31) & 0xff;
      }

      final encodedChunks = await Stream<List<int>>.fromIterable([src])
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
              ),
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);

      final decodedChunks = await Stream<List<int>>.fromIterable(
        _chunk(encoded, [4096, 8192]),
      ).transform(lz4FrameDecoder()).toList();

      expect(_concat(decodedChunks), equals(src));
    });

    test('decodes independent blocks with dictionary resolver', () async {
      final dict =
          Uint8List.fromList(List.generate(1024, (i) => (i * 7) & 0xff));
      const dictId = 0x55AA3311;

      final src = Uint8List.fromList(
        [...dict.sublist(100, 300), ...'Repeated dictionary pattern'.codeUnits],
      );

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          dictId: dictId,
          blockIndependence: true,
        ),
        dictionary: dict,
      );

      final decodedChunks = await Stream<List<int>>.fromIterable([encoded])
          .transform(
            lz4FrameDecoder(
              dictionaryResolver: (id) => id == dictId ? dict : null,
            ),
          )
          .toList();

      expect(_concat(decodedChunks), equals(src));
    });

    test(
        'decodes dependent blocks with dictionary resolver (historyLen < window && dict != null)',
        () async {
      final dict =
          Uint8List.fromList(List.generate(2048, (i) => (i * 13) & 0xff));
      const dictId = 0x77889900;

      final part1 =
          Uint8List.fromList([...dict.sublist(50, 250), ...'Part 1'.codeUnits]);
      final part2 = Uint8List.fromList(
          [...part1, ...'Part 2 referencing part 1'.codeUnits]);
      final src = Uint8List.fromList([...part1, ...part2]);

      final encodedChunks = await Stream<List<int>>.fromIterable([src])
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
                dictId: dictId,
              ),
              dictionary: dict,
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);

      final decodedChunks = await Stream<List<int>>.fromIterable([encoded])
          .transform(
            lz4FrameDecoder(
              dictionaryResolver: (id) => id == dictId ? dict : null,
            ),
          )
          .toList();

      expect(_concat(decodedChunks), equals(src));
    });
  });

  group('LZ4 Stream Encoder - Empty Input and Dictionary Options', () {
    test(
        'encodes empty input stream with dependent blocks and dictionary > 64KB (lines 68, 69)',
        () async {
      // dictionary > 64KB (historyWindow = 64 * 1024)
      final largeDict = Uint8List(70 * 1024);
      for (var i = 0; i < largeDict.length; i++) {
        largeDict[i] = (i * 3) & 0xff;
      }

      final encodedChunks = await const Stream<List<int>>.empty()
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockIndependence: false,
              ),
              dictionary: largeDict,
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(encoded);
      expect(decoded, isEmpty);
    });

    test(
        'encodes empty input stream with dependent blocks and dictionary <= 64KB',
        () async {
      final smallDict = Uint8List(1024);
      final encodedChunks = await const Stream<List<int>>.empty()
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockIndependence: false,
              ),
              dictionary: smallDict,
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(encoded);
      expect(decoded, isEmpty);
    });

    test('skips empty chunks in input stream', () async {
      final src = Uint8List.fromList('Data between empty chunks'.codeUnits);
      final input = Stream<List<int>>.fromIterable([
        Uint8List(0),
        src.sublist(0, 5),
        Uint8List(0),
        src.sublist(5),
        Uint8List(0),
      ]);

      final encodedChunks = await input.transform(lz4FrameEncoder()).toList();

      final decoded = lz4FrameDecode(_concat(encodedChunks));
      expect(decoded, equals(src));
    });

    test('encodes empty stream with contentChecksum', () async {
      final encodedChunks = await const Stream<List<int>>.empty()
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(contentChecksum: true),
            ),
          )
          .toList();

      final decoded = lz4FrameDecode(_concat(encodedChunks));
      expect(decoded, isEmpty);
    });
  });

  group('LZ4 Stream Encoder - Linked Blocks with Block Checksums', () {
    test(
        'encodes linked blocks with block checksums when compressed (lines 129-131)',
        () async {
      // Highly compressible repeated data so useCompressed is true
      const blockSize = 64 * 1024;
      final src = Uint8List(blockSize * 2);
      for (var i = 0; i < src.length; i++) {
        src[i] = ((i % 128) + 32) & 0xff;
      }

      final encodedChunks = await Stream<List<int>>.fromIterable([src])
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
                blockChecksum: true,
                contentChecksum: true,
              ),
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));

      // Also decode via stream decoder to verify stream decoder blockChecksum handling
      final streamDecodedChunks = await Stream<List<int>>.fromIterable(
        _chunk(encoded, [1024, 2048]),
      ).transform(lz4FrameDecoder()).toList();

      expect(_concat(streamDecodedChunks), equals(src));
    });

    test('encodes linked blocks with block checksums when uncompressed',
        () async {
      // Incompressible pseudo-random data to force useCompressed = false
      final randomData = Uint8List(100);
      var seed = 12345;
      for (var i = 0; i < randomData.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        randomData[i] = (seed >> 16) & 0xff;
      }

      final encodedChunks = await Stream<List<int>>.fromIterable([randomData])
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
                blockChecksum: true,
              ),
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(randomData));
    });

    test('encodes with dictionary > 64KB on non-empty stream', () async {
      final largeDict = Uint8List(70 * 1024);
      for (var i = 0; i < largeDict.length; i++) {
        largeDict[i] = (i * 5) & 0xff;
      }

      final src = Uint8List.fromList([
        ...largeDict.sublist(largeDict.length - 500),
        ...'Payload with dict match'.codeUnits,
      ]);

      const dictId = 0x99887766;
      final encodedChunks = await Stream<List<int>>.fromIterable([src])
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
                dictId: dictId,
              ),
              dictionary: largeDict,
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(
        encoded,
        dictionaryResolver: (id) => id == dictId ? largeDict : null,
      );
      expect(decoded, equals(src));
    });
  });

  group('LZ4 Stream Encoder - Small Chunks Across Block Boundaries', () {
    test('encodes stream of tiny chunks crossing 64KB block boundaries',
        () async {
      const blockSize = 64 * 1024;
      // 150KB total length across two 64KB blocks and one 22KB tail block
      final totalLen = blockSize * 2 + 22 * 1024;
      final src = Uint8List(totalLen);
      for (var i = 0; i < totalLen; i++) {
        src[i] = (i * 37) & 0xff;
      }

      // Feed in varied small chunk sizes: 1, 7, 13, 29 bytes
      final smallChunks = _chunk(src, [1, 7, 13, 29]);

      final pool = SimpleLz4BufferPool();
      final encodedChunks = await Stream<List<int>>.fromIterable(smallChunks)
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: false,
                blockChecksum: true,
                contentChecksum: true,
                bufferPool: pool,
              ),
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));
    });

    test('encodes small chunks with independent blocks and contentSize',
        () async {
      final src =
          Uint8List.fromList(List.generate(70 * 1024, (i) => (i * 41) & 0xff));

      final encodedChunks = await Stream<List<int>>.fromIterable(
        _chunk(src, [3, 11, 19]),
      )
          .transform(
            lz4FrameEncoderWithOptions(
              options: Lz4FrameOptions(
                blockSize: Lz4FrameBlockSize.k64KB,
                blockIndependence: true,
                contentSize: src.length,
                contentChecksum: true,
              ),
            ),
          )
          .toList();

      final encoded = _concat(encodedChunks);
      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));
    });

    test(
        'encoder rejects input stream longer than declared contentSize (line 156)',
        () async {
      final src = Uint8List.fromList('0123456789Extra'.codeUnits);
      final options = Lz4FrameOptions(contentSize: 10);

      final future = Stream<List<int>>.fromIterable([src])
          .transform(lz4FrameEncoderWithOptions(options: options))
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'contentSize does not match stream length',
          ),
        ),
      );
    });

    test(
        'encoder rejects input stream shorter than declared contentSize at stream end (line 215)',
        () async {
      final src = Uint8List.fromList('Short'.codeUnits); // 5 bytes
      final options = Lz4FrameOptions(contentSize: 10);

      final future = Stream<List<int>>.fromIterable([src])
          .transform(lz4FrameEncoderWithOptions(options: options))
          .toList();

      await expectLater(
        future,
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'contentSize does not match stream length',
          ),
        ),
      );
    });
  });

  group('LZ4 Stream Decoder - Additional Edge Coverage', () {
    test(
        'decodes partial legacy block (<8MB) alone at EOF (lines 422, 423, 445, 446)',
        () async {
      final legacyRaw =
          Uint8List.fromList('Single partial legacy block at EOF'.codeUnits);
      final legacyFrame = _buildLegacyFrame([lz4Compress(legacyRaw)]);

      final outChunks = await Stream<List<int>>.fromIterable([legacyFrame])
          .transform(lz4FrameDecoder())
          .toList();

      final out = _concat(outChunks);
      expect(out, equals(legacyRaw));
    });

    test(
        'decodes dependent blocks with dictionary when historyLen > 0 (line 522)',
        () async {
      final dict =
          Uint8List.fromList(List.generate(1024, (i) => (i * 11) & 0xff));
      const dictId = 0x11223344;

      final b1 = Uint8List.fromList('Block1'.codeUnits);
      final b2 = Uint8List.fromList('Block2'.codeUnits);
      final compressedB2 = lz4Compress(b2);

      // Block 1 is uncompressed (so historyLen becomes b1.length > 0).
      // Block 2 is compressed (triggers decompress with dict and historyLen > 0).
      final frameWriter = ByteWriter(initialCapacity: 128);
      // Header: magic, FLG (blockIndependence: false, dictId: true) = 0x41, BD = 0x40, dictId
      frameWriter.writeUint32LE(0x184D2204);
      final desc = ByteWriter(initialCapacity: 16);
      desc.writeUint8(0x41);
      desc.writeUint8(0x40);
      desc.writeUint32LE(dictId);
      final descBytes = desc.toBytes();
      frameWriter.writeBytes(descBytes);
      final hc = (xxh32(descBytes, seed: 0) >> 8) & 0xff;
      frameWriter.writeUint8(hc);

      // Block 1 (uncompressed)
      frameWriter.writeUint32LE(0x80000000 | b1.length);
      frameWriter.writeBytes(b1);

      // Block 2 (compressed)
      frameWriter.writeUint32LE(compressedB2.length);
      frameWriter.writeBytes(compressedB2);

      // End mark
      frameWriter.writeUint32LE(0);

      final frame = frameWriter.toBytes();

      final decodedChunks = await Stream<List<int>>.fromIterable([frame])
          .transform(
            lz4FrameDecoder(
              dictionaryResolver: (id) => id == dictId ? dict : null,
            ),
          )
          .toList();

      expect(
          _concat(decodedChunks), equals(Uint8List.fromList([...b1, ...b2])));
    });

    test('supports BD block maximum sizes: 256KB, 1MB, 4MB (lines 655, 657)',
        () async {
      final src = Uint8List.fromList('Block size BD test'.codeUnits);
      final compressed = lz4Compress(src);

      // BD = 0x50 (256KB, index 5)
      final frame256k = _buildCustomFrame(
        flg: 0x60,
        bd: 0x50,
        blocks: [compressed],
        endMark: true,
      );
      final out256k = await Stream<List<int>>.fromIterable([frame256k])
          .transform(lz4FrameDecoder())
          .toList();
      expect(_concat(out256k), equals(src));

      // BD = 0x60 (1MB, index 6)
      final frame1m = _buildCustomFrame(
        flg: 0x60,
        bd: 0x60,
        blocks: [compressed],
        endMark: true,
      );
      final out1m = await Stream<List<int>>.fromIterable([frame1m])
          .transform(lz4FrameDecoder())
          .toList();
      expect(_concat(out1m), equals(src));

      // BD = 0x70 (4MB, index 7)
      final frame4m = _buildCustomFrame(
        flg: 0x60,
        bd: 0x70,
        blocks: [compressed],
        endMark: true,
      );
      final out4m = await Stream<List<int>>.fromIterable([frame4m])
          .transform(lz4FrameDecoder())
          .toList();
      expect(_concat(out4m), equals(src));
    });

    test('decodes empty uncompressed block (line 564)', () async {
      final frame = _buildCustomFrame(
        flg: 0x60,
        blocks: [Uint8List(0)],
        uncompressedBlocks: true,
        endMark: true,
      );

      final outChunks = await Stream<List<int>>.fromIterable([frame])
          .transform(lz4FrameDecoder())
          .toList();

      expect(_concat(outChunks), isEmpty);
    });

    test('shrinks buffer on reset with remaining data (line 767)', () async {
      // Incompressible random data to ensure frame1 > 1024 bytes
      final rand = Uint8List(2000);
      var seed = 42;
      for (var i = 0; i < rand.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        rand[i] = (seed >> 16) & 0xff;
      }
      final frame1 = lz4FrameEncode(rand);

      final src2 = Uint8List.fromList('Frame2'.codeUnits);
      final frame2 = lz4FrameEncode(src2);

      // Concatenate into single buffer > 1024 bytes
      final combined = Uint8List(frame1.length + frame2.length);
      combined.setRange(0, frame1.length, frame1);
      combined.setRange(frame1.length, combined.length, frame2);

      final outChunks = await Stream<List<int>>.fromIterable([combined])
          .transform(lz4FrameDecoder())
          .toList();

      final out = _concat(outChunks);
      expect(out.length, equals(rand.length + src2.length));
    });
  });
}
