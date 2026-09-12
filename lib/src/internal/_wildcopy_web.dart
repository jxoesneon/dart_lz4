import 'dart:typed_data';

/// Safe 32-bit wildcopy for Web (JavaScript / WASM).
int wildCopy(ByteData bd, int dest, int distance, int limit) {
  var d = dest;
  while (d <= limit) {
    bd.setUint32(
      d,
      bd.getUint32(d - distance, Endian.little),
      Endian.little,
    );
    d += 4;
  }
  return d;
}

const int wildCopyLimitOffset = 4;
const int wildCopyMinDistance = 8;
