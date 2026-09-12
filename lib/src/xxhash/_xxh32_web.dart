/// Safe 16-bit split-multiplication for Web.
int mul32(int a, int b) {
  final al = a & 0xffff;
  final ah = (a >>> 16) & 0xffff;
  final bl = b & 0xffff;
  final bh = (b >>> 16) & 0xffff;

  final lo = al * bl;
  final mid = (ah * bl + al * bh) & 0xffff;

  return (lo + (mid << 16)).toUnsigned(32);
}

/// Web IEEE-754 precision loss check (> 2^53 - 1).
void checkWebPrecision(int len) {
  if (len > 9007199254740991) {
    throw UnsupportedError('xxhash32 precision loss on Web');
  }
}
