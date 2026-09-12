import 'dart:typed_data';

/// Interface for buffer pooling to reduce allocations and garbage collection overhead.
///
/// Implementations provide reusable byte buffers for compression and decompression
/// pipelines, such as `ByteWriter` and block decoders.
abstract interface class Lz4BufferPool {
  /// Checks out a [Uint8List] of at least [size] bytes.
  ///
  /// If an idle buffer of matching capacity is available in the pool, it is
  /// recycled and returned. Otherwise, a new buffer is allocated.
  ///
  /// Callers should return the buffer via [checkin] when finished to make it
  /// eligible for subsequent checkouts.
  Uint8List checkout(int size);

  /// Checks in a [buffer] for future reuse.
  ///
  /// Depending on the pool configuration and implementation, the buffer may be
  /// retained in an internal bucket or rejected (e.g. if the pool is full or if
  /// the buffer exceeds the maximum cacheable size).
  void checkin(Uint8List buffer);
}

/// Internal base class providing power-of-two slab bucketing and bounded capacity.
abstract class _BaseLz4BufferPool implements Lz4BufferPool {
  /// Default maximum buffer size eligible for pooling (8 MiB).
  ///
  /// LZ4 block sizes range up to 4 MiB for standard frames and 8 MiB for legacy frames.
  /// Caching buffers larger than 8 MiB is rejected by default to prevent
  /// memory exhaustion attacks (decompression bombs).
  static const int defaultMaxBufferSizeBytes = 8 * 1024 * 1024;

  /// Default maximum number of buffers retained per size bucket.
  static const int defaultMaxBuffersPerBucket = 16;

  /// Minimum power-of-two slab size (64 bytes).
  static const int _minSlabSize = 64;

  final Map<int, List<Uint8List>> _buckets = {};
  int _totalBuffers = 0;

  /// Maximum number of buffers allowed per bucket.
  final int maxBuffersPerBucket;

  /// Optional maximum total number of buffers allowed across all buckets.
  final int? maxTotalBuffers;

  /// Maximum size in bytes of a buffer that will be cached in the pool.
  ///
  /// Buffers exceeding this size are rejected on [checkin] to prevent
  /// caching decompression-bomb-sized buffers.
  final int maxBufferSizeBytes;

  _BaseLz4BufferPool({
    int maxBuffers = defaultMaxBuffersPerBucket,
    int? maxBuffersPerBucket,
    this.maxTotalBuffers,
    this.maxBufferSizeBytes = defaultMaxBufferSizeBytes,
  }) : maxBuffersPerBucket = maxBuffersPerBucket ?? maxBuffers {
    final perBucket = this.maxBuffersPerBucket;
    if (perBucket < 0) {
      throw RangeError.value(
          perBucket, 'maxBuffersPerBucket', 'Must be non-negative');
    }
    final total = maxTotalBuffers;
    if (total != null && total < 0) {
      throw RangeError.value(total, 'maxTotalBuffers', 'Must be non-negative');
    }
    if (maxBufferSizeBytes < 0) {
      throw RangeError.value(
          maxBufferSizeBytes, 'maxBufferSizeBytes', 'Must be non-negative');
    }
  }

  /// Backward-compatible alias for [maxBuffersPerBucket].
  int get maxBuffers => maxBuffersPerBucket;

  /// Total number of idle buffers currently retained across all buckets in the pool.
  int get totalCachedBuffers => _totalBuffers;

  /// Returns the number of cached buffers in the bucket for [size].
  int pooledBuffersForSize(int size) => _buckets[size]?.length ?? 0;

  /// Computes the next power-of-two slab size for [size], with a minimum of [_minSlabSize].
  static int _nextPowerOf2(int size) {
    if (size <= _minSlabSize) return _minSlabSize;
    var v = size - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v |= v >> 32;
    return v + 1;
  }

