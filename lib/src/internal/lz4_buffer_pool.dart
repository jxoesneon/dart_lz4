import 'dart:typed_data';

/// Interface for buffer pooling to reduce allocations.
abstract interface class Lz4BufferPool {
  /// Checks out a [Uint8List] of at least [size] bytes.
  Uint8List checkout(int size);

  /// Checks in a [buffer] for reuse.
  void checkin(Uint8List buffer);
}

/// A simple buffer pool that reuses buffers without clearing them.
class SimpleLz4BufferPool implements Lz4BufferPool {
  final List<Uint8List> _pools = [];
  final int _maxBuffers;

  SimpleLz4BufferPool({int maxBuffers = 16}) : _maxBuffers = maxBuffers;

  @override
  Uint8List checkout(int size) {
    for (var i = 0; i < _pools.length; i++) {
      if (_pools[i].length >= size) {
        return _pools.removeAt(i);
      }
    }
    return Uint8List(size);
  }

  @override
  void checkin(Uint8List buffer) {
    if (_pools.length < _maxBuffers) {
      _pools.add(buffer);
    }
  }
}

/// A secure buffer pool that zeroes out buffers before checkin.
class SecureLz4BufferPool implements Lz4BufferPool {
  final List<Uint8List> _pools = [];
  final int _maxBuffers;

  SecureLz4BufferPool({int maxBuffers = 16}) : _maxBuffers = maxBuffers;

  @override
  Uint8List checkout(int size) {
    for (var i = 0; i < _pools.length; i++) {
      if (_pools[i].length >= size) {
        return _pools.removeAt(i);
      }
    }
    return Uint8List(size);
  }

  @override
  void checkin(Uint8List buffer) {
    // Zero out the buffer to prevent data leakage.
    buffer.fillRange(0, buffer.length, 0);
    if (_pools.length < _maxBuffers) {
      _pools.add(buffer);
    }
  }
}
