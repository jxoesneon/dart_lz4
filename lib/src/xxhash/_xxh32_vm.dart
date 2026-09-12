/// Optimized 32-bit multiplication for Dart VM.
int mul32(int a, int b) => (a * b) & 0xFFFFFFFF;

/// 64-bit integer platforms do not suffer from Web IEEE-754 precision loss.
void checkWebPrecision(int len) {}