  @override
  Uint8List checkout(int size) {
    if (size < 0) {
      throw RangeError.value(
          size, 'size', 'Requested buffer size must be non-negative');
    }
    if (size == 0) {
      return Uint8List(0);
    }
    if (size > maxBufferSizeBytes) {
      return Uint8List(size);
    }

    // 1. Check exact size bucket first (fast O(1) hit for repeated exact sizes)
    final exactBucket = _buckets[size];
    if (exactBucket != null && exactBucket.isNotEmpty) {
      _totalBuffers--;
      return exactBucket.removeLast();
    }

    // 2. Check power-of-two slab bucket
    final slabSize = _nextPowerOf2(size);
    if (slabSize <= maxBufferSizeBytes) {
      final slabBucket = _buckets[slabSize];
      if (slabBucket != null && slabBucket.isNotEmpty) {
        _totalBuffers--;
        return slabBucket.removeLast();
      }

      // 3. Check any intermediate bucket that satisfies size without exceeding slabSize
      for (final entry in _buckets.entries) {
        if (entry.key >= size &&
            entry.key <= slabSize &&
            entry.value.isNotEmpty) {
          _totalBuffers--;
          return entry.value.removeLast();
        }
      }

      return Uint8List(slabSize);
    }

    return Uint8List(size);
  }

  @override
  void checkin(Uint8List buffer) {
    if (buffer.isEmpty || buffer.length > maxBufferSizeBytes) {
      return;
    }

    final total = maxTotalBuffers;
    if (total != null && _totalBuffers >= total) {
      return;
    }

    final bucket = _buckets.putIfAbsent(buffer.length, () => []);
    if (bucket.length >= maxBuffersPerBucket) {
      return;
    }

    // Prevent duplicate checkin of the same buffer instance.
    for (var i = 0; i < bucket.length; i++) {
      if (identical(bucket[i], buffer)) {
        return;
      }
    }

    bucket.add(buffer);
    _totalBuffers++;
  }

  /// Clears all cached buffers from the pool.
  void clear() {
    _buckets.clear();
    _totalBuffers = 0;
  }
}

/// A high-performance buffer pool using power-of-two slab bucketing.
///
/// ### Overview and Usage
/// [SimpleLz4BufferPool] organizes byte buffers into power-of-two slab buckets
/// (e.g. 64 B, 128 B, ..., 64 KB, 256 KB, 1 MB, 4 MB, up to [maxBufferSizeBytes]).
/// When [checkout] is called, a buffer of matching capacity is retrieved in O(1)
/// time from the appropriate slab bucket, eliminating repetitive heap allocations
/// and reducing Garbage Collection (GC) churn.
///
/// ```dart
/// final pool = SimpleLz4BufferPool(
///   maxBuffers: 16,
///   maxBufferSizeBytes: 8 * 1024 * 1024,
/// );
/// final buffer = pool.checkout(65536);
/// try {
///   // Perform high-throughput decompression
/// } finally {
///   pool.checkin(buffer);
/// }
/// ```
///
/// ### Performance Benefits
/// - **Zero-Overhead Recycling**: Does not zero out buffers on [checkin],
///   avoiding costly memory clearing loops when buffers are immediately overwritten.
/// - **Slab Bucketing**: Prevents memory fragmentation by grouping allocations into
///   discrete power-of-two tiers (matching LZ4 block sizes of 64KB, 256KB, 1MB, 4MB).
/// - **Bounded Memory**: Enforces [maxBuffersPerBucket] and [maxBufferSizeBytes]
///   to maintain a predictable memory footprint.
///
/// ### Security Implications (Simple vs. Secure)
/// - **WARNING**: [SimpleLz4BufferPool] does **NOT** sanitize or zero out memory
///   upon [checkin]. Buffers returned by [checkout] may contain residual bytes
///   from previous decompression operations.
/// - In multi-tenant environments or systems handling confidential payloads,
///   reusing uncleared buffers can lead to **CWE-226: Sensitive Information
///   Uncleared Before Release to a New Owning Process** if subsequent operations
///   read past the logical end of decoded data.
/// - If decompression security boundaries require memory isolation, use
///   [SecureLz4BufferPool] instead.
class SimpleLz4BufferPool extends _BaseLz4BufferPool {
  /// Creates a new [SimpleLz4BufferPool].
  ///
  /// - [maxBuffers]: The maximum number of buffers retained per slab bucket (alias
  ///   for [maxBuffersPerBucket], defaults to 16).
  /// - [maxBuffersPerBucket]: Explicit per-bucket buffer limit.
  /// - [maxTotalBuffers]: Optional total buffer limit across all buckets combined.
  /// - [maxBufferSizeBytes]: Maximum size in bytes of a buffer eligible for
  ///   caching (defaults to 8 MiB). Buffers exceeding this size are rejected to
  ///   prevent decompression bombs from monopolizing memory.
  SimpleLz4BufferPool({
    super.maxBuffers,
    super.maxBuffersPerBucket,
    super.maxTotalBuffers,
    super.maxBufferSizeBytes,
  });
}

