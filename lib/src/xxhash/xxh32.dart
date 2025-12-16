import 'dart:typed_data';

const _mask32 = 0xFFFFFFFF;

const _prime32_1 = 0x9E3779B1;
const _prime32_2 = 0x85EBCA77;
const _prime32_3 = 0xC2B2AE3D;
const _prime32_4 = 0x27D4EB2F;
const _prime32_5 = 0x165667B1;

final class Xxh32 {
  final int _seed;
  int _totalLen;

  int _v1;
  int _v2;
  int _v3;
  int _v4;

  final Uint8List _mem;
  int _memSize;

  Xxh32({int seed = 0})
      : _seed = seed,
        _totalLen = 0,
        _v1 = (seed + _prime32_1 + _prime32_2) & _mask32,
        _v2 = (seed + _prime32_2) & _mask32,
        _v3 = seed & _mask32,
        _v4 = (seed - _prime32_1) & _mask32,
        _mem = Uint8List(16),
        _memSize = 0;

  void update(Uint8List input, {int start = 0, int? end}) {
    final e = end ?? input.length;
    if (start < 0 || start > input.length) {
      throw RangeError.range(start, 0, input.length, 'start');
    }
    if (e < start || e > input.length) {
      throw RangeError.range(e, start, input.length, 'end');
    }

    var p = start;
    var length = e - start;
    if (length == 0) {
      return;
    }

    _totalLen += length;

    if (_memSize + length < 16) {
      _mem.setRange(_memSize, _memSize + length, input, p);
      _memSize += length;
      return;
    }

    if (_memSize != 0) {
      final fill = 16 - _memSize;
      _mem.setRange(_memSize, 16, input, p);
      p += fill;
      length -= fill;
      _memSize = 0;

      var m = 0;
      _v1 = _round(_v1, _readU32LE(_mem, m));
      m += 4;
      _v2 = _round(_v2, _readU32LE(_mem, m));
      m += 4;
      _v3 = _round(_v3, _readU32LE(_mem, m));
      m += 4;
      _v4 = _round(_v4, _readU32LE(_mem, m));
    }

    final limit = p + length - 16;
    while (p <= limit) {
      _v1 = _round(_v1, _readU32LE(input, p));
      p += 4;
      _v2 = _round(_v2, _readU32LE(input, p));
      p += 4;
      _v3 = _round(_v3, _readU32LE(input, p));
      p += 4;
      _v4 = _round(_v4, _readU32LE(input, p));
      p += 4;
    }

    final remaining = (e - p);
    if (remaining != 0) {
      _mem.setRange(0, remaining, input, p);
      _memSize = remaining;
    }
  }

  int digest() {
    int h32;
    if (_totalLen >= 16) {
      h32 = (_rotl32(_v1, 1) +
              _rotl32(_v2, 7) +
              _rotl32(_v3, 12) +
              _rotl32(_v4, 18)) &
          _mask32;
    } else {
      h32 = (_seed + _prime32_5) & _mask32;
    }

    h32 = (h32 + _totalLen) & _mask32;

    var p = 0;
    final len = _memSize;

    while (p <= len - 4) {
      h32 = (h32 + ((_readU32LE(_mem, p) * _prime32_3) & _mask32)) & _mask32;
      h32 = (_rotl32(h32, 17) * _prime32_4) & _mask32;
      p += 4;
    }

    while (p < len) {
      h32 = (h32 + ((_mem[p] * _prime32_5) & _mask32)) & _mask32;
      h32 = (_rotl32(h32, 11) * _prime32_1) & _mask32;
      p++;
    }

    h32 ^= (h32 >>> 15);
    h32 = (h32 * _prime32_2) & _mask32;
    h32 ^= (h32 >>> 13);
    h32 = (h32 * _prime32_3) & _mask32;
    h32 ^= (h32 >>> 16);

    return h32 & _mask32;
  }
}

int xxh32(Uint8List input, {int seed = 0}) {
  var p = 0;
  final len = input.length;

  int h32;
  if (len >= 16) {
    var v1 = (seed + _prime32_1 + _prime32_2) & _mask32;
    var v2 = (seed + _prime32_2) & _mask32;
    var v3 = seed & _mask32;
    var v4 = (seed - _prime32_1) & _mask32;

    final limit = len - 16;
    while (p <= limit) {
      v1 = _round(v1, _readU32LE(input, p));
      p += 4;
      v2 = _round(v2, _readU32LE(input, p));
      p += 4;
      v3 = _round(v3, _readU32LE(input, p));
      p += 4;
      v4 = _round(v4, _readU32LE(input, p));
      p += 4;
    }

    h32 =
        (_rotl32(v1, 1) + _rotl32(v2, 7) + _rotl32(v3, 12) + _rotl32(v4, 18)) &
            _mask32;
  } else {
    h32 = (seed + _prime32_5) & _mask32;
  }

  h32 = (h32 + len) & _mask32;

  while (p <= len - 4) {
    h32 = (h32 + ((_readU32LE(input, p) * _prime32_3) & _mask32)) & _mask32;
    h32 = (_rotl32(h32, 17) * _prime32_4) & _mask32;
    p += 4;
  }

  while (p < len) {
    h32 = (h32 + ((input[p] * _prime32_5) & _mask32)) & _mask32;
    h32 = (_rotl32(h32, 11) * _prime32_1) & _mask32;
    p++;
  }

  h32 ^= (h32 >>> 15);
  h32 = (h32 * _prime32_2) & _mask32;
  h32 ^= (h32 >>> 13);
  h32 = (h32 * _prime32_3) & _mask32;
  h32 ^= (h32 >>> 16);

  return h32 & _mask32;
}

int _round(int acc, int input) {
  acc = (acc + ((input * _prime32_2) & _mask32)) & _mask32;
  acc = _rotl32(acc, 13);
  acc = (acc * _prime32_1) & _mask32;
  return acc;
}

int _rotl32(int x, int r) {
  final v = x & _mask32;
  return (((v << r) & _mask32) | (v >>> (32 - r))) & _mask32;
}

int _readU32LE(Uint8List src, int offset) {
  return (src[offset] |
          (src[offset + 1] << 8) |
          (src[offset + 2] << 16) |
          (src[offset + 3] << 24)) &
      _mask32;
}
