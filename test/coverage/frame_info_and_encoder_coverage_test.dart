import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/block/lz4_block_encoder.dart';
import 'package:dart_lz4/src/frame/lz4_frame_decoder.dart';
import 'package:dart_lz4/src/frame/lz4_frame_encoder.dart';
import 'package:dart_lz4/src/internal/byte_writer.dart';
import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

/// Helper to build a standard LZ4 frame header with custom parameters.
Uint8List createFrameHeader({
  int magic = 0x184D2204,
  int version = 1,
  bool blockIndependence = true,
  bool blockChecksum = false,
  bool contentSize = false,
  bool contentChecksum = false,
  int reservedFlg = 0,
  bool dictId = false,
  int blockMaxSizeId = 4, // 64KB
  int reservedBd = 0,
  int? contentSizeValue,
  int? dictIdValue,
  bool corruptHc = false,
}) {
  final writer = ByteWriter();
  writer.writeUint32LE(magic);

  final flg = ((version & 0x03) << 6) |
      ((blockIndependence ? 1 : 0) << 5) |
      ((blockChecksum ? 1 : 0) << 4) |
      ((contentSize ? 1 : 0) << 3) |
      ((contentChecksum ? 1 : 0) << 2) |
      ((reservedFlg & 0x01) << 1) |
      ((dictId ? 1 : 0) << 0);
  writer.writeUint8(flg);

  final bd = ((blockMaxSizeId & 0x07) << 4) | (reservedBd & 0x8F);
  writer.writeUint8(bd);

  if (contentSize) {
    final size = contentSizeValue ?? 0;
    writer.writeUint32LE(size & 0xFFFFFFFF);
    writer.writeUint32LE((size ~/ 4294967296) & 0xFFFFFFFF);
  }

  if (dictId) {
    writer.writeUint32LE(dictIdValue ?? 0);
  }

  final descriptor =
      Uint8List.sublistView(writer.bytesView(), 4, writer.length);
  var hc = (xxh32(descriptor, seed: 0) >> 8) & 0xFF;
  if (corruptHc) {
    hc ^= 0xFF;
  }
  writer.writeUint8(hc);

  return writer.toBytes();
}

/// Helper to build a complete LZ4 frame.
Uint8List buildFrame({
  required Uint8List header,
  List<Uint8List> blocks = const [],
  List<bool> isUncompressed = const [],
  bool blockChecksum = false,
  bool writeEndMark = true,
  bool contentChecksum = false,
  int? contentChecksumValue,
  bool corruptContentChecksum = false,
}) {
  final writer = ByteWriter();
  writer.writeBytes(header);

  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    final uncompressed = i < isUncompressed.length && isUncompressed[i];
    final rawSize = uncompressed ? (0x80000000 | block.length) : block.length;
    writer.writeUint32LE(rawSize);
    writer.writeBytes(block);
    if (blockChecksum) {
      writer.writeUint32LE(xxh32(block, seed: 0));
    }
  }

  if (writeEndMark) {
    writer.writeUint32LE(0); // End mark
  }

  if (contentChecksum) {
    var cs = contentChecksumValue ?? 0;
    if (corruptContentChecksum) {
      cs ^= 0xFFFFFFFF;
    }
    writer.writeUint32LE(cs);
  }

  return writer.toBytes();
}

