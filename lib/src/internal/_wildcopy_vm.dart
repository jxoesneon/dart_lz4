import 'dart:typed_data';

/// High-performance 64-bit wildcopy for Dart VM.
int wildCopy(ByteData bd, int dest, int distance, int limit) {
  var d = dest;
  while (d <= limit) {
    bd.setUint64(
      d,
      bd.getUint64(d - distance, Endian.little),
      Endian.little,
    );
    d += 8;
  }
  return d;
}

const int wildCopyLimitOffset = 8;
const int wildCopyMinDistance = 8;
