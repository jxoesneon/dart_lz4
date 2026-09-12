import 'dart:typed_data';

import 'package:dart_lz4/src/frame/lz4_frame_options.dart';
import 'package:dart_lz4/src/hc/lz4_hc_options.dart';
import 'package:dart_lz4/src/internal/byte_reader.dart';
import 'package:dart_lz4/src/internal/byte_writer.dart';
import 'package:dart_lz4/src/internal/lz4_buffer_pool.dart';
import 'package:dart_lz4/src/internal/lz4_exception.dart';
import 'package:test/test.dart';

void main() {
  group('1. Lz4HcOptions coverage', () {
    test('instantiates and verifies every Lz4HcLevel (levels 1 through 12)',
        () {
      final expectedDepths = <Lz4HcLevel, int>{
        Lz4HcLevel.level1: 1,
        Lz4HcLevel.level2: 1,
        Lz4HcLevel.level3: 2,
        Lz4HcLevel.level4: 4,
        Lz4HcLevel.level5: 8,
        Lz4HcLevel.level6: 16,
        Lz4HcLevel.level7: 32,
        Lz4HcLevel.level8: 64,
        Lz4HcLevel.level9: 128,
        Lz4HcLevel.level10: 256,
        Lz4HcLevel.level11: 512,
        Lz4HcLevel.level12: 1024,
      };

      expect(Lz4HcLevel.values.length, 12);

      for (final level in Lz4HcLevel.values) {
        final options = Lz4HcOptions(level: level);
        expect(options.level, equals(level));
        expect(options.effectiveSearchDepth, equals(expectedDepths[level]));
      }
    });

    test('effectiveSearchDepth falls back to maxSearchDepth when level is null',
        () {
      final defaultOptions = Lz4HcOptions();
      expect(defaultOptions.level, isNull);
      expect(defaultOptions.maxSearchDepth, 64);
      expect(defaultOptions.effectiveSearchDepth, 64);

      final customOptions = Lz4HcOptions(maxSearchDepth: 128);
      expect(customOptions.level, isNull);
      expect(customOptions.maxSearchDepth, 128);
      expect(customOptions.effectiveSearchDepth, 128);
    });

    test('throws RangeError when maxSearchDepth < 1', () {
      expect(() => Lz4HcOptions(maxSearchDepth: 0), throwsRangeError);
      expect(() => Lz4HcOptions(maxSearchDepth: -1), throwsRangeError);
    });
  });

  group('2. ByteReader coverage', () {
    test('constructor bounds checks on offset (negative and out-of-bounds)',
        () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      // Negative offset
      expect(() => ByteReader(bytes, offset: -1), throwsRangeError);

      // Offset beyond buffer length
      expect(() => ByteReader(bytes, offset: 5), throwsRangeError);

      // Valid boundary offsets
      final atStart = ByteReader(bytes, offset: 0);
      expect(atStart.offset, 0);
      expect(atStart.length, 4);
      expect(atStart.remaining, 4);
      expect(atStart.isEOF, isFalse);

      final atEnd = ByteReader(bytes, offset: 4);
      expect(atEnd.offset, 4);
      expect(atEnd.remaining, 0);
      expect(atEnd.isEOF, isTrue);
    });

    test('skip negative and out-of-bounds', () {
      final bytes = Uint8List.fromList([10, 20, 30]);
      final reader = ByteReader(bytes);

      // Negative count throws RangeError
      expect(() => reader.skip(-1), throwsRangeError);

      // Skip past end throws Lz4FormatException
      expect(() => reader.skip(4), throwsA(isA<Lz4FormatException>()));

      // Valid skip
      reader.skip(2);
      expect(reader.offset, 2);
      expect(reader.readUint8(), 30);
      expect(reader.isEOF, isTrue);
    });

    test('readBytesView bounds checks', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final reader = ByteReader(bytes);

      // Negative count throws RangeError
      expect(() => reader.readBytesView(-1), throwsRangeError);

      // Count exceeding remaining throws Lz4FormatException
      expect(() => reader.readBytesView(6), throwsA(isA<Lz4FormatException>()));

      // Valid readBytesView
      final view = reader.readBytesView(3);
      expect(view, [1, 2, 3]);
      expect(reader.offset, 3);
      expect(reader.remaining, 2);
    });

    test('peekUint8 bounds checks', () {
      final bytes = Uint8List.fromList([0xAA, 0xBB]);
      final reader = ByteReader(bytes);

      // Negative lookahead throws RangeError
      expect(() => reader.peekUint8(-1), throwsRangeError);

      // Lookahead beyond remaining throws Lz4FormatException
      expect(() => reader.peekUint8(2), throwsA(isA<Lz4FormatException>()));

      // Valid peek
      expect(reader.peekUint8(0), 0xAA);
      expect(reader.peekUint8(1), 0xBB);
      expect(reader.offset, 0);

      // When reader is at EOF, peek throws Lz4FormatException
      reader.skip(2);
      expect(reader.isEOF, isTrue);
      expect(() => reader.peekUint8(), throwsA(isA<Lz4FormatException>()));
    });

    test('readUint32LE and other reads at boundary', () {
      // 0 bytes available
      final emptyReader = ByteReader(Uint8List(0));
      expect(
          () => emptyReader.readUint32LE(), throwsA(isA<Lz4FormatException>()));

      // 3 bytes available - insufficient for 32-bit LE read
      final shortBytes = Uint8List.fromList([1, 2, 3]);
      final shortReader = ByteReader(shortBytes);
      expect(
          () => shortReader.readUint32LE(), throwsA(isA<Lz4FormatException>()));

      // Exactly 4 bytes available - succeeds
      final exactBytes = Uint8List.fromList([0x78, 0x56, 0x34, 0x12]);
      final exactReader = ByteReader(exactBytes);
      expect(exactReader.readUint32LE(), 0x12345678);
      expect(exactReader.isEOF, isTrue);

      // After EOF, subsequent readUint8 throws
      expect(() => exactReader.readUint8(), throwsA(isA<Lz4FormatException>()));

      // 1 byte available - insufficient for 16-bit LE read
      final singleByteReader = ByteReader(Uint8List.fromList([1]));
      expect(() => singleByteReader.readUint16LE(),
          throwsA(isA<Lz4FormatException>()));
    });

    test('readUint64LE bounds and overflow check', () {
      // Less than 8 bytes throws Lz4FormatException
      final shortReader = ByteReader(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]));
      expect(
          () => shortReader.readUint64LE(), throwsA(isA<Lz4FormatException>()));

      // Valid 64-bit int read
      final validBytes = Uint8List.fromList([
        0x01, 0x00, 0x00, 0x00, // low = 1
        0x02, 0x00, 0x00, 0x00, // high = 2 -> (2 * 2^32) + 1 = 8589934593
      ]);
      final reader = ByteReader(validBytes);
      expect(reader.readUint64LE(), 8589934593);

      // High bit set causes overflow (negative in signed 64-bit VM int)
      final overflowBytes = Uint8List.fromList([
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
      ]);
      final overflowReader = ByteReader(overflowBytes);
      expect(() => overflowReader.readUint64LE(),
          throwsA(isA<Lz4FormatException>()));
    });
  });

  group('3. ByteWriter coverage', () {
    test(
        'validates negative initialCapacity, maxLength, blockStartOffset in default constructor',
        () {
      expect(() => ByteWriter(initialCapacity: -1), throwsRangeError);
      expect(() => ByteWriter(maxLength: -1), throwsRangeError);
      expect(() => ByteWriter(blockStartOffset: -1), throwsRangeError);
    });

    test('validates ByteWriter.forBuffer bounds and negative maxLength', () {
      final buf = Uint8List(8);

      expect(() => ByteWriter.forBuffer(buf, offset: -1), throwsRangeError);
      expect(() => ByteWriter.forBuffer(buf, offset: 9), throwsRangeError);
      expect(() => ByteWriter.forBuffer(buf, maxLength: -1), throwsRangeError);

      final valid = ByteWriter.forBuffer(buf, offset: 4, maxLength: 8);
      expect(valid.isFixed, isTrue);
      expect(valid.length, 4);
      expect(valid.blockStartOffset, 4);
      expect(valid.remainingCapacity, 4);
    });

    test(
        'blockStartOffset getter and setter with valid and out-of-range values',
        () {
      final writer = ByteWriter();
      expect(writer.blockStartOffset, 0);

      writer.writeBytes(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(writer.length, 5);

      // Valid setter
      writer.blockStartOffset = 3;
      expect(writer.blockStartOffset, 3);

      // Negative throws RangeError
      expect(() => writer.blockStartOffset = -1, throwsRangeError);

      // Greater than length throws RangeError
      expect(() => writer.blockStartOffset = 6, throwsRangeError);
    });

    test('length setter bounds checks', () {
      final writer = ByteWriter(initialCapacity: 10);
      expect(writer.length, 0);

      // Valid
      writer.length = 5;
      expect(writer.length, 5);

      // Negative
      expect(() => writer.length = -1, throwsRangeError);

      // Greater than buffer capacity
      expect(() => writer.length = 11, throwsRangeError);
    });

    test('clear() resets length properly for regular and fixed ByteWriter', () {
      // Regular ByteWriter resets length to 0
      final writer = ByteWriter(blockStartOffset: 2);
      writer.writeBytes(Uint8List.fromList([1, 2, 3]));
      expect(writer.length, 3);
      writer.clear();
      expect(writer.length, 0);

      // Fixed ByteWriter resets length to blockStartOffset
      final buf = Uint8List(10);
      final fixedWriter = ByteWriter.forBuffer(buf, offset: 4);
      expect(fixedWriter.length, 4);
      fixedWriter.writeBytes(Uint8List.fromList([9, 8]));
      expect(fixedWriter.length, 6);
      fixedWriter.clear();
      expect(fixedWriter.length, 4);
    });

    test('writeUint32LEAt at valid and out-of-range indices', () {
      final writer = ByteWriter();
      writer.writeBytes(Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]));

      // Valid write at index 0
      writer.writeUint32LEAt(0, 0x12345678);
      expect(writer.toBytes().sublist(0, 4), [0x78, 0x56, 0x34, 0x12]);

      // Valid write at index 4
      writer.writeUint32LEAt(4, 0xAABBCCDD);
      expect(writer.toBytes().sublist(4, 8), [0xDD, 0xCC, 0xBB, 0xAA]);

      // Negative index
      expect(() => writer.writeUint32LEAt(-1, 0x12345678), throwsRangeError);

      // Out of range index where index + 4 > length
      expect(() => writer.writeUint32LEAt(5, 0x12345678), throwsRangeError);
      expect(() => writer.writeUint32LEAt(8, 0x12345678), throwsRangeError);
      expect(() => writer.writeUint32LEAt(100, 0x12345678), throwsRangeError);
    });

    test('writeRepeatedByte validation and execution', () {
      final writer = ByteWriter();

      // Negative count throws RangeError
      expect(() => writer.writeRepeatedByte(0x55, -1), throwsRangeError);

      // Count 0 does nothing
      writer.writeRepeatedByte(0x55, 0);
      expect(writer.length, 0);

      // Count > 0 writes repeated bytes
      writer.writeRepeatedByte(0x55, 3);
      expect(writer.toBytes(), [0x55, 0x55, 0x55]);
    });

    test('writeBytesView validation', () {
      final writer = ByteWriter();
      final data = Uint8List.fromList([1, 2, 3, 4]);

      expect(() => writer.writeBytesView(data, -1, 2), throwsRangeError);
      expect(() => writer.writeBytesView(data, 3, 2), throwsRangeError);
      expect(() => writer.writeBytesView(data, 0, 5), throwsRangeError);

      writer.writeBytesView(data, 1, 3);
      expect(writer.toBytes(), [2, 3]);
    });

    test('copyMatch validation and operations', () {
      final writer = ByteWriter();
      writer.writeBytes(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));

      // Negative matchLength throws RangeError
      expect(() => writer.copyMatch(1, -1), throwsRangeError);

      // matchLength 0 returns normally without modifying buffer
      writer.copyMatch(1, 0);
      expect(writer.length, 8);

      // Invalid explicit blockStartOffset
      expect(() => writer.copyMatch(1, 1, -1), throwsRangeError);
      expect(() => writer.copyMatch(1, 1, 9), throwsRangeError);

      // Invalid distance <= 0
      expect(() => writer.copyMatch(0, 2),
          throwsA(isA<Lz4CorruptDataException>()));
      expect(() => writer.copyMatch(-1, 2),
          throwsA(isA<Lz4CorruptDataException>()));

      // Invalid distance > length - start
      expect(() => writer.copyMatch(9, 2),
          throwsA(isA<Lz4CorruptDataException>()));

      // Multi-byte wildcopy with distance >= 8 and matchLength >= 8
      writer.copyMatch(8, 16);
      expect(writer.length, 24);
      expect(writer.toBytes(), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
    });

    test('buffer pool release() on ByteWriter', () {
      final pool = SimpleLz4BufferPool();
      final writer = ByteWriter(initialCapacity: 128, bufferPool: pool);
      writer.writeBytes(Uint8List.fromList([1, 2, 3]));
      expect(writer.length, 3);

      writer.release();
      expect(writer.length, 0);
      expect(pool.totalCachedBuffers, 1);

      // ByteWriter without pool release is safe no-op
      final noPoolWriter = ByteWriter(initialCapacity: 64);
      noPoolWriter.release();
      expect(noPoolWriter.length, 0);
    });

    test('capacity expansion with and without pool', () {
      final pool = SimpleLz4BufferPool();
      // Starts with 0 capacity, forces multiple doubling loops in _ensureCapacity
      final writer = ByteWriter(initialCapacity: 0, bufferPool: pool);
      final payload = Uint8List(500);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xff;
      }
      writer.writeBytes(payload);
      expect(writer.length, 500);
      expect(writer.bytesView().length, 500);
      expect(writer.toBytes(), payload);

      writer.release();
      expect(pool.totalCachedBuffers, 1);
    });

    test('fixed ByteWriter and non-fixed maxLength enforcement', () {
      final buffer = Uint8List(10);
      final writer = ByteWriter.forBuffer(buffer, maxLength: 4);
      writer.writeBytes(Uint8List.fromList([1, 2, 3, 4]));
      expect(
          () => writer.writeUint8(5), throwsA(isA<Lz4OutputLimitException>()));

      // Non-fixed ByteWriter output limit exceeded
      final unfixed = ByteWriter(maxLength: 4);
      unfixed.writeBytes(Uint8List.fromList([1, 2, 3, 4]));
      expect(
          () => unfixed.writeUint8(5), throwsA(isA<Lz4OutputLimitException>()));
    });
  });

  group('4. Lz4BufferPool coverage', () {
    test('validates negative constructor arguments in SimpleLz4BufferPool', () {
      expect(() => SimpleLz4BufferPool(maxBuffers: -1), throwsRangeError);
      expect(
          () => SimpleLz4BufferPool(maxBuffersPerBucket: -1), throwsRangeError);
      expect(() => SimpleLz4BufferPool(maxTotalBuffers: -1), throwsRangeError);
      expect(
          () => SimpleLz4BufferPool(maxBufferSizeBytes: -1), throwsRangeError);
    });

    test('validates negative constructor arguments in SecureLz4BufferPool', () {
      expect(() => SecureLz4BufferPool(maxBuffers: -1), throwsRangeError);
      expect(
          () => SecureLz4BufferPool(maxBuffersPerBucket: -1), throwsRangeError);
      expect(() => SecureLz4BufferPool(maxTotalBuffers: -1), throwsRangeError);
      expect(
          () => SecureLz4BufferPool(maxBufferSizeBytes: -1), throwsRangeError);
    });

    test('checkout with negative size throws RangeError', () {
      final pool = SimpleLz4BufferPool();
      expect(() => pool.checkout(-1), throwsRangeError);

      final securePool = SecureLz4BufferPool();
      expect(() => securePool.checkout(-1), throwsRangeError);
    });

    test('checkout with size 0 returns empty Uint8List', () {
      final pool = SimpleLz4BufferPool();
      final buf = pool.checkout(0);
      expect(buf.length, 0);
      // checkin empty buffer is ignored
      pool.checkin(buf);
      expect(pool.totalCachedBuffers, 0);
    });

    test(
        'checkout when slabSize > maxBufferSizeBytes returns unpooled buffer of exact size',
        () {
      // Set maxBufferSizeBytes to 1000.
      // For size 700: 700 <= 1000, but next power of 2 is 1024 > 1000.
      // This reaches line 139: return Uint8List(size).
      final pool = SimpleLz4BufferPool(maxBufferSizeBytes: 1000);
      final buf = pool.checkout(700);
      expect(buf.length, 700);

      // Checkout size exceeding maxBufferSizeBytes directly
      final hugeBuf = pool.checkout(2000);
      expect(hugeBuf.length, 2000);
      // Checkin buffer exceeding maxBufferSizeBytes is ignored
      pool.checkin(hugeBuf);
      expect(pool.totalCachedBuffers, 0);
    });

    test('maxTotalBuffers reached during checkin drops subsequent buffers', () {
      final pool = SimpleLz4BufferPool(maxTotalBuffers: 2);
      final b1 = pool.checkout(64);
      final b2 = pool.checkout(128);
      final b3 = pool.checkout(256);

      pool.checkin(b1);
      pool.checkin(b2);
      expect(pool.totalCachedBuffers, 2);

      // Checkin b3 when maxTotalBuffers (2) is reached; should be rejected
      pool.checkin(b3);
      expect(pool.totalCachedBuffers, 2);
    });

    test('maxBuffersPerBucket reached during checkin drops subsequent buffers',
        () {
      final pool = SimpleLz4BufferPool(maxBuffersPerBucket: 1);
      final b1 = pool.checkout(64);
      final b2 = Uint8List(64);

      pool.checkin(b1);
      expect(pool.pooledBuffersForSize(64), 1);

      // Exceeds maxBuffersPerBucket (1), should be rejected
      pool.checkin(b2);
      expect(pool.pooledBuffersForSize(64), 1);
      expect(pool.totalCachedBuffers, 1);

      // Duplicate checkin of same instance is also rejected
      pool.checkin(b1);
      expect(pool.pooledBuffersForSize(64), 1);
    });

    test('clear() empties all buckets and resets totalCachedBuffers', () {
      final pool = SimpleLz4BufferPool();
      final b1 = pool.checkout(64);
      final b2 = pool.checkout(128);
      pool.checkin(b1);
      pool.checkin(b2);

      expect(pool.totalCachedBuffers, 2);
      expect(pool.pooledBuffersForSize(64), 1);
      expect(pool.pooledBuffersForSize(128), 1);

      pool.clear();
      expect(pool.totalCachedBuffers, 0);
      expect(pool.pooledBuffersForSize(64), 0);
      expect(pool.pooledBuffersForSize(128), 0);
    });

    test('pooledBuffersForSize and totalCachedBuffers getters', () {
      final pool = SimpleLz4BufferPool(maxBuffers: 8);
      expect(pool.maxBuffers, 8);
      expect(pool.maxBuffersPerBucket, 8);
      expect(pool.totalCachedBuffers, 0);
      expect(pool.pooledBuffersForSize(256), 0);

      final b1 = pool.checkout(256);
      final b2 = pool.checkout(256);
      pool.checkin(b1);
      pool.checkin(b2);

      expect(pool.totalCachedBuffers, 2);
      expect(pool.pooledBuffersForSize(256), 2);
      expect(pool.pooledBuffersForSize(512), 0);
    });

    test('checkout intermediate bucket reuse', () {
      final pool = SimpleLz4BufferPool();
      // Directly check in an intermediate size buffer (e.g. 100 bytes)
      final customBuffer = Uint8List(100);
      pool.checkin(customBuffer);
      expect(pool.pooledBuffersForSize(100), 1);

      // Requesting 80 bytes: next power of 2 is 128.
      // The 100-byte buffer satisfies 80 <= 100 <= 128 and is reused.
      final recycled = pool.checkout(80);
      expect(identical(recycled, customBuffer), isTrue);
      expect(pool.totalCachedBuffers, 0);
    });
  });

  group('5. Lz4FrameOptions coverage', () {
    test('validates acceleration < 1', () {
      expect(() => Lz4FrameOptions(acceleration: 0), throwsRangeError);
      expect(() => Lz4FrameOptions(acceleration: -1), throwsRangeError);
      expect(() => Lz4FrameOptions(acceleration: 1), returnsNormally);
      expect(() => Lz4FrameOptions(acceleration: 5), returnsNormally);
    });

    test('validates contentSize < 0', () {
      expect(() => Lz4FrameOptions(contentSize: -1), throwsRangeError);
      expect(() => Lz4FrameOptions(contentSize: 0), returnsNormally);
      expect(() => Lz4FrameOptions(contentSize: 1024), returnsNormally);
    });

    test('validates dictId < 0 and dictId > 0xFFFFFFFF', () {
      expect(() => Lz4FrameOptions(dictId: -1), throwsRangeError);
      expect(() => Lz4FrameOptions(dictId: 0x100000000), throwsRangeError);
      expect(() => Lz4FrameOptions(dictId: 0), returnsNormally);
      expect(() => Lz4FrameOptions(dictId: 0xFFFFFFFF), returnsNormally);
    });

    test('Lz4FrameBlockSize extensions bdId and maxBytes', () {
      expect(Lz4FrameBlockSize.k64KB.bdId, 4);
      expect(Lz4FrameBlockSize.k64KB.maxBytes, 64 * 1024);

      expect(Lz4FrameBlockSize.k256KB.bdId, 5);
      expect(Lz4FrameBlockSize.k256KB.maxBytes, 256 * 1024);

      expect(Lz4FrameBlockSize.k1MB.bdId, 6);
      expect(Lz4FrameBlockSize.k1MB.maxBytes, 1024 * 1024);

      expect(Lz4FrameBlockSize.k4MB.bdId, 7);
      expect(Lz4FrameBlockSize.k4MB.maxBytes, 4 * 1024 * 1024);
    });

    test('Lz4FrameOptions all properties instantiation', () {
      final pool = SimpleLz4BufferPool();
      final hcOpts = Lz4HcOptions(level: Lz4HcLevel.level12);
      final options = Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k1MB,
        blockIndependence: false,
        blockChecksum: true,
        contentChecksum: true,
        contentSize: 12345,
        dictId: 0x12345678,
        compression: Lz4FrameCompression.hc,
        acceleration: 2,
        hcOptions: hcOpts,
        bufferPool: pool,
      );

      expect(options.blockSize, Lz4FrameBlockSize.k1MB);
      expect(options.blockIndependence, isFalse);
      expect(options.blockChecksum, isTrue);
      expect(options.contentChecksum, isTrue);
      expect(options.contentSize, 12345);
      expect(options.dictId, 0x12345678);
      expect(options.compression, Lz4FrameCompression.hc);
      expect(options.acceleration, 2);
      expect(options.hcOptions, same(hcOpts));
      expect(options.bufferPool, same(pool));
    });
  });
}
