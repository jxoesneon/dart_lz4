# Technical Specification: Guarded Wildcopy Decompression & Zero-Allocation Buffer Pooling

**Project:** dart_lz4 (Pure Dart LZ4)  
**Status:** Draft  
**Target:** Performance optimization and memory efficiency.

---

## 1. Guarded Wildcopy Decompression

### 1.1 Overview
LZ4 decompression performance is dominated by match copying. The current implementation uses a scalar (1-byte) loop which is inefficient. "Wildcopy" is an optimization where we copy fixed-size blocks (8 bytes) to leverage word-sized CPU operations.

### 1.2 Design: 8-Byte Copy Loop
The `copyMatch` implementation in `ByteWriter` will be upgraded to use `ByteData` for 64-bit word copies.

#### 1.2.1 Core Algorithm
1. **Distance Check**: If `distance < 8`, the copy loop must handle overlapping memory regions. LZ4 semantics require that the pattern repeats. A simple 8-byte copy naturally handles this if `distance` is used as the offset for each load.
2. **Wildcopy Phase**: Perform 8-byte copies while the destination pointer is at least 8 bytes away from the logical end of the match (`matchEnd - 7`).
3. **Scalar Fallback (The Guard)**: Copy the remaining 0-7 bytes using a scalar 1-byte loop. This prevents "overshoot" where bytes beyond the requested `matchLength` (and potentially beyond the buffer boundary) would be modified.

#### 1.2.2 Implementation Strategy (Dart)
Using `ByteData` ensures compatibility across aligned (ARM) and unaligned (x86) platforms without manual alignment checks, as the Dart VM/Web runtime handles the underlying complexity.

```dart
// Conceptual Implementation in ByteWriter
void copyMatch(int distance, int matchLength) {
  // ... validation ...
  _ensureCapacity(matchLength);

  final destStart = _length;
  final matchEnd = destStart + matchLength;
  final wildCopyLimit = matchEnd - 7;
  
  int op = destStart;
  int ref = destStart - distance;

  final bd = _buffer.buffer.asByteData();

  // Wildcopy loop
  while (op < wildCopyLimit) {
    bd.setUint64(op, bd.getUint64(ref, Endian.little), Endian.little);
    op += 8;
    ref += 8;
  }

  // Scalar fallback guard
  while (op < matchEnd) {
    _buffer[op++] = _buffer[ref++];
  }

  _length = matchEnd;
}
```

### 1.3 Performance Impact Analysis
- **Throughput**: For matches > 16 bytes, we expect a 4x-6x improvement in match-copying speed on 64-bit architectures.
- **Instruction Count**: Reduces loop overhead by a factor of 8 for large matches.
- **Latency**: Minimal overhead for small matches (< 8 bytes) due to the scalar fallback branch.

### 1.4 Safety Proof
- **Bounds Protection**: The `wildCopyLimit` ensures that the last `setUint64` starts at most at `matchEnd - 8`, meaning it writes up to `matchEnd`. It never writes to `matchEnd + 1`.
- **Memory Integrity**: Since `_ensureCapacity` is called before copying, we guarantee that `_buffer` has sufficient space for the wildcopy, even if it slightly overshoots the internal `matchLength` within the pre-allocated capacity (but it doesn't overshoot `matchEnd` due to the guard).

---

## 2. Zero-Allocation Buffer Pooling

### 2.1 Overview
To minimize GC churn in high-throughput streaming or block-processing scenarios, `dart_lz4` will implement a buffer pooling mechanism.

### 2.2 `Lz4BufferPool` Interface
```dart
/// Interface for managing reusable byte buffers.
abstract interface class Lz4BufferPool {
  /// Checks out a buffer of at least [minimumCapacity].
  /// The returned buffer's contents are not guaranteed to be zeroed 
  /// unless [zeroClear] is true.
  Uint8List checkout(int minimumCapacity, {bool zeroClear = false});

  /// Returns a buffer to the pool for future reuse.
  void checkin(Uint8List buffer);
}
```

### 2.3 Security: Stale Data Leakage Protection
**Council of Safety Mandate:** Reusing buffers across different decompression contexts poses a risk of leaking sensitive data from previous operations if the buffer is not properly sanitized.

#### 2.3.1 Logical-Size Clamping
- When a buffer is checked out, the pool should ideally return a `Uint8List.view` that is exactly the requested size.
- However, for `ByteWriter`, we often need growing capacity. The pool should provide the underlying `Uint8List` but the `ByteWriter` must strictly manage its `_length`.

#### 2.3.2 Zero-Clearing Requirements
- **Mandatory Zeroing**: If a pool is shared across security boundaries, the pool **MUST** zero-clear the buffer either during `checkin` or `checkout`.
- **Implementation**: Use `Uint8List.fillRange(0, length, 0)`.

### 2.4 Lifecycle Management
1. **Checkout**: `ByteWriter` or `lz4BlockDecompress` requests a buffer from the pool.
2. **Utilization**: The buffer is used as the backing store for decompression.
3. **Checkin**: Upon completion (or error), the caller returns the buffer to the pool.
4. **Error Handling**: A `try-finally` block must be used to ensure `checkin` is called even if decompression fails.

### 2.5 "Stale Data Leakage" Test Specification
A dedicated test suite `test/security/buffer_leakage_test.dart` will be created:
1. **Scenario**: Decompress sensitive data into a buffer.
2. **Action**: `checkin` the buffer and then `checkout` the same buffer for a smaller, non-sensitive decompression.
3. **Validation**: Assert that no bytes from the sensitive data are readable beyond the logical length of the second decompression or within the padded capacity of the buffer if zero-clearing is enabled.

---

## 3. Integration Plan
- Update `ByteWriter` to support an optional `Lz4BufferPool`.
- Refactor `lz4BlockDecompress` and `lz4BlockDecompressInto` to utilize the pool if provided in `Lz4Options`.
- Standardize on `ByteData` for all multi-byte read/write operations in `ByteReader` and `ByteWriter`.
