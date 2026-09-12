import 'dart:typed_data';

/// Multi-platform wildcopy stub using 32-bit words.
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
