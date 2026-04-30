/// Optimized 32-bit multiplication for Dart VM.
int mul32(int a, int b) => (a * b) & 0xFFFFFFFF;
