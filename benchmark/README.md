# Benchmarks

This directory contains micro-benchmarks and throughput benchmarks for:

- LZ4 block encode/decode (fast)
- LZ4HC block encode/decode (hc)
- LZ4 frame encode/decode (sync)
- LZ4 frame encode/decode (streaming)

Run:

- dart run benchmark/lz4_benchmark.dart

## Methodology

The benchmark harness reports:

- Compressed size and **ratio** (`compressed_bytes / input_bytes`).
- **Throughput** in MiB/s for compress/decompress or encode/decode.

Throughput is measured by:

- Warming up the codec for a few iterations.
- Increasing the iteration count until a target wall-clock time is reached.
- Reporting the steady-state throughput based on total bytes processed.

The suite runs two input shapes:

- `random 1MiB`: low compressibility (ratio near 1.0).
- `repeating 1MiB`: high compressibility (ratio near 0.0).

## Interpreting results

- **Random input** is useful for measuring overhead and raw speed (since it won’t compress much).
- **Repeating input** is useful for measuring match-finding effectiveness and compression ratio.
- **Fast vs HC**:
  - `fast` prioritizes throughput.
  - `hc` prioritizes ratio and may be significantly slower on incompressible data.
- **Frame vs block**:
  - Frames add headers, optional checksums, and block framing overhead.
  - Ratios can differ slightly because frames may store some blocks uncompressed when that is smaller.
- **Streaming vs sync**:
  - Streaming includes chunking/concatenation overhead and may show different encode/decode throughput.

For consistent comparisons:

- Run on an otherwise idle machine.
- Compare runs on the same Dart SDK and CPU.
- Prefer multiple runs and compare medians.
