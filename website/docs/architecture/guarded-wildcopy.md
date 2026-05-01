---
sidebar_position: 1
---

# Architecture: Guarded Wildcopy

Decompression speed in LZ4 is entirely bound by memory copy throughput. Traditional byte-by-byte copying is incredibly slow.

## The Concept

The official LZ4 specification permits over-reading and over-writing (wildcopies) up to a specific boundary. 

Instead of reading 1 byte and writing 1 byte in a loop, a "Wildcopy" reads 8 bytes (a full 64-bit integer) and writes 8 bytes in a single operation. This drastically reduces loop iterations and branch checks.

## The Problem in Dart

Dart abstracts memory access. While FFI allows raw pointer access, pure Dart `Uint8List` access is bounds-checked by the VM. 
Furthermore, JavaScript (the Web target for Dart) does not natively support 64-bit bitwise operations without `BigInt`, which incurs massive boxing overhead.

## The Guarded Solution

`dart_lz4` uses a **Guarded Wildcopy** approach with Polymorphic Engine Interfaces:

1. **Native VM (JIT/AOT):** We utilize `ByteData` to read/write 64-bit `Int64` blocks natively aligned in memory.
2. **Web Fallback:** We fall back to 32-bit `Int32` reads/writes. This is safe for JavaScript engines and still provides a ~2-3x speedup over byte-by-byte operations without triggering `BigInt` boxing.

## Safety First

"Guarded" means that the wildcopy loop actively terminates before reaching the last 8-12 bytes of a buffer, depending on the specification boundary. The final bytes are *always* written byte-by-byte, guaranteeing we never exceed `Uint8List` bounds or throw `RangeError`s in production.
