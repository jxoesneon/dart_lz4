import 'dart:typed_data';

const _mask32 = 0xFFFFFFFF;

const _prime32_1 = 0x9E3779B1;
const _prime32_2 = 0x85EBCA77;
const _prime32_3 = 0xC2B2AE3D;
const _prime32_4 = 0x27D4EB2F;
const _prime32_5 = 0x165667B1;

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
