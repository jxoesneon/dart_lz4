import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/block/lz4_block_encoder.dart';
import 'package:dart_lz4/src/frame/lz4_engine_factory.dart';
import 'package:dart_lz4/src/hc/lz4_hc_block_encoder.dart';
import 'package:dart_lz4/src/internal/byte_writer.dart';
import 'package:dart_lz4/src/xxhash/xxh32.dart';
import 'package:test/test.dart';

void main() {
  group('xxh32 and Xxh32 coverage tests', () {
    test('Xxh32 parameter range errors and web precision guard', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final hasher = Xxh32();

      // Line 43: start < 0 or start > input.length
      expect(() => hasher.update(data, start: -1), throwsRangeError);
      expect(() => hasher.update(data, start: 9), throwsRangeError);

      // Line 46: end < start or end > input.length
      expect(() => hasher.update(data, start: 4, end: 3), throwsRangeError);
      expect(() => hasher.update(data, start: 0, end: 10), throwsRangeError);

      // Empty update: length == 0 returns early (line 52)
      hasher.update(data, start: 2, end: 2);
      expect(hasher.digest(), 0x02CC5D05); // same as empty digest with seed 0

      // Normal update evaluates nextLen web guard (line 56)
      final h2 = Xxh32();
      h2.update(data, start: 0, end: data.length);
      expect(h2.digest(), xxh32(data));
    });

    test(
        'Unaligned buffer lengths (length % 4 == 1, 2, 3) for small inputs (<16)',
        () {
      final sample =
          Uint8List.fromList(List.generate(16, (i) => (i * 17 + 3) & 0xff));

      for (var len = 0; len < 16; len++) {
        final sub = Uint8List.sublistView(sample, 0, len);
        final expected = xxh32(sub);
        final helperExpected = xxh32Digest(sub);
        expect(helperExpected, expected);

        final streaming = Xxh32();
        streaming.update(sub);
        expect(streaming.digest(), expected,
            reason: 'len=$len (% 4 = ${len % 4})');
      }
    });

    test('Unaligned buffer lengths (length % 4 == 1, 2, 3) for inputs >= 16',
        () {
      final sample =
          Uint8List.fromList(List.generate(128, (i) => (i * 31 + 7) & 0xff));

      // Test lengths with various mod 4 values
      for (final len in [
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        31,
        32,
        33,
        47,
        48,
        49,
        63,
        64,
        65,
        99,
        100,
        101,
        102,
        103
      ]) {
        final sub = Uint8List.sublistView(sample, 0, len);
        final expected = xxh32(sub);
        final helperExpected = xxh32Digest(sub);
        expect(helperExpected, expected);

        final streaming = Xxh32();
        streaming.update(sub);
        expect(streaming.digest(), expected,
            reason: 'len=$len (% 4 = ${len % 4})');
      }
    });

    test(
        'Unaligned memory offset (input.offsetInBytes % 4 != 0) for one-shot and streaming',
        () {
      final backing =
          Uint8List.fromList(List.generate(200, (i) => (i * 13 + 5) & 0xff));

      // Test unaligned byte offsets 1, 2, 3 to trigger fallback paths in xxh32 and Xxh32
      for (final offset in [1, 2, 3]) {
        for (final len in [16, 20, 25, 32, 47, 64]) {
          final unalignedView =
              Uint8List.sublistView(backing, offset, offset + len);
          expect(unalignedView.offsetInBytes % 4, isNot(0));

          final oneShot = xxh32(unalignedView);
          final helper = xxh32Digest(unalignedView);
          expect(helper, oneShot);

          final streaming = Xxh32();
          streaming.update(unalignedView);
          expect(streaming.digest(), oneShot,
              reason: 'offset=$offset, len=$len');
        }
      }
    });

    test('Custom seed values with small, large, and unaligned inputs', () {
      final seeds = [
        0,
        1,
        0x9E3779B1,
        0x85EBCA77,
        0xC2B2AE3D,
        0x27D4EB2F,
        0x165667B1,
        0x12345678,
        0xFFFFFFFF,
        -1,
        42,
      ];

      final testInputs = [
        Uint8List(0),
        Uint8List.fromList([42]),
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([1, 2, 3, 4]),
        Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
        Uint8List.fromList(List.generate(16, (i) => i)),
        Uint8List.fromList(List.generate(19, (i) => i * 3)),
        Uint8List.fromList(List.generate(65, (i) => (i * 17) & 0xff)),
      ];

      for (final seed in seeds) {
        for (final input in testInputs) {
          final oneShot = xxh32(input, seed: seed);
          final helper = xxh32Digest(input, seed: seed);
          expect(helper, oneShot);

          final hasher = Xxh32(seed: seed);
          hasher.update(input);
          expect(hasher.digest(), oneShot,
              reason: 'seed=$seed, len=${input.length}');
        }
      }
    });

    test(
        'Incremental streaming Xxh32 with odd chunk sizes (1 byte, 3 bytes, 7 bytes)',
        () {
      final rng = Random(42);
      final testData = Uint8List(250);
      for (var i = 0; i < testData.length; i++) {
        testData[i] = rng.nextInt(256);
      }

      final chunkSizes = [1, 3, 7, 9, 11, 13, 17];

      for (final chunkSize in chunkSizes) {
        for (final totalLen in [
          0,
          1,
          2,
          3,
          4,
          7,
          15,
          16,
          17,
          23,
          31,
          32,
          33,
          49,
          64,
          65,
          100,
          127,
          250
        ]) {
          final input = Uint8List.sublistView(testData, 0, totalLen);
          final expected = xxh32(input, seed: 0x12345678);

          final hasher = Xxh32(seed: 0x12345678);
          var pos = 0;
          while (pos < input.length) {
            final end = min(pos + chunkSize, input.length);
            hasher.update(input, start: pos, end: end);
            pos = end;
          }

          expect(
            hasher.digest(),
            expected,
            reason: 'chunkSize=$chunkSize, totalLen=$totalLen',
          );
        }
      }
    });

    test('Incremental streaming Xxh32 multi-block fill and drain transitions',
        () {
      final hasher = Xxh32();
      // Step 1: 5 bytes (buffered in _mem)
      hasher.update(Uint8List.fromList([1, 2, 3, 4, 5]));
      // Step 2: 7 bytes (total 12, still < 16)
      hasher.update(Uint8List.fromList([6, 7, 8, 9, 10, 11, 12]));
      // Step 3: 10 bytes (spans across 16-byte boundary: 4 fill _mem, 6 remain)
      hasher
          .update(Uint8List.fromList([13, 14, 15, 16, 17, 18, 19, 20, 21, 22]));
      // Step 4: 20 bytes (spans another boundary)
      hasher.update(Uint8List.fromList(List.generate(20, (i) => 23 + i)));

      final allData = Uint8List.fromList(List.generate(42, (i) => i + 1));
      expect(hasher.digest(), xxh32(allData));
      expect(xxh32Digest(allData), xxh32(allData));
    });
  });

  group('lz4_hc_block_encoder backward match and dictionary prefix coverage',
      () {
    test(
        'match length boundary handling and backward extension within block (lines 143, 144, 145)',
        () {
      // Create a scenario where an earlier match skips inserting intermediate positions into hashTable.
      // A later match hits at an inserted position, and the preceding bytes match the skipped position,
      // causing lines 140-146 in PureDartLz4HcEngine to decrement matchStart, refStart, and increment actualLen!
      final builder = BytesBuilder();

      // Segment 1: Distinct literals to populate initial hash table
      // Pos 0..9: 10 distinct bytes
      builder.add([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      // Segment 2: Match length 7 at pos 10 matching pos 0..6
      // When match of len 7 is processed at pos 10:
      // i advances from 10 to 17.
      // stop = 17 - 4 = 13.
      // Positions 14, 15, 16 are SKIPPED (never inserted into hashTable).
      // Pos 16 has byte 7. Pos 17 has byte 99.
      builder.add([1, 2, 3, 4, 5, 6, 7]);

      // Segment 3: Pos 17..25
      builder.add([99, 100, 101, 102, 103, 104, 105, 106]);

      // Segment 4: Literals to advance anchor
      builder.add([200, 201, 202, 203, 204]);

      // Segment 5: Preceded by byte 7 (which was at skipped pos 16),
      // followed by 99, 100, 101, 102...
      // Since pos 16 was not inserted, the encoder doesn't match at byte 7,
      // but matches at 99 (pos 17).
      // Then the backward while loop triggers: input[matchStart-1] == input[refStart-1] (7 == 7)!
      builder.add([7, 99, 100, 101, 102, 103, 104, 105, 106]);

      // Trailing bytes
      builder.add([210, 211, 212, 213, 214, 215, 216, 217, 218, 219]);

      final input = builder.toBytes();

      final compressed =
          lz4HcBlockCompress(input, options: Lz4HcOptions(maxSearchDepth: 64));
      final decompressed =
          lz4Decompress(compressed, decompressedSize: input.length);
      expect(decompressed, equals(input));
    });

    test(
        'dictionary prefix compression with HC mode and backward extension into dictionary prefix',
        () {
      // In this test, the dictionary contains a pattern that is partially shadowed or preceded by identical bytes.
      // The encoder starts matching in src and extends backward into the dictionary prefix!
      final dictBuilder = BytesBuilder();
      // Prefix padding
      dictBuilder.add(List.generate(30, (i) => 50 + i));
      // Target match region in dict: pos 30..45
      // Preceding byte: 0x77 at pos 29
      dictBuilder.add([0x77]);
      dictBuilder.add([10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);
      // Shadow pos 29 with another sequence elsewhere with maxSearchDepth 1
      dictBuilder.add(List.generate(20, (i) => 100 + i));
      dictBuilder.add([0x77, 99, 88, 77]); // pos 51 overwrites hash for 0x77
      dictBuilder.add(List.generate(10, (i) => 200 + i));

      final dictionary = dictBuilder.toBytes();

      final srcBuilder = BytesBuilder();
      srcBuilder.add([0xAA, 0xBB]); // literals at start of src
      // Preceding byte 0x77, followed by 10, 11, 12, 13, 14, 15, 16, 17
      srcBuilder.add([0x77, 10, 11, 12, 13, 14, 15, 16, 17]);
      srcBuilder.add([0xCC, 0xDD, 0xEE, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05]);

      final src = srcBuilder.toBytes();

      // Compress with HC engine with level1 (search depth 1) and dictionary
      final engine =
          PureDartLz4HcEngine(options: Lz4HcOptions(level: Lz4HcLevel.level1));
      final writer = ByteWriter(initialCapacity: src.length * 2);
      engine.compress(writer, src, dictionary: dictionary);
      final compressedBytes = writer.toBytes();

      expect(compressedBytes.isNotEmpty, isTrue);

      // Frame roundtrip with HC mode and dictionary
      const dictId = 0x55AA1122;
      final frameOptions = Lz4FrameOptions(
        compression: Lz4FrameCompression.hc,
        hcOptions: Lz4HcOptions(level: Lz4HcLevel.level1),
        dictId: dictId,
      );

      final frameEncoded = lz4FrameEncodeWithOptions(
        src,
        options: frameOptions,
        dictionary: dictionary,
      );

      final frameDecoded = lz4FrameDecode(
        frameEncoded,
        dictionaryResolver: (id) => id == dictId ? dictionary : null,
      );

      expect(frameDecoded, equals(src));
    });

    test(
        'HC block encoder boundary cases: empty, short input with dictionary, large dictionary',
        () {
      final dict =
          Uint8List.fromList(List.generate(100, (i) => (i * 7) & 0xff));

      // 1. Empty src with dictionary
      final writerEmpty = ByteWriter();
      PureDartLz4HcEngine(options: Lz4HcOptions())
          .compress(writerEmpty, Uint8List(0), dictionary: dict);
      expect(writerEmpty.length, 0);

      // 2. Short src (< 4 bytes) with dictionary (hits line 61)
      for (var len = 1; len < 4; len++) {
        final shortSrc =
            Uint8List.fromList(List.generate(len, (i) => 0x41 + i));
        final writerShort = ByteWriter();
        PureDartLz4HcEngine(options: Lz4HcOptions())
            .compress(writerShort, shortSrc, dictionary: dict);
        expect(writerShort.length, greaterThan(0));
      }

      // 3. Empty dictionary (dictFull.isEmpty branch)
      final normalSrc = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final writerEmptyDict = ByteWriter();
      PureDartLz4HcEngine(options: Lz4HcOptions())
          .compress(writerEmptyDict, normalSrc, dictionary: Uint8List(0));
      expect(writerEmptyDict.length, greaterThan(0));

      // 4. Large dictionary (> 65535 bytes) to test sublistView window truncation (lines 39-44)
      final largeDict = Uint8List(70 * 1024);
      for (var i = 0; i < largeDict.length; i++) {
        largeDict[i] = (i * 13) & 0xff;
      }
      final writerLargeDict = ByteWriter();
      PureDartLz4HcEngine(options: Lz4HcOptions())
          .compress(writerLargeDict, normalSrc, dictionary: largeDict);
      expect(writerLargeDict.length, greaterThan(0));

      // 5. Long literals and long match (> 255 bytes) to exercise _writeLength (lines 261-268)
      final longBuilder = BytesBuilder();
      // 300 non-repeating literals
      longBuilder.add(List.generate(300, (i) => i % 251));
      // 300 repeating bytes (match)
      longBuilder.add(List.filled(300, 0x55));
      final longInput = longBuilder.toBytes();

      final longCompressed = lz4HcBlockCompress(longInput);
      final longDecompressed =
          lz4Decompress(longCompressed, decompressedSize: longInput.length);
      expect(longDecompressed, equals(longInput));

      // 6. Distance > 0xFFFF branch (line 112)
      final hugeData = Uint8List(70 * 1024);
      hugeData.setRange(0, 8, [1, 2, 3, 4, 5, 6, 7, 8]);
      hugeData.setRange(68 * 1024, 68 * 1024 + 8, [1, 2, 3, 4, 5, 6, 7, 8]);
      final hugeCompressed = lz4HcBlockCompress(hugeData,
          options: Lz4HcOptions(maxSearchDepth: 8));
      final hugeDecompressed =
          lz4Decompress(hugeCompressed, decompressedSize: hugeData.length);
      expect(hugeDecompressed, equals(hugeData));
    });
  });

  group('lz4_engine_factory coverage tests', () {
    test(
        'createLz4Engine instantiates PureDartLz4FastEngine with fast compression',
        () {
      final optionsDefault = Lz4FrameOptions(
        compression: Lz4FrameCompression.fast,
      );
      final engineDefault = createLz4Engine(optionsDefault);
      expect(engineDefault, isA<PureDartLz4FastEngine>());

      final optionsCustom = Lz4FrameOptions(
        compression: Lz4FrameCompression.fast,
        acceleration: 5,
      );
      final engineCustom = createLz4Engine(optionsCustom);
      expect(engineCustom, isA<PureDartLz4FastEngine>());
      expect((engineCustom as PureDartLz4FastEngine).acceleration, 5);

      // Verify compression functionality with fast engine
      final testData = Uint8List.fromList([1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8]);
      final writer = ByteWriter();
      engineCustom.compress(writer, testData);
      expect(writer.length, greaterThan(0));
      final decompressed =
          lz4Decompress(writer.toBytes(), decompressedSize: testData.length);
      expect(decompressed, equals(testData));
    });

    test('createLz4Engine instantiates PureDartLz4HcEngine with hc compression',
        () {
      // 1. Default hcOptions (null -> default Lz4HcOptions())
      final optionsDefaultHc = Lz4FrameOptions(
        compression: Lz4FrameCompression.hc,
      );
      final engineDefaultHc = createLz4Engine(optionsDefaultHc);
      expect(engineDefaultHc, isA<PureDartLz4HcEngine>());
      final hcEngine = engineDefaultHc as PureDartLz4HcEngine;
      expect(hcEngine.options.maxSearchDepth, 64);
      expect(hcEngine.options.level, isNull);

      // 2. Custom hcOptions with level
      final optionsCustomHc = Lz4FrameOptions(
        compression: Lz4FrameCompression.hc,
        hcOptions: Lz4HcOptions(level: Lz4HcLevel.level9),
      );
      final engineCustomHc = createLz4Engine(optionsCustomHc);
      expect(engineCustomHc, isA<PureDartLz4HcEngine>());
      final hcEngineCustom = engineCustomHc as PureDartLz4HcEngine;
      expect(hcEngineCustom.options.level, Lz4HcLevel.level9);
      expect(hcEngineCustom.options.effectiveSearchDepth, 128);

      // Verify compression functionality with HC engine
      final testData = Uint8List.fromList([1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8]);
      final writer = ByteWriter();
      hcEngineCustom.compress(writer, testData);
      expect(writer.length, greaterThan(0));
      final decompressed =
          lz4Decompress(writer.toBytes(), decompressedSize: testData.length);
      expect(decompressed, equals(testData));
    });

    test('frame encode and decode roundtrip using both engine factories', () {
      final data =
          Uint8List.fromList(List.generate(1000, (i) => (i % 25) + 65));

      // Fast frame compression
      final fastEncoded = lz4FrameEncodeWithOptions(
        data,
        options: Lz4FrameOptions(
          compression: Lz4FrameCompression.fast,
          acceleration: 2,
        ),
      );
      expect(lz4FrameDecode(fastEncoded), equals(data));

      // HC frame compression
      final hcEncoded = lz4FrameEncodeWithOptions(
        data,
        options: Lz4FrameOptions(
          compression: Lz4FrameCompression.hc,
          hcOptions: Lz4HcOptions(level: Lz4HcLevel.level6),
        ),
      );
      expect(lz4FrameDecode(hcEncoded), equals(data));
      // HC should achieve equal or better compression than fast mode
      expect(hcEncoded.length, lessThanOrEqualTo(fastEncoded.length));
    });
  });
}