/// A security-hardened buffer pool that zeroes out buffers on checkin.
///
/// ### Overview and Usage
/// [SecureLz4BufferPool] provides the same power-of-two slab bucketing and
/// allocation reduction as [SimpleLz4BufferPool], but strictly enforces memory
/// sanitization to prevent data leakage across operations.
///
/// ```dart
/// final securePool = SecureLz4BufferPool();
/// final buffer = securePool.checkout(1024);
/// try {
///   // Decompress sensitive data into buffer
/// } finally {
///   // Buffer is completely zeroed out upon checkin
///   securePool.checkin(buffer);
/// }
/// ```
///
/// ### Security Guarantees (CWE-226 Mitigation)
/// - **Mandatory Zeroization**: On [checkin], the pool immediately executes
///   `buffer.fillRange(0, buffer.length, 0)`. Even if the buffer exceeds
///   [maxBufferSizeBytes] and is rejected from caching, it is scrubbed before
///   being released to the Dart garbage collector.
/// - **Stale Data Leakage Protection**: Prevents residual sensitive data (such as
///   session tokens, decrypted keys, or PII) from persisting in reused memory or
///   being observed by subsequent operations (CWE-226).
/// - **Decompression-Bomb Defense**: Buffers larger than [maxBufferSizeBytes]
///   (default 8 MiB) are scrubbed and rejected from pool caching, ensuring rogue
///   or hostile inputs cannot cause unbounded heap retention.
///
/// ### Performance Trade-offs (Simple vs. Secure)
/// - [SecureLz4BufferPool] incurs a small CPU overhead during [checkin] to fill
///   the buffer with zeros (`buffer.fillRange`).
/// - When processing untrusted inputs or operating across tenant/security
///   domains, this overhead is the recommended tradeoff to guarantee memory hygiene.
/// - For purely single-tenant, high-throughput pipelines where data is non-sensitive
///   and buffers are guaranteed to be overwritten, [SimpleLz4BufferPool] offers
///   maximum raw speed.
class SecureLz4BufferPool extends _BaseLz4BufferPool {
  /// Creates a new [SecureLz4BufferPool].
  ///
  /// - [maxBuffers]: The maximum number of buffers retained per slab bucket (alias
  ///   for [maxBuffersPerBucket], defaults to 16).
  /// - [maxBuffersPerBucket]: Explicit per-bucket buffer limit.
  /// - [maxTotalBuffers]: Optional total buffer limit across all buckets combined.
  /// - [maxBufferSizeBytes]: Maximum size in bytes of a buffer eligible for
  ///   caching (defaults to 8 MiB). Buffers exceeding this size are scrubbed
  ///   and rejected from caching.
  SecureLz4BufferPool({
    super.maxBuffers,
    super.maxBuffersPerBucket,
    super.maxTotalBuffers,
    super.maxBufferSizeBytes,
  });

  @override
  void checkin(Uint8List buffer) {
    // Mandate zeroization to prevent CWE-226 stale memory leakage.
    // Executed before caching checks to ensure even oversized/rejected
    // buffers are cleansed before being handed to GC.
    buffer.fillRange(0, buffer.length, 0);
    super.checkin(buffer);
  }
}
