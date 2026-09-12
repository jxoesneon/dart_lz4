import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/block/lz4_block_decoder.dart';
import 'package:dart_lz4/src/block/lz4_block_encoder.dart';
import 'package:dart_lz4/src/internal/byte_writer.dart';
import 'package:test/test.dart';

void main() {
  group('LZ4 Block Decoder Coverage Tests', () {
    test('decompressedSize < 0 throws RangeError (line 15)', () {
      expect(
        () => lz4BlockDecompress(Uint8List(0), decompressedSize: -1),
        throwsRangeError,
      );
      expect(
        () => lz4BlockDecompress(Uint8List(5), decompressedSize: -42),
        throwsRangeError,
      );
    });

    test(
        'decompressedSize exceeds maxDecompressedSize throws Lz4FormatException (line 19)',
        () {
      expect(
        () => lz4BlockDecompress(
          Uint8List(0),
          decompressedSize: 100,
          maxDecompressedSize: 50,
        ),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maxDecompressedSize'),
          ),
        ),
      );
      expect(
        () => lz4BlockDecompress(
          Uint8List(0),
          decompressedSize: 1,
          maxDecompressedSize: 0,
        ),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maxDecompressedSize (0)'),
          ),
        ),
      );
    });

    test(
        'trailing bytes after literal-only block throw Lz4CorruptDataException (line 55)',
        () {
      // 2 literals: [0xAA, 0xBB], but there is an extra trailing byte 0xCC
      final src = Uint8List.fromList([
        0x20, // 2 literals, 0 match
        0xAA, 0xBB,
        0xCC, // trailing byte
      ]);

      expect(
        () => lz4BlockDecompress(src, decompressedSize: 2),
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            contains('Trailing bytes after end of block'),
          ),
        ),
      );
    });

    test(
        'trailing bytes after match copy throw Lz4CorruptDataException (line 83)',
        () {
      // Decompressed size = 5.
      // 1 literal 'A', match length = 0 + 4 = 4 with distance 1 => 5 bytes total.
      // Followed by an unexpected trailing byte 0xFF.
      final src = Uint8List.fromList([
        0x10, // 1 literal, 0 base match length (+4 = 4)
        0x41, // 'A'
        0x01, 0x00, // distance 1
        0xFF, // trailing byte
      ]);

      expect(
        () => lz4BlockDecompress(src, decompressedSize: 5),
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            contains('Trailing bytes after end of block'),
          ),
        ),
      );
    });

    test(
        'corrupt token literal length overflow throws Lz4CorruptDataException (line 43)',
        () {
      // decompressedSize = 3, but token specifies 4 literals
      final src = Uint8List.fromList([
        0x40, // 4 literals > decompressedSize (3)
        0x01, 0x02, 0x03, 0x04,
      ]);

      expect(
        () => lz4BlockDecompress(src, decompressedSize: 3),
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            contains('Literal length exceeds output size'),
          ),
        ),
      );

      // Extended literal length overflow
      final extSrc = Uint8List.fromList([
        0xF0, // 15 literals + extended
        0x05, // +5 = 20 literals > decompressedSize (16)
        ...Uint8List(20),
      ]);

      expect(
        () => lz4BlockDecompress(extSrc, decompressedSize: 16),
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            contains('Literal length exceeds output size'),
          ),
        ),
      );
    });

    test(
        'match length exceeds output size throws Lz4CorruptDataException (line 72, 78)',
        () {
      // decompressedSize = 5.
      // 1 literal 'A', match length base 2 (+4 = 6) => 1 + 6 = 7 > 5.
      final src = Uint8List.fromList([
        0x12, // 1 literal, match length = 2 + 4 = 6
        0x41, // literal 'A'
        0x01, 0x00, // distance 1
      ]);

      expect(
        () => lz4BlockDecompress(src, decompressedSize: 5),
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            contains('Match length exceeds output size'),
          ),
        ),
      );

      // Extended match length exceeds output size
      final extMatchSrc = Uint8List.fromList([
        0x1F, // 1 literal, match length 15 + extended
        0x41, // literal 'A'
        0x01, 0x00, // distance 1
        0x10, // +16 => match length = 15 + 4 + 16 = 35 > 10 - 1 = 9
      ]);

      expect(
        () => lz4BlockDecompress(extMatchSrc, decompressedSize: 10),
        throwsA(
          isA<Lz4CorruptDataException>().having(
            (e) => e.message,
            'message',
            contains('Match length exceeds output size'),
          ),
        ),
      );
    });

    test(
        'incomplete tokens / unexpected end of input in lz4BlockDecompress (line 32, 61)',
        () {
      // Line 32: EOF when starting a token loop while output is incomplete
      expect(
        () => lz4BlockDecompress(Uint8List(0), decompressedSize: 5),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );

      // Line 32: EOF after a complete sequence when more decompressed bytes expected
      final partialSrc = Uint8List.fromList([
        0x10, // 1 literal, 0 match
        0x41, // 'A'
        0x01, 0x00, // distance 1
      ]);
      expect(
        () => lz4BlockDecompress(partialSrc, decompressedSize: 10),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );

      // Line 61: 0 bytes remaining for 2-byte distance
      final srcNoDist = Uint8List.fromList([0x00]);
      expect(
        () => lz4BlockDecompress(srcNoDist, decompressedSize: 10),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );

      // Line 61: Only 1 byte remaining for 2-byte distance
      final srcOneByteDist = Uint8List.fromList([0x00, 0x01]);
      expect(
        () => lz4BlockDecompress(srcOneByteDist, decompressedSize: 10),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );
    });

    test(
        'incomplete tokens / unexpected end of input in lz4BlockDecompressInto (line 127)',
        () {
      final writer = ByteWriter();

      // Only token byte, 0 bytes for distance
      final src0 = Uint8List.fromList([0x00]);
      expect(
        () => lz4BlockDecompressInto(src0, writer),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );

      // Token + 1 byte for distance
      final src1 = Uint8List.fromList([0x00, 0x05]);
      expect(
        () => lz4BlockDecompressInto(src1, writer),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );

      // Token with literal followed by incomplete distance
      final srcLitIncompleteDist = Uint8List.fromList([0x10, 0x41, 0x02]);
      expect(
        () => lz4BlockDecompressInto(srcLitIncompleteDist, writer),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unexpected end of input'),
          ),
        ),
      );
    });

    test(
        'lz4BlockDecompressInto extended literal and match lengths (lines 114, 133)',
        () {
      // Extended literal length (token literal = 15, +5 = 20)
      final lits = List<int>.generate(20, (i) => (i + 1) * 3);
      final srcExtLit = Uint8List.fromList([
        0xF0, // 15 literals + extended
        0x05, // +5 => 20 literals
        ...lits,
      ]);
      final writer1 = ByteWriter();
      lz4BlockDecompressInto(srcExtLit, writer1);
      expect(writer1.toBytes(), equals(lits));

      // Extended match length (token match = 15, +3 => 15 + 4 + 3 = 22)
      final srcExtMatch = Uint8List.fromList([
        0x1F, // 1 literal, 15 match + extended
        0x42, // 'B'
        0x01, 0x00, // distance 1
        0x03, // +3 => 22 match length
      ]);
      final writer2 = ByteWriter();
      lz4BlockDecompressInto(srcExtMatch, writer2);
      expect(writer2.toBytes(), equals(List<int>.filled(23, 0x42)));
    });

    test('extended length sequence overflow iterations > 0x1000000 (line 202)',
        () {
      // 0x1000000 is 16,777,216. 0x1000001 bytes of 255 exceeds the limit.
      const overflowCount = 0x1000001;

      // Test in literal length sequence
      final litOverflow = Uint8List(1 + overflowCount);
      litOverflow[0] = 0xF0; // 15 literals + extended length
      litOverflow.fillRange(1, litOverflow.length, 255);

      expect(
        () => lz4BlockDecompress(litOverflow, decompressedSize: 10),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Extended length sequence too long',
          ),
        ),
      );

      // Test in match length sequence
      final matchOverflow = Uint8List(4 + overflowCount);
      matchOverflow[0] = 0x1F; // 1 literal, match length 15 + extended
      matchOverflow[1] = 0x41; // 'A'
      matchOverflow[2] = 0x01; // distance low
      matchOverflow[3] = 0x00; // distance high
      matchOverflow.fillRange(4, matchOverflow.length, 255);

      expect(
        () => lz4BlockDecompress(matchOverflow, decompressedSize: 10),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            'Extended length sequence too long',
          ),
        ),
      );
    });

    group('lz4BlockDecompressIntoBuffer coverage', () {
      test('dstOffset < 0 and dstOffset > dst.length throw RangeError', () {
        final dst = Uint8List(10);
        final emptySrc = Uint8List(0);

        expect(
          () => lz4BlockDecompressIntoBuffer(emptySrc, dst, dstOffset: -1),
          throwsRangeError,
        );
        expect(
          () => lz4BlockDecompressIntoBuffer(emptySrc, dst, dstOffset: -10),
          throwsRangeError,
        );
        expect(
          () => lz4BlockDecompressIntoBuffer(emptySrc, dst, dstOffset: 11),
          throwsRangeError,
        );
        expect(
          () => lz4BlockDecompressIntoBuffer(emptySrc, dst, dstOffset: 50),
          throwsRangeError,
        );
        // dstOffset == dst.length is valid for empty decompression
        expect(
          lz4BlockDecompressIntoBuffer(emptySrc, dst, dstOffset: 10),
          equals(0),
        );
      });

      test('Lz4OutputLimitException when destination buffer is too small', () {
        final raw = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        final compressed = lz4Compress(raw);

        // Buffer too small at offset 0
        final smallDst = Uint8List(5);
        expect(
          () => lz4BlockDecompressIntoBuffer(compressed, smallDst),
          throwsA(
            isA<Lz4OutputLimitException>().having(
              (e) => e.message,
              'message',
              contains('Destination buffer too small'),
            ),
          ),
        );

        // Buffer length 12, but dstOffset 5 leaves only 7 bytes (needs 10)
        final offsetDst = Uint8List(12);
        expect(
          () =>
              lz4BlockDecompressIntoBuffer(compressed, offsetDst, dstOffset: 5),
          throwsA(
            isA<Lz4OutputLimitException>().having(
              (e) => e.message,
              'message',
              contains('Destination buffer too small'),
            ),
          ),
        );

        // Buffer too small for literals
        final litBlock = Uint8List.fromList([0x60, 1, 2, 3, 4, 5, 6]);
        expect(
          () => lz4BlockDecompressIntoBuffer(litBlock, Uint8List(4)),
          throwsA(isA<Lz4OutputLimitException>()),
        );

        // Buffer too small for match copy
        final matchBlock = Uint8List.fromList([
          0x40, // 4 literals, match length 4 => total 8
          1, 2, 3, 4,
          0x04, 0x00, // distance 4
        ]);
        expect(
          () => lz4BlockDecompressIntoBuffer(matchBlock, Uint8List(6)),
          throwsA(isA<Lz4OutputLimitException>()),
        );
      });

      test('Lz4CorruptDataException and other rethrown exceptions', () {
        // Invalid match distance = 0
        final corruptZeroDist = Uint8List.fromList([
          0x40, 1, 2, 3, 4,
          0x00, 0x00, // invalid distance 0
        ]);
        expect(
          () => lz4BlockDecompressIntoBuffer(corruptZeroDist, Uint8List(16)),
          throwsA(
            isA<Lz4CorruptDataException>().having(
              (e) => e.message,
              'message',
              contains('Invalid match distance'),
            ),
          ),
        );

        // Invalid match distance referencing before dstOffset
        final corruptDistanceBeforeOffset = Uint8List.fromList([
          0x40, 1, 2, 3, 4,
          0x06, 0x00, // distance 6 > length - offset (4)
        ]);
        expect(
          () => lz4BlockDecompressIntoBuffer(
            corruptDistanceBeforeOffset,
            Uint8List(20),
            dstOffset: 5,
          ),
          throwsA(
            isA<Lz4CorruptDataException>().having(
              (e) => e.message,
              'message',
              contains('Invalid match distance'),
            ),
          ),
        );

        // Incomplete distance triggers rethrow of Lz4FormatException
        final truncatedDist = Uint8List.fromList([
          0x10, 0x41, // 1 literal
          0x01, // truncated distance (1 byte instead of 2)
        ]);
        expect(
          () => lz4BlockDecompressIntoBuffer(truncatedDist, Uint8List(10)),
          throwsA(
            isA<Lz4FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unexpected end of input'),
            ),
          ),
        );
      });
    });
  });

  group('LZ4 Sized Block Coverage Tests', () {
    test(
        'lz4CompressWithSize and lz4DecompressWithSize roundtrip and empty input',
        () {
      // Empty input
      final empty = Uint8List(0);
      final emptyComp = lz4CompressWithSize(empty);
      expect(emptyComp.length, equals(4)); // 4-byte header
      final emptyDecomp = lz4DecompressWithSize(emptyComp);
      expect(emptyDecomp, isEmpty);

      // Single byte
      final single = Uint8List.fromList([42]);
      final singleComp = lz4CompressWithSize(single);
      expect(lz4DecompressWithSize(singleComp), equals(single));

      // Normal roundtrip with acceleration
      final src = Uint8List.fromList(List.generate(200, (i) => (i * 7) % 256));
      final compAcc = lz4CompressWithSize(src, acceleration: 4);
      expect(lz4DecompressWithSize(compAcc), equals(src));
    });

    test(
        'lz4DecompressWithSize input shorter than 4 bytes throws Lz4FormatException',
        () {
      expect(
        () => lz4DecompressWithSize(Uint8List(0)),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Input too short for size header'),
          ),
        ),
      );
      expect(
        () => lz4DecompressWithSize(Uint8List(1)),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Input too short for size header'),
          ),
        ),
      );
      expect(
        () => lz4DecompressWithSize(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('Input too short for size header'),
          ),
        ),
      );
    });

    test('lz4DecompressWithSize maxDecompressedSize check (lines 50-53)', () {
      final src = Uint8List.fromList(List.generate(100, (i) => i));
      final compressed = lz4CompressWithSize(src);

      // maxDecompressedSize exceeded
      expect(
        () => lz4DecompressWithSize(compressed, maxDecompressedSize: 99),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maxDecompressedSize (99)'),
          ),
        ),
      );

      // Negative maxDecompressedSize
      expect(
        () => lz4DecompressWithSize(compressed, maxDecompressedSize: -1),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maxDecompressedSize (-1)'),
          ),
        ),
      );

      // Exact limit succeeds
      expect(
        lz4DecompressWithSize(compressed, maxDecompressedSize: 100),
        equals(src),
      );

      // Larger limit succeeds
      expect(
        lz4DecompressWithSize(compressed, maxDecompressedSize: 500),
        equals(src),
      );
    });

    test('lz4DecompressWithSize corrupt headers and payloads', () {
      // Header claims 100 bytes, but no payload follows
      final corruptTruncated = Uint8List.fromList([100, 0, 0, 0]);
      expect(
        () => lz4DecompressWithSize(corruptTruncated),
        throwsA(isA<Lz4FormatException>()),
      );

      // Header claims 10 bytes, but payload has invalid match distance
      final corruptPayload = Uint8List.fromList([
        10, 0, 0, 0, // 4-byte header: 10 bytes decompressed
        0x40, 1, 2, 3, 4, // 4 literals
        0x00, 0x00, // distance 0 (corrupt)
      ]);
      expect(
        () => lz4DecompressWithSize(corruptPayload),
        throwsA(isA<Lz4CorruptDataException>()),
      );

      // Header claims huge size 0xFFFFFFFF (> maxDecompressedSize limit)
      final hugeHeader = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
      expect(
        () => lz4DecompressWithSize(hugeHeader, maxDecompressedSize: 1024),
        throwsA(
          isA<Lz4FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maxDecompressedSize'),
          ),
        ),
      );
    });
  });

  group('LZ4 Block Encoder Coverage Tests', () {
    test('acceleration validation and edge cases', () {
      final input = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      // acceleration < 1 throws RangeError
      expect(
        () => PureDartLz4FastEngine(acceleration: 0),
        throwsRangeError,
      );
      expect(
        () => PureDartLz4FastEngine(acceleration: -1),
        throwsRangeError,
      );
      expect(
        () => lz4BlockCompress(input, acceleration: 0),
        throwsRangeError,
      );

      // Large acceleration values
      for (final acc in [1, 2, 8, 16, 30, 32, 64]) {
        final compressed = lz4BlockCompress(input, acceleration: acc);
        final decompressed =
            lz4Decompress(compressed, decompressedSize: input.length);
        expect(decompressed, equals(input));
      }
    });

    test('empty buffers, single byte, and sub-minMatch buffers (< 4 bytes)',
        () {
      // Empty buffer
      final empty = Uint8List(0);
      final emptyCompressed = lz4BlockCompress(empty);
      expect(emptyCompressed, isEmpty);
      expect(lz4Decompress(emptyCompressed, decompressedSize: 0), isEmpty);

      // Single byte
      final single = Uint8List.fromList([0x77]);
      final singleCompressed = lz4BlockCompress(single);
      expect(
        lz4Decompress(singleCompressed, decompressedSize: 1),
        equals(single),
      );

      // 2 bytes
      final twoBytes = Uint8List.fromList([0x12, 0x34]);
      final twoCompressed = lz4BlockCompress(twoBytes);
      expect(
        lz4Decompress(twoCompressed, decompressedSize: 2),
        equals(twoBytes),
      );

      // 3 bytes
      final threeBytes = Uint8List.fromList([0x12, 0x34, 0x56]);
      final threeCompressed = lz4BlockCompress(threeBytes);
      expect(
        lz4Decompress(threeCompressed, decompressedSize: 3),
        equals(threeBytes),
      );

      // Exactly 4 bytes (minMatch)
      final fourBytes = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
      final fourCompressed = lz4BlockCompress(fourBytes);
      expect(
        lz4Decompress(fourCompressed, decompressedSize: 4),
        equals(fourBytes),
      );
    });

    test('search limit boundaries (totalLength - 12)', () {
      for (var len = 5; len <= 20; len++) {
        final data =
            Uint8List.fromList(List.generate(len, (i) => (i * 3) & 0xff));
        final comp = lz4BlockCompress(data);
        final decomp = lz4Decompress(comp, decompressedSize: len);
        expect(decomp, equals(data));
      }
    });

    test('max history boundaries and distances > 0xFFFF', () {
      // Pattern at offset 0, repeated after 70000 bytes.
      // Distance is > 65535, so it cannot be encoded as a single match reference.
      const size = 70000;
      final largeData = Uint8List(size + 16);
      largeData[0] = 0xAA;
      largeData[1] = 0xBB;
      largeData[2] = 0xCC;
      largeData[3] = 0xDD;

      // Repeat at offset size
      largeData[size] = 0xAA;
      largeData[size + 1] = 0xBB;
      largeData[size + 2] = 0xCC;
      largeData[size + 3] = 0xDD;

      final compressed = lz4BlockCompress(largeData);
      final decompressed =
          lz4Decompress(compressed, decompressedSize: largeData.length);
      expect(decompressed, equals(largeData));

      // Match within 64KB history window (e.g. 50,000 bytes distance)
      const distWithin = 50000;
      final matchData = Uint8List(distWithin + 16);
      matchData.setRange(0, 8, [1, 2, 3, 4, 5, 6, 7, 8]);
      matchData.setRange(distWithin, distWithin + 8, [1, 2, 3, 4, 5, 6, 7, 8]);

      final compWithin = lz4BlockCompress(matchData);
      final decompWithin =
          lz4Decompress(compWithin, decompressedSize: matchData.length);
      expect(decompWithin, equals(matchData));
    });

    test('dictionary support in lz4BlockCompress and boundary conditions', () {
      // Empty dictionary
      final src = Uint8List.fromList([1, 2, 3, 4, 1, 2, 3, 4]);
      final compEmptyDict = lz4BlockCompress(src, dictionary: Uint8List(0));
      expect(compEmptyDict.isNotEmpty, isTrue);

      // Dictionary smaller than 64KB
      final smallDict = Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80]);
      final compSmallDict = lz4BlockCompress(src, dictionary: smallDict);
      expect(compSmallDict.isNotEmpty, isTrue);

      // Dictionary with input < 4 bytes
      final compSmallSrc = lz4BlockCompress(
        Uint8List.fromList([1, 2]),
        dictionary: smallDict,
      );
      expect(compSmallSrc.isNotEmpty, isTrue);

      // Dictionary exact boundary (64KB - 1 = 65535)
      const dictWindow = 64 * 1024 - 1;
      final exactDict = Uint8List(dictWindow);
      exactDict.setRange(0, 4, [1, 2, 3, 4]);
      final compExact = lz4BlockCompress(src, dictionary: exactDict);
      expect(compExact.isNotEmpty, isTrue);

      // Dictionary larger than history window (> 65535 bytes)
      // This exercises: dictFull.length > dictionaryWindow -> sublistView
      const largeDictSize = 70000;
      final largeDict = Uint8List(largeDictSize);
      largeDict
          .setRange(largeDictSize - 8, largeDictSize, [1, 2, 3, 4, 5, 6, 7, 8]);
      final compLargeDict = lz4BlockCompress(src, dictionary: largeDict);
      expect(compLargeDict.isNotEmpty, isTrue);
    });

    test(
        'sequences with long literal length (>= 15) and long match length (>= 19) (lines 197, 207)',
        () {
      // Pattern at start: 8 bytes
      // Followed by 20 non-matching literals (literal length >= 15)
      // Followed by 25 repeating bytes that match the start (match length >= 19)
      // Followed by trailing literals
      final input = Uint8List.fromList([
        1, 2, 3, 4, 5, 6, 7, 8,
        ...List.generate(20, (i) => 100 + i), // 20 literals >= 15
        1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
        1, // 25 match bytes
        90, 91, 92, 93, 94, // trailing literals
      ]);

      final compressed = lz4BlockCompress(input);
      expect(compressed.isNotEmpty, isTrue);

      final decompressed =
          lz4BlockDecompress(compressed, decompressedSize: input.length);
      expect(decompressed, equals(input));

      // Also decompress into buffer
      final dst = Uint8List(input.length);
      final written = lz4BlockDecompressIntoBuffer(compressed, dst);
      expect(written, equals(input.length));
      expect(dst, equals(input));
    });
  });
}
