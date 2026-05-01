---
sidebar_position: 1
---

# Tuning HC Levels

LZ4 HC (High Compression) mode provides significantly better compression ratios at the cost of encoding speed. (Decoding speed remains virtually identical to standard LZ4).

## Standard Levels (1 - 12)

`dart_lz4` fully standardizes the HC levels to match the C-reference implementation, where levels range from 1 to 12.

- **Level 1-3:** Light HC. Faster encoding, slightly better ratio than standard fast LZ4.
- **Level 9:** Default HC level. A great balance of strong compression and reasonable time.
- **Level 12:** Max HC. For when you need every single byte squeezed and encoding time is not a constraint.

```dart
import 'package:dart_lz4/dart_lz4.dart';

void main() {
  final data = List<int>.filled(1024 * 1024, 42); // 1MB of repetitive data
  
  // Standard compression (fast)
  final fast = lz4Compress(data);
  
  // Default HC compression (level 9)
  final hcDefault = lz4Compress(data, level: Lz4Level.hc);
  
  // Maximum HC compression (level 12)
  final hcMax = lz4Compress(
    data, 
    level: Lz4Level.hc,
    hcOptions: Lz4HcOptions(level: 12),
  );
}
```

## When to use HC

Use HC mode for:
1. **"Compress once, decompress many"** scenarios (e.g., game assets, static web content).
2. Cold storage or backups where size is the primary constraint.

Do NOT use HC mode for:
1. Real-time RPC pipelines.
2. High-throughput ingestion queues.