void main() {
  group('1. lz4_frame_info coverage', () {
    test('malformed magic number: throws on < 4 bytes', () {
      expect(
        () => lz4FrameInfo(Uint8List(0)),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );
      expect(
        () => lz4FrameInfo(Uint8List(1)),
        throwsA(isA<Lz4FormatException>()),
      );
      expect(
        () => lz4FrameInfo(Uint8List(2)),
        throwsA(isA<Lz4FormatException>()),
      );
      expect(
        () => lz4FrameInfo(Uint8List(3)),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('malformed magic number: throws on invalid 4-byte magic', () {
      final invalidMagics = [
        Uint8List.fromList([0x00, 0x00, 0x00, 0x00]),
        Uint8List.fromList([0x04, 0x22, 0x4D, 0x19]), // standard magic + 1
        Uint8List.fromList([0x50, 0x2A, 0x4D, 0x19]), // skippable mask mismatch
        Uint8List.fromList([0x02, 0x21, 0x4C, 0x19]), // legacy magic mismatch
        Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]),
      ];

      for (final magic in invalidMagics) {
        expect(
          () => lz4FrameInfo(magic),
          throwsA(isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Invalid LZ4 frame magic number'),
          )),
        );
      }
    });

    test('truncated frame header: descriptor too short (< 3 bytes)', () {
      final magicOnly = Uint8List.fromList([0x04, 0x22, 0x4D, 0x18]);
      expect(
        () => lz4FrameInfo(magicOnly),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      final magicPlusOne = Uint8List.fromList([0x04, 0x22, 0x4D, 0x18, 0x60]);
      expect(
        () => lz4FrameInfo(magicPlusOne),
        throwsA(isA<Lz4FormatException>()),
      );

      final magicPlusTwo =
          Uint8List.fromList([0x04, 0x22, 0x4D, 0x18, 0x60, 0x40]);
      expect(
        () => lz4FrameInfo(magicPlusTwo),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('truncated frame header: content size flag set but < 8 bytes size',
        () {
      final header =
          createFrameHeader(contentSize: true, contentSizeValue: 100);
      // Remove 5 bytes from end (content size needs 8 bytes + 1 byte HC)
      final truncated = Uint8List.sublistView(header, 0, header.length - 5);
      expect(
        () => lz4FrameInfo(truncated),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );
    });

    test('truncated frame header: dictId flag set but < 4 bytes dictId', () {
      final header = createFrameHeader(dictId: true, dictIdValue: 0x12345678);
      // Remove 3 bytes from end
      final truncated = Uint8List.sublistView(header, 0, header.length - 3);
      expect(
        () => lz4FrameInfo(truncated),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );
    });

    test('unsupported frame version: versions 0, 2, 3 throw exception', () {
      for (final version in [0, 2, 3]) {
        final header = createFrameHeader(version: version);
        expect(
          () => lz4FrameInfo(header),
          throwsA(isA<Lz4UnsupportedFeatureException>().having(
            (e) => e.message,
            'message',
            contains('Unsupported LZ4 frame version'),
          )),
        );
      }
    });

    test('reserved FLG bits set: bit 1 set throws Lz4FormatException', () {
      final header = createFrameHeader(reservedFlg: 1);
      expect(
        () => lz4FrameInfo(header),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Reserved FLG bit is set'),
        )),
      );
    });

    test('reserved BD bits set: bit 7 or bits 0-3 set throw Lz4FormatException',
        () {
      final reservedValues = [0x80, 0x01, 0x02, 0x04, 0x08, 0x0F, 0x8F];
      for (final reserved in reservedValues) {
        final header = createFrameHeader(reservedBd: reserved);
        expect(
          () => lz4FrameInfo(header),
          throwsA(isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Reserved BD bits are set'),
          )),
        );
      }
    });

    test(
        'header checksum mismatch in lz4FrameInfo throws Lz4CorruptDataException',
        () {
      final header = createFrameHeader(corruptHc: true);
      expect(
        () => lz4FrameInfo(header),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Header checksum mismatch'),
        )),
      );
    });

    test('block maximum size decoding: covers cases 4, 5, 6, 7 and invalid IDs',
        () {
      final validSizes = {
        4: 64 * 1024,
        5: 256 * 1024,
        6: 1024 * 1024,
        7: 4 * 1024 * 1024,
      };

      for (final entry in validSizes.entries) {
        final header = createFrameHeader(blockMaxSizeId: entry.key);
        final info = lz4FrameInfo(header);
        expect(info.blockMaxSize, entry.value);
      }

      // Invalid block maximum sizes (IDs 0, 1, 2, 3)
      for (final id in [0, 1, 2, 3]) {
        final header = createFrameHeader(blockMaxSizeId: id);
        expect(
          () => lz4FrameInfo(header),
          throwsA(isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Invalid block maximum size'),
          )),
        );
      }
    });

    test(
        'skippable frame info inspection: size bounds, headerSize, and toString',
        () {
      for (var i = 0; i <= 15; i++) {
        final data = Uint8List.fromList([1, 2, 3, 4, 5]);
        final skippable = lz4SkippableFrameEncode(data, index: i);
        final info = lz4FrameInfo(skippable);

        expect(info.isSkippable, isTrue);
        expect(info.isLegacy, isFalse);
        expect(info.skippableSize, 5);
        expect(info.headerSize, 8);
        expect(info.magic, 0x184D2A50 + i);
        expect(
          info.toString(),
          equals('Lz4FrameInfo(type: skippable, size: 5)'),
        );
      }

      // Skippable frame with truncated size (< 4 bytes for size)
      final truncatedSkippable =
          Uint8List.fromList([0x50, 0x2A, 0x4D, 0x18, 0x01, 0x02]);
      expect(
        () => lz4FrameInfo(truncatedSkippable),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // Skippable frame size > 0x7FFFFFFF (exceeds 2GB limit)
      final hugeSkippable = Uint8List.fromList([
        0x50, 0x2A, 0x4D, 0x18,
        0x00, 0x00, 0x00, 0x80, // 0x80000000
      ]);
      expect(
        () => lz4FrameInfo(hugeSkippable),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Skippable frame size too large'),
        )),
      );
    });

    test('legacy frame info inspection: properties and toString', () {
      final legacy = lz4LegacyFrameEncode(Uint8List.fromList([1, 2, 3, 4]));
      final info = lz4FrameInfo(legacy);

      expect(info.isLegacy, isTrue);
      expect(info.isSkippable, isFalse);
      expect(info.headerSize, 4);
      expect(info.magic, 0x184C2102);
      expect(info.toString(), equals('Lz4FrameInfo(type: legacy)'));
    });

    test('standard frame info toString covers all properties', () {
      final header = createFrameHeader(
        blockIndependence: false,
        blockChecksum: true,
        contentChecksum: true,
        contentSize: true,
        contentSizeValue: 123456,
        dictId: true,
        dictIdValue: 0x9ABCDEF0,
        blockMaxSizeId: 5, // 256KB
      );

      final info = lz4FrameInfo(header);
      expect(
        info.toString(),
        equals(
            'Lz4FrameInfo(type: standard, independent: false, blockChecksum: true, contentChecksum: true, contentSize: 123456, dictId: 2596069104, blockMaxSize: 262144)'),
      );
    });
  });

  group('2. lz4_frame_encoder coverage', () {
    test('linked blocks (blockIndependence: false) in multi-block sync encode',
        () {
      // 140 KiB input with 64 KiB blocks forces 3 blocks:
      // Block 0: 64 KiB (offset 0)
      // Block 1: 64 KiB (offset 64 KiB, hits offset >= historyWindow)
      // Block 2: 12 KiB (offset 128 KiB, hits offset >= historyWindow)
      final src = Uint8List(140 * 1024);
      for (var i = 0; i < src.length; i++) {
        src[i] = ((i % 251) ^ (i >> 3)) & 0xFF;
      }

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: false,
          contentChecksum: true,
        ),
      );

      final info = lz4FrameInfo(encoded);
      expect(info.blockIndependence, isFalse);
      expect(info.contentChecksum, isTrue);

      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));
    });

    test(
        'linked blocks (blockIndependence: false) with dictionary in multi-block sync encode',
        () {
      final dict =
          Uint8List.fromList(List.generate(1024, (i) => (i * 17) % 256));
      const dictId = 0x33445566;

      final src = Uint8List(130 * 1024);
      // Copy dict pattern into beginning of src to leverage dictionary
      src.setRange(0, dict.length, dict);
      for (var i = dict.length; i < src.length; i++) {
        src[i] = (i % 256);
      }

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockSize: Lz4FrameBlockSize.k64KB,
          blockIndependence: false,
          dictId: dictId,
          contentChecksum: true,
        ),
        dictionary: dict,
      );

      final info = lz4FrameInfo(encoded);
      expect(info.blockIndependence, isFalse);
      expect(info.dictId, dictId);

      final decoded = lz4FrameDecode(
        encoded,
        dictionaryResolver: (id) => id == dictId ? dict : null,
      );
      expect(decoded, equals(src));
    });

    test(
        'block checksums enabled (blockChecksum: true) with compressible payload',
        () {
      // Highly compressible data -> compressed block with block checksum
      final src = Uint8List(2048); // All zeros
      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockChecksum: true,
          contentChecksum: true,
        ),
      );

      final info = lz4FrameInfo(encoded);
      expect(info.blockChecksum, isTrue);

      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));
    });

    test(
        'block checksums enabled (blockChecksum: true) with uncompressed payload',
        () {
      // Incompressible random data -> uncompressed block fallback with block checksum
      final rng = Random(12345);
      final src =
          Uint8List.fromList(List.generate(64, (_) => rng.nextInt(256)));

      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          blockChecksum: true,
        ),
      );

      final info = lz4FrameInfo(encoded);
      expect(info.blockChecksum, isTrue);

      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));
    });

    test('64-bit content size encoding in sync frame encoder', () {
      final src = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          contentSize: src.length,
          contentChecksum: true,
        ),
      );

      final info = lz4FrameInfo(encoded);
      expect(info.contentSize, 8);

      final decoded = lz4FrameDecode(encoded);
      expect(decoded, equals(src));

      // Mismatched content size throws Lz4FormatException
      expect(
        () => lz4FrameEncodeWithOptions(
          src,
          options: Lz4FrameOptions(
            contentSize: src.length + 10,
          ),
        ),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('contentSize does not match src length'),
        )),
      );

      // Large 64-bit content size (> 4 GiB) exercises upper 32-bit math and exception
      const hugeSize = 0x140000000; // 5 GiB
      expect(
        () => lz4FrameEncodeWithOptions(
          Uint8List(0),
          options: Lz4FrameOptions(
            contentSize: hugeSize,
          ),
        ),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('contentSize does not match src length'),
        )),
      );
    });

    test('dictionary encoding with fast and HC engines', () {
      final dictionary = Uint8List.fromList(List.generate(128, (i) => i));
      const dictId = 0x12345678;
      final src = Uint8List.fromList(List.generate(64, (i) => i));

      // Fast compression engine
      final fastEncoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          dictId: dictId,
          compression: Lz4FrameCompression.fast,
        ),
        dictionary: dictionary,
      );

      final fastDecoded = lz4FrameDecode(
        fastEncoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );
      expect(fastDecoded, equals(src));

      // HC compression engine
      final hcEncoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          dictId: dictId,
          compression: Lz4FrameCompression.hc,
        ),
        dictionary: dictionary,
      );

      final hcDecoded = lz4FrameDecode(
        hcEncoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );
      expect(hcDecoded, equals(src));

      // lz4FrameEncode convenience function
      final convEncoded = lz4FrameEncode(src);
      expect(lz4FrameDecode(convEncoded), equals(src));
    });

    test('skippable frame encoding: indices 0 to 15 and bounds validation', () {
      final payload = Uint8List.fromList([10, 20, 30, 40]);

      // Indices 0 and 15 explicitly
      final frame0 = lz4SkippableFrameEncode(payload, index: 0);
      expect(frame0.length, 8 + payload.length);
      final view0 = ByteData.sublistView(frame0);
      expect(view0.getUint32(0, Endian.little), 0x184D2A50);
      expect(view0.getUint32(4, Endian.little), payload.length);
      expect(frame0.sublist(8), equals(payload));

      final frame15 = lz4SkippableFrameEncode(payload, index: 15);
      final view15 = ByteData.sublistView(frame15);
      expect(view15.getUint32(0, Endian.little), 0x184D2A5F);

      // Intermediate indices
      for (final idx in [1, 5, 8, 12]) {
        final frame = lz4SkippableFrameEncode(payload, index: idx);
        final view = ByteData.sublistView(frame);
        expect(view.getUint32(0, Endian.little), 0x184D2A50 + idx);
      }

      // Range errors for invalid indices
      expect(
          () => lz4SkippableFrameEncode(payload, index: -1), throwsRangeError);
      expect(
          () => lz4SkippableFrameEncode(payload, index: 16), throwsRangeError);

      // Exceeding 4 GiB limit (line 33)
      if (!identical(0, 0.0)) {
        final huge = Uint8List(0x100000000);
        expect(() => lz4SkippableFrameEncode(huge), throwsRangeError);
      }
    });

    test('legacy frame encoding with compressible and uncompressed branches',
        () {
      // Compressible data
      final compressible = Uint8List(1024);
      final leg1 = lz4LegacyFrameEncode(compressible);
      expect(lz4FrameInfo(leg1).isLegacy, isTrue);
      expect(lz4FrameDecode(leg1), equals(compressible));

      // Incompressible data
      final rng = Random(999);
      final incompressible =
          Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
      final leg2 = lz4LegacyFrameEncode(incompressible);
      expect(lz4FrameDecode(leg2), equals(incompressible));

      // lz4LegacyEncode wrapper
      final leg3 = lz4LegacyEncode(compressible, acceleration: 2);
      expect(lz4FrameDecode(leg3), equals(compressible));
    });
  });

  group('3. lz4_frame_decoder coverage', () {
    test(
        'linked blocks with history prefix in sync frame decode (dictLen < needed)',
        () {
      // Frame with blockIndependence: false and dictId.
      // Block 1: 16 bytes raw (uncompressed).
      // Block 2: compressed block referencing dict and Block 1 history.
      // dict is short (100 bytes < 64KB historyWindow), exercising dictLen < needed.
      final dict = Uint8List.fromList(
          List.generate(100, (i) => 'A'.codeUnitAt(0) + (i % 26)));
      const dictId = 0x99887766;

      final header = createFrameHeader(
        blockIndependence: false,
        dictId: true,
        dictIdValue: dictId,
      );

      final block1Data = Uint8List.fromList(List.generate(16, (i) => i + 1));

      // Create history buffer containing dictionary + block1
      final combinedHistory = Uint8List.fromList([...dict, ...block1Data]);

      // Block 2 references bytes from dictionary and block 1
      final block2Raw = Uint8List.fromList([
        ...dict.sublist(0, 10),
        ...block1Data.sublist(0, 8),
        99,
        100,
        101,
        102,
      ]);
      final block2Compressed =
          lz4BlockCompress(block2Raw, dictionary: combinedHistory);

      final frame = buildFrame(
        header: header,
        blocks: [block1Data, block2Compressed],
        isUncompressed: [true, false],
      );

      final decoded = lz4FrameDecodeBytes(
        frame,
        dictionaryResolver: (id) => id == dictId ? dict : null,
      );

      expect(decoded, equals([...block1Data, ...block2Raw]));
    });

    test(
        'linked blocks with history prefix in sync frame decode (dictLen >= needed)',
        () {
      // dict is 70 KiB (> 64 KiB historyWindow), exercising dictLen >= needed (copyLen = needed).
      const dictSize = 70 * 1024;
      final dict = Uint8List.fromList(List.generate(dictSize, (i) => i % 256));
      const dictId = 0xAABBCCDD;

      final header = createFrameHeader(
        blockIndependence: false,
        dictId: true,
        dictIdValue: dictId,
      );

      final block1Data = Uint8List.fromList([10, 20, 30, 40]);

      // History is the last (64KB - 4) bytes of dict + block1Data
      const needed = 64 * 1024 - 4;
      final copyStart = dict.length - needed;
      final effectiveDict = dict.sublist(copyStart);
      final combinedHistory =
          Uint8List.fromList([...effectiveDict, ...block1Data]);

      final block2Raw = Uint8List.fromList([
        ...effectiveDict.sublist(effectiveDict.length - 20),
        ...block1Data,
        1,
        2,
        3,
        4,
      ]);
      final block2Compressed =
          lz4BlockCompress(block2Raw, dictionary: combinedHistory);

      final frame = buildFrame(
        header: header,
        blocks: [block1Data, block2Compressed],
        isUncompressed: [true, false],
      );

      final decoded = lz4FrameDecodeBytes(
        frame,
        dictionaryResolver: (id) => id == dictId ? dict : null,
      );

      expect(decoded, equals([...block1Data, ...block2Raw]));
    });

    test(
        'linked blocks without dictionary: handles outHistoryLen > 0 and outHistoryLen == 0',
        () {
      // Dependent blocks without dictionary (dict == null)
      final header = createFrameHeader(blockIndependence: false);

      final block1Data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final block2Raw = Uint8List.fromList([...block1Data, 9, 10, 11, 12]);
      final block2Compressed =
          lz4BlockCompress(block2Raw, dictionary: block1Data);

      final frame = buildFrame(
        header: header,
        blocks: [block1Data, block2Compressed],
        isUncompressed: [true, false],
      );

      final decoded = lz4FrameDecode(frame);
      expect(decoded, equals([...block1Data, ...block2Raw]));

      // Dependent block with outHistoryLen == 0 (Block 1 is 0 bytes)
      final blockEmpty = Uint8List(0);
      final blockSoloRaw = Uint8List.fromList([55, 66, 77, 88]);
      final blockSoloCompressed = lz4BlockCompress(blockSoloRaw);

      final frame2 = buildFrame(
        header: header,
        blocks: [blockEmpty, blockSoloCompressed],
        isUncompressed: [true, false],
      );

      final decoded2 = lz4FrameDecode(frame2);
      expect(decoded2, equals(blockSoloRaw));
    });

    test(
        'dependent block decompression: produced > blockMaxSize throws Lz4CorruptDataException',
        () {
      // BD specifies 64KB max size, but compressed block claims to produce > 64KB
      final header = createFrameHeader(
        blockIndependence: false,
        blockMaxSizeId: 4, // 64KB
      );

      // Create a huge payload > 64KB
      final hugeData = Uint8List(65 * 1024);
      final compressedHuge = lz4BlockCompress(hugeData);

      final frame = buildFrame(
        header: header,
        blocks: [
          Uint8List.fromList([1, 2, 3]),
          compressedHuge
        ],
        isUncompressed: [true, false],
      );

      expect(
        () => lz4FrameDecode(frame),
        throwsA(anyOf(
          isA<Lz4CorruptDataException>(),
          isA<Lz4OutputLimitException>(),
        )),
      );
    });

    test('block checksum mismatch throws Lz4CorruptDataException', () {
      final header = createFrameHeader(blockChecksum: true);
      final block = Uint8List.fromList([1, 2, 3, 4, 5]);

      final writer = ByteWriter();
      writer.writeBytes(header);
      writer.writeUint32LE(0x80000000 | block.length); // uncompressed
      writer.writeBytes(block);
      // Corrupt block checksum
      writer.writeUint32LE(0xDEADBEEF);
      writer.writeUint32LE(0); // end mark

      expect(
        () => lz4FrameDecode(writer.toBytes()),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Block checksum mismatch'),
        )),
      );
    });

    test('content checksum mismatch throws Lz4CorruptDataException', () {
      final src = Uint8List.fromList([10, 20, 30, 40]);
      final encoded = lz4FrameEncodeWithOptions(
        src,
        options: Lz4FrameOptions(
          contentChecksum: true,
        ),
      );

      // Corrupt the last 4 bytes (content checksum)
      final corrupted = Uint8List.fromList(encoded);
      corrupted[corrupted.length - 1] ^= 0xFF;

      expect(
        () => lz4FrameDecode(corrupted),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Content checksum mismatch'),
        )),
      );
    });

    test('unexpected end of input at various frame locations in decoder', () {
      // 1. Truncated magic (< 4 bytes)
      expect(
        () => lz4FrameDecode(Uint8List(2)),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 2. Skippable frame with truncated size
      final truncSkip = Uint8List.fromList([0x50, 0x2A, 0x4D, 0x18, 0x01]);
      expect(
        () => lz4FrameDecode(truncSkip),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 3. Skippable frame with size > 0x7FFFFFFF
      final hugeSkip =
          Uint8List.fromList([0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x80]);
      expect(
        () => lz4FrameDecode(hugeSkip),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Skippable frame size too large'),
        )),
      );

      // 4. Standard frame truncated descriptor (< 3 bytes after magic)
      final truncDesc = Uint8List.fromList([0x04, 0x22, 0x4D, 0x18, 0x60]);
      expect(
        () => lz4FrameDecode(truncDesc),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 5. Standard frame truncated content size (< 8 bytes)
      final csHeader =
          createFrameHeader(contentSize: true, contentSizeValue: 50);
      expect(
        () => lz4FrameDecode(
            Uint8List.sublistView(csHeader, 0, csHeader.length - 4)),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 6. Standard frame truncated dictId (< 4 bytes)
      final dictHeader = createFrameHeader(dictId: true, dictIdValue: 12345);
      expect(
        () => lz4FrameDecode(
            Uint8List.sublistView(dictHeader, 0, dictHeader.length - 2)),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 7. Standard frame truncated before block size (< 4 bytes after header)
      final header = createFrameHeader();
      final truncBlockHeader = Uint8List.fromList([...header, 0x01, 0x02]);
      expect(
        () => lz4FrameDecode(truncBlockHeader),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 8. Standard frame truncated block checksum (< 4 bytes after block payload)
      final bcHeader = createFrameHeader(blockChecksum: true);
      final writer = ByteWriter();
      writer.writeBytes(bcHeader);
      writer.writeUint32LE(0x80000000 | 4); // 4 bytes uncompressed
      writer.writeBytes(Uint8List.fromList([1, 2, 3, 4]));
      writer
          .writeUint16LE(0x1234); // only 2 bytes of block checksum instead of 4
      expect(
        () => lz4FrameDecode(writer.toBytes()),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 9. Standard frame truncated content checksum (< 4 bytes after end mark)
      final ccHeader = createFrameHeader(contentChecksum: true);
      final ccWriter = ByteWriter();
      ccWriter.writeBytes(ccHeader);
      ccWriter.writeUint32LE(0); // end mark
      ccWriter.writeUint8(0xFF); // only 1 byte of content checksum instead of 4
      expect(
        () => lz4FrameDecode(ccWriter.toBytes()),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );
    });

    test('decoder header checksum mismatch and feature/format exceptions', () {
      // Header checksum mismatch
      final badHcHeader = createFrameHeader(corruptHc: true);
      final badHcFrame = buildFrame(header: badHcHeader);
      expect(
        () => lz4FrameDecode(badHcFrame),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Header checksum mismatch'),
        )),
      );

      // Unsupported frame version
      final badVersion = buildFrame(header: createFrameHeader(version: 0));
      expect(
        () => lz4FrameDecode(badVersion),
        throwsA(isA<Lz4UnsupportedFeatureException>().having(
          (e) => e.message,
          'message',
          contains('Unsupported LZ4 frame version'),
        )),
      );

      // Reserved FLG bit set
      final badFlg = buildFrame(header: createFrameHeader(reservedFlg: 1));
      expect(
        () => lz4FrameDecode(badFlg),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Reserved FLG bit is set'),
        )),
      );

      // Reserved BD bits set
      final badBd = buildFrame(header: createFrameHeader(reservedBd: 0x01));
      expect(
        () => lz4FrameDecode(badBd),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Reserved BD bits are set'),
        )),
      );

      // Invalid block maximum size in BD
      final badBms = buildFrame(header: createFrameHeader(blockMaxSizeId: 1));
      expect(
        () => lz4FrameDecode(badBms),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Invalid block maximum size'),
        )),
      );

      // Valid block maximum sizes in BD (cases 5, 6, 7)
      for (final id in [5, 6, 7]) {
        final frameWithBms = buildFrame(
          header: createFrameHeader(blockMaxSizeId: id),
          blocks: [
            Uint8List.fromList([1, 2, 3])
          ],
          isUncompressed: [true],
        );
        expect(lz4FrameDecode(frameWithBms), equals([1, 2, 3]));
      }

      // Invalid LZ4 frame magic number
      final badMagic = Uint8List.fromList([0x00, 0x11, 0x22, 0x33, 0x44]);
      expect(
        () => lz4FrameDecode(badMagic),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Invalid LZ4 frame magic number'),
        )),
      );
    });

    test('decoder dictionary error handling', () {
      final header = createFrameHeader(dictId: true, dictIdValue: 0x55667788);
      final frame = buildFrame(header: header);

      // No dictionary resolver provided
      expect(
        () => lz4FrameDecode(frame),
        throwsA(isA<Lz4UnsupportedFeatureException>().having(
          (e) => e.message,
          'message',
          contains('Dictionary ID present but no dictionary resolver provided'),
        )),
      );

      // Dictionary resolver returns null
      expect(
        () => lz4FrameDecode(frame, dictionaryResolver: (_) => null),
        throwsA(isA<Lz4Exception>().having(
          (e) => e.message,
          'message',
          contains('Dictionary not found for ID: 1432778632'),
        )),
      );
    });

    test('decoder block size exceeds maximum', () {
      final header = createFrameHeader(blockMaxSizeId: 4); // 64KB max
      final writer = ByteWriter();
      writer.writeBytes(header);
      // Raw block size = 64KB + 1
      writer.writeUint32LE(0x80000000 | (64 * 1024 + 1));
      expect(
        () => lz4FrameDecode(writer.toBytes()),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Block size exceeds maximum'),
        )),
      );
    });

    test('decoder content size mismatch at frame end', () {
      final header =
          createFrameHeader(contentSize: true, contentSizeValue: 100);
      // Produce only 10 bytes of data
      final frame = buildFrame(
        header: header,
        blocks: [Uint8List(10)],
        isUncompressed: [true],
      );

      expect(
        () => lz4FrameDecode(frame),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Content size mismatch'),
        )),
      );
    });

    test('decoder maxOutputBytes limits', () {
      // Limit checked against declared content size
      final csHeader =
          createFrameHeader(contentSize: true, contentSizeValue: 500);
      final csFrame = buildFrame(header: csHeader);
      expect(
        () => lz4FrameDecode(csFrame, maxOutputBytes: 100),
        throwsA(isA<Lz4OutputLimitException>().having(
          (e) => e.message,
          'message',
          contains('Content size exceeds output limit'),
        )),
      );

      // Limit checked during decompression
      final header = createFrameHeader();
      final frame = buildFrame(
        header: header,
        blocks: [Uint8List(200)],
        isUncompressed: [true],
      );
      expect(
        () => lz4FrameDecode(frame, maxOutputBytes: 50),
        throwsA(isA<Lz4OutputLimitException>()),
      );
    });

    test('legacy frame decoding error handling and boundaries', () {
      // 1. Truncated legacy frame (< 4 bytes for block size)
      final truncLegacy =
          Uint8List.fromList([0x02, 0x21, 0x4C, 0x18, 0x01, 0x02]);
      expect(
        () => lz4FrameDecode(truncLegacy),
        throwsA(isA<Lz4FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected end of input'),
        )),
      );

      // 2. Legacy block size 0 throws Lz4CorruptDataException
      final zeroBlockLegacy = Uint8List.fromList([
        0x02, 0x21, 0x4C, 0x18, // Legacy magic
        0x00, 0x00, 0x00, 0x00, // Block size 0
      ]);
      expect(
        () => lz4FrameDecode(zeroBlockLegacy),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Invalid legacy block size'),
        )),
      );

      // 3. Non-full legacy block followed by another block throws Lz4CorruptDataException
      // In legacy frames, non-terminal blocks must be 8 MiB (8388608 bytes).
      // If block 1 produces 10 bytes and is followed by another block, it must throw.
      final smallData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final smallCompressed = lz4BlockCompress(smallData);

      final multiBlockLegacy = ByteWriter();
      multiBlockLegacy.writeUint32LE(0x184C2102); // legacy magic
      multiBlockLegacy.writeUint32LE(smallCompressed.length);
      multiBlockLegacy.writeBytes(smallCompressed);
      // Next block
      multiBlockLegacy.writeUint32LE(smallCompressed.length);
      multiBlockLegacy.writeBytes(smallCompressed);

      expect(
        () => lz4FrameDecode(multiBlockLegacy.toBytes()),
        throwsA(isA<Lz4CorruptDataException>().having(
          (e) => e.message,
          'message',
          contains('Legacy block is not full'),
        )),
      );

      // 4. Legacy frame followed by skippable and standard frames
      final raw1 = Uint8List.fromList([11, 22, 33, 44]);
      final legFrame = lz4LegacyFrameEncode(raw1);

      final skipFrame =
          lz4SkippableFrameEncode(Uint8List.fromList([99, 98, 97]));

      final raw2 = Uint8List.fromList([55, 66, 77, 88]);
      final stdFrame = lz4FrameEncode(raw2);

      final concatenated = Uint8List.fromList([
        ...legFrame,
        ...skipFrame,
        ...stdFrame,
      ]);

      final decodedConcatenated = lz4FrameDecode(concatenated);
      expect(decodedConcatenated, equals([...raw1, ...raw2]));
    });
  });
}
