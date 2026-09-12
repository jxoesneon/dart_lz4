import 'dart:async';
import 'dart:typed_data';

import 'package:dart_lz4/dart_lz4.dart';
import 'package:dart_lz4/src/frame/lz4_frame_decoder.dart';
import 'package:dart_lz4/src/frame/lz4_frame_stream_decoder.dart';
import 'package:test/test.dart';

void main() {
  group('SimpleLz4BufferPool', () {
    test('checkout, checkin, and reuse verified', () {
      final pool = SimpleLz4BufferPool(maxBuffers: 4);

      // 1. Checkout buffer of at least 1024 bytes
      final b1 = pool.checkout(1024);
      expect(b1.length, greaterThanOrEqualTo(1024));

      // Mark buffer with a signature pattern
      b1[0] = 0x42;
      b1[100] = 0x99;

      // 2. Checkin buffer
      pool.checkin(b1);
      expect(pool.totalCachedBuffers, equals(1));

      // 3. Checkout buffer of same size - should reuse b1 without clearing
      final b2 = pool.checkout(1024);
      expect(b2.length, equals(b1.length));
      expect(identical(b2, b1), isTrue);
      // Verify SimpleLz4BufferPool does not zero out (performance-optimized)
      expect(b2[0], equals(0x42));
      expect(b2[100], equals(0x99));
      expect(pool.totalCachedBuffers, equals(0));
    });

    test('slab bucketing with power-of-two tiers', () {
      final pool = SimpleLz4BufferPool();

      // Allocate slabs of different power-of-two sizes: 64KB, 256KB, 1MB
      final buf64k = pool.checkout(64 * 1024);
      final buf256k = pool.checkout(256 * 1024);
      final buf1m = pool.checkout(1024 * 1024);

      expect(buf64k.length, equals(64 * 1024));
      expect(buf256k.length, equals(256 * 1024));
      expect(buf1m.length, equals(1024 * 1024));

      // Check all back into the pool
      pool.checkin(buf64k);
      pool.checkin(buf256k);
      pool.checkin(buf1m);

      expect(pool.totalCachedBuffers, equals(3));
      expect(pool.pooledBuffersForSize(64 * 1024), equals(1));
      expect(pool.pooledBuffersForSize(256 * 1024), equals(1));
      expect(pool.pooledBuffersForSize(1024 * 1024), equals(1));

      // Re-checkout: should hit matching power-of-two slab buckets
      final reused64k = pool.checkout(64 * 1024);
      expect(identical(reused64k, buf64k), isTrue);

      final reused256k = pool.checkout(200 * 1024); // fits in 256KB slab
      expect(identical(reused256k, buf256k), isTrue);

      final reused1m = pool.checkout(1024 * 1024);
      expect(identical(reused1m, buf1m), isTrue);
    });

    test('capacity limits: maxBuffersPerBucket drops excess buffers', () {
      final pool = SimpleLz4BufferPool(maxBuffers: 2);

      final b1 = pool.checkout(512);
      final b2 = pool.checkout(512);
      final b3 = pool.checkout(512);

      pool.checkin(b1);
      pool.checkin(b2);
      expect(pool.totalCachedBuffers, equals(2));

      // 3rd buffer exceeds maxBuffers (2) for this bucket, so it should be dropped
      pool.checkin(b3);
      expect(pool.totalCachedBuffers, equals(2));

      // Duplicate checkin of the same buffer is prevented
      pool.checkin(b1);
      expect(pool.totalCachedBuffers, equals(2));
    });

    test('capacity limits: maxTotalBuffers caps total pooled memory', () {
      final pool = SimpleLz4BufferPool(maxBuffers: 5, maxTotalBuffers: 3);

      final b1 = pool.checkout(64);
      final b2 = pool.checkout(128);
      final b3 = pool.checkout(256);
      final b4 = pool.checkout(512);

      pool.checkin(b1);
      pool.checkin(b2);
      pool.checkin(b3);
      expect(pool.totalCachedBuffers, equals(3));

      // Exceeds total pool limit of 3
      pool.checkin(b4);
      expect(pool.totalCachedBuffers, equals(3));
    });

    test('decompression-bomb defense: maxBufferSizeBytes rejects huge buffers',
        () {
      const maxAllowed = 1024 * 1024; // 1 MB limit
      final pool = SimpleLz4BufferPool(maxBufferSizeBytes: maxAllowed);

      // Buffer under limit
      final validBuf = pool.checkout(512 * 1024);
      pool.checkin(validBuf);
      expect(pool.totalCachedBuffers, equals(1));

      // Buffer exceeding limit (e.g. 2 MB)
      final hugeBuf = Uint8List(2 * 1024 * 1024);
      pool.checkin(hugeBuf);
      // Rejected: not added to pool
      expect(pool.totalCachedBuffers, equals(1));

      // Checkout larger than maxBufferSizeBytes allocates fresh without caching
      final freshHuge = pool.checkout(2 * 1024 * 1024);
      expect(freshHuge.length, equals(2 * 1024 * 1024));
    });

    test('edge cases: size 0 and clear()', () {
      final pool = SimpleLz4BufferPool();
      final empty = pool.checkout(0);
      expect(empty.length, equals(0));
      pool.checkin(empty);
      expect(pool.totalCachedBuffers, equals(0));

      final buf = pool.checkout(128);
      pool.checkin(buf);
      expect(pool.totalCachedBuffers, equals(1));
      pool.clear();
      expect(pool.totalCachedBuffers, equals(0));
    });
  });

  group('SecureLz4BufferPool', () {
    test('CWE-226: zeroes out buffers on checkin completely', () {
      final pool = SecureLz4BufferPool();

      // Checkout a buffer and fill it with sensitive pattern (0xFF)
      final buf1 = pool.checkout(4096);
      buf1.fillRange(0, buf1.length, 0xFF);
      expect(buf1.every((b) => b == 0xFF), isTrue);

      // Check it in
      pool.checkin(buf1);

      // Verify buf1 was zeroed in-place immediately upon checkin
      for (var i = 0; i < buf1.length; i++) {
        if (buf1[i] != 0) {
          fail('Buffer was not sanitized at index $i (value: ${buf1[i]})');
        }
      }

      // Checkout same size from pool
      final buf2 = pool.checkout(4096);
      expect(identical(buf2, buf1), isTrue);
      expect(buf2.every((b) => b == 0), isTrue,
          reason: 'Checked out buffer must be pristine zeroes');
    });

    test('CWE-226: zeroing occurs even if buffer is rejected due to size cap',
        () {
      const maxAllowed = 256;
      final pool = SecureLz4BufferPool(maxBufferSizeBytes: maxAllowed);

      // Buffer larger than maxAllowed
      final sensitiveOversized = Uint8List(512);
      sensitiveOversized.fillRange(0, sensitiveOversized.length, 0xDE);

      pool.checkin(sensitiveOversized);

      // Buffer must be scrubbed before being released to GC
      expect(sensitiveOversized.every((b) => b == 0), isTrue,
          reason: 'Oversized buffer must be zeroed before GC disposal');
      // And not retained in pool
      expect(pool.totalCachedBuffers, equals(0));
    });

    test('multiple checkouts and checkins with diverse dirty patterns', () {
      final pool = SecureLz4BufferPool(maxBuffers: 4);

      final b1 = pool.checkout(128);
      final b2 = pool.checkout(128);
      final b3 = pool.checkout(128);

      b1.fillRange(0, b1.length, 0xAA);
      b2.fillRange(0, b2.length, 0x55);
      b3.fillRange(0, b3.length, 0x7F);

      pool.checkin(b1);
      pool.checkin(b2);
      pool.checkin(b3);

      expect(b1.every((b) => b == 0), isTrue);
      expect(b2.every((b) => b == 0), isTrue);
      expect(b3.every((b) => b == 0), isTrue);

      // Re-checkout all 3
      final r1 = pool.checkout(128);
      final r2 = pool.checkout(128);
      final r3 = pool.checkout(128);

      expect(r1.every((b) => b == 0), isTrue);
      expect(r2.every((b) => b == 0), isTrue);
      expect(r3.every((b) => b == 0), isTrue);
    });
  });

  group('Streaming Frame Encode & Decode with Buffer Pools', () {
    test('round-trip streaming with SimpleLz4BufferPool', () async {
      final pool = SimpleLz4BufferPool();

      // Generate 128 KB of patterned test data
      final payload = Uint8List(128 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i * 31 + 7) & 0xFF;
      }

      // Stream encode using buffer pool
      final options = Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        bufferPool: pool,
      );

      final inputStream = Stream<List<int>>.fromIterable([
        payload.sublist(0, 32 * 1024),
        payload.sublist(32 * 1024, 64 * 1024),
        payload.sublist(64 * 1024, 96 * 1024),
        payload.sublist(96 * 1024),
      ]);

      final compressedChunks = await inputStream
          .transform(lz4FrameEncoderWithOptions(options: options))
          .toList();

      final totalCompressedBytes =
          compressedChunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      expect(totalCompressedBytes, greaterThan(0));

      // Stream decode using transformer with bufferPool
      final compressedStream = Stream<List<int>>.fromIterable(compressedChunks);
      final decompressedChunks = await compressedStream
          .transform(lz4FrameDecoderTransformer(bufferPool: pool))
          .toList();

      final decompressedBuilder = BytesBuilder(copy: false);
      for (final chunk in decompressedChunks) {
        decompressedBuilder.add(chunk);
      }
      final result = decompressedBuilder.takeBytes();

      expect(result, equals(payload));
      expect(pool.totalCachedBuffers, greaterThan(0),
          reason: 'Buffers should be recycled and returned to pool');
    });

    test('round-trip streaming with SecureLz4BufferPool', () async {
      final pool = SecureLz4BufferPool();

      // Generate 96 KB of test data
      final payload = Uint8List(96 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i ^ 0xA5) & 0xFF;
      }

      final options = Lz4FrameOptions(
        blockSize: Lz4FrameBlockSize.k64KB,
        contentChecksum: true,
        bufferPool: pool,
      );

      final compressedChunks = await Stream<List<int>>.value(payload)
          .transform(lz4FrameEncoderWithOptions(options: options))
          .toList();

      final decompressedChunks =
          await Stream<List<int>>.fromIterable(compressedChunks)
              .transform(lz4FrameDecoderTransformer(bufferPool: pool))
              .toList();

      final decompressedBuilder = BytesBuilder(copy: false);
      for (final chunk in decompressedChunks) {
        decompressedBuilder.add(chunk);
      }
      final result = decompressedBuilder.takeBytes();

      expect(result, equals(payload));
      expect(pool.totalCachedBuffers, greaterThan(0));
    });

    test('synchronous frame decode with buffer pool', () {
      final simplePool = SimpleLz4BufferPool();
      final securePool = SecureLz4BufferPool();

      final input = Uint8List.fromList(
          List.generate(5000, (i) => 'Hello LZ4 buffer pooling $i\n'.codeUnits)
              .expand((x) => x)
              .toList());

      final encoded = lz4FrameEncode(input);

      // Decode with SimpleLz4BufferPool
      final decoded1 = lz4FrameDecodeBytes(encoded, bufferPool: simplePool);
      expect(decoded1, equals(input));
      expect(simplePool.totalCachedBuffers, greaterThanOrEqualTo(1));

      // Decode with SecureLz4BufferPool
      final decoded2 = lz4FrameDecodeBytes(encoded, bufferPool: securePool);
      expect(decoded2, equals(input));
      expect(securePool.totalCachedBuffers, greaterThanOrEqualTo(1));
    });
  });
}
