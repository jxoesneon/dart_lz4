import 'dart:typed_data';

import '../block/lz4_block_encoder.dart';
import '../internal/byte_writer.dart';
import '../internal/lz4_exception.dart';
import '../hc/lz4_hc_block_encoder.dart';
import '../xxhash/xxh32.dart';
import 'lz4_frame_options.dart';

const _lz4FrameMagic = 0x184D2204;
const _lz4SkippableMagicBase = 0x184D2A50;
const _lz4LegacyFrameMagic = 0x184C2102;
const _legacyBlockMaxSize = 8 * 1024 * 1024; // 8 MiB

/// Encodes a skippable frame containing [data].
///
/// Skippable frames are used to embed user-defined metadata within an LZ4
/// stream. Decoders that don't recognize the frame type will skip over it.
///
/// The [index] (0–15) selects which skippable magic number to use:
/// `0x184D2A50` through `0x184D2A5F`. Different indices can be used to
/// distinguish different types of metadata.
///
/// The [data] can be up to 4 GiB in size (2^32 - 1 bytes).
///
/// Returns the encoded skippable frame (8 bytes header + data).
Uint8List lz4SkippableFrameEncode(Uint8List data, {int index = 0}) {
  if (index < 0 || index > 15) {
    throw RangeError.range(index, 0, 15, 'index');
  }
  if (data.length > 0xFFFFFFFF) {
    throw RangeError.value(data.length, 'data.length', 'Exceeds 4 GiB limit');
  }

  final result = Uint8List(8 + data.length);
  final view = ByteData.sublistView(result);

  // Magic number
  view.setUint32(0, _lz4SkippableMagicBase + index, Endian.little);
  // Size
  view.setUint32(4, data.length, Endian.little);
  // Data
  result.setRange(8, result.length, data);

  return result;
}

/// Encodes [src] as a legacy LZ4 frame (magic `0x184C2102`).
///
/// Legacy frames use 8 MiB blocks without checksums or content size headers.
/// This format is produced by `lz4 -l` and is rarely needed for new data.
/// Prefer the modern frame format ([lz4FrameEncodeBytes]) for new applications.
///
/// [acceleration] controls the speed/ratio tradeoff (higher = faster, lower ratio).
Uint8List lz4LegacyFrameEncode(Uint8List src, {int acceleration = 1}) {
  final writer = ByteWriter(initialCapacity: src.length + 64);

  // Write legacy magic
  writer.writeUint32LE(_lz4LegacyFrameMagic);

  var offset = 0;
  while (offset < src.length) {
    var end = offset + _legacyBlockMaxSize;
    if (end > src.length) {
      end = src.length;
    }

    final chunk = Uint8List.sublistView(src, offset, end);

    // Compress block
    final compressed = lz4BlockCompress(chunk, acceleration: acceleration);

    // Legacy format always uses compressed data (no uncompressed fallback in original spec)
    // However, we should still store uncompressed if compression doesn't help
    if (compressed.length < chunk.length) {
      writer.writeUint32LE(compressed.length);
      writer.writeBytes(compressed);
    } else {
      // Store uncompressed - legacy decoders expect this to still decompress
      // but since LZ4 block format handles literals, just write the compressed version
      writer.writeUint32LE(compressed.length);
      writer.writeBytes(compressed);
    }

    offset = end;
  }

  return writer.toBytes();
}

Uint8List lz4FrameEncodeBytes(
  Uint8List src, {
  int acceleration = 1,
  Uint8List? dictionary,
}) {
  return lz4FrameEncodeBytesWithOptions(
    src,
    options: Lz4FrameOptions(
      acceleration: acceleration,
    ),
    dictionary: dictionary,
  );
}

Uint8List lz4FrameEncodeBytesWithOptions(
  Uint8List src, {
  required Lz4FrameOptions options,
  Uint8List? dictionary,
}) {
  const version = 0x01;

  final flg = ((version & 0x03) << 6) |
      ((options.blockIndependence ? 1 : 0) << 5) |
      ((options.blockChecksum ? 1 : 0) << 4) |
      ((options.contentSize != null ? 1 : 0) << 3) |
      ((options.contentChecksum ? 1 : 0) << 2) |
      ((options.dictId != null ? 1 : 0) << 0);

  final bd = (options.blockSize.bdId & 0x07) << 4;
  final blockMaxSize = options.blockSize.maxBytes;

  final writer = ByteWriter(initialCapacity: src.length + 64);
  writer.writeUint32LE(_lz4FrameMagic);

  writer.writeUint8(flg);
  writer.writeUint8(bd);

  final contentSize = options.contentSize;
  if (contentSize != null) {
    writer.writeUint32LE(contentSize & 0xFFFFFFFF);
    // Use integer division instead of shift for JS compatibility
    writer.writeUint32LE((contentSize ~/ 4294967296) & 0xFFFFFFFF);
  }

  final dictId = options.dictId;
  if (dictId != null) {
    writer.writeUint32LE(dictId);
  }

  final headerEnd = writer.length;
  final headerBytes = writer.bytesView();
  final descriptor = Uint8List.sublistView(headerBytes, 4, headerEnd);
  final hc = (xxh32(descriptor, seed: 0) >> 8) & 0xff;
  writer.writeUint8(hc);

  Xxh32? contentHasher;
  if (options.contentChecksum) {
    contentHasher = Xxh32(seed: 0);
  }

  const historyWindow = 64 * 1024;

  var offset = 0;
  while (offset < src.length) {
    var end = offset + blockMaxSize;
    if (end > src.length) {
      end = src.length;
    }

    final chunk = Uint8List.sublistView(src, offset, end);

    if (contentHasher != null) {
      contentHasher.update(chunk);
    }

    final Uint8List? blockDict;
    if (options.blockIndependence) {
      // If blocks are independent, we can only use the provided external dictionary
      blockDict = dictionary;
    } else {
      // Dependent blocks:
      // If offset == 0, we use the external dictionary.
      // If offset > 0, we use the previous data as dictionary.
      // However, if we are near the beginning, we might need to combine
      // part of the external dictionary with the start of src.
      if (offset == 0) {
        blockDict = dictionary;
      } else if (offset >= historyWindow) {
        // We have enough history in src itself.
        blockDict = Uint8List.sublistView(src, offset - historyWindow, offset);
      } else {
        // Mixed history: some from external dict (if any), some from src.
        // We need 64KB total history.
        // Available from src: 'offset' bytes.
        // Needed from dict: historyWindow - offset.
        final dictLen = dictionary?.length ?? 0;
        if (dictLen == 0) {
          blockDict = Uint8List.sublistView(src, 0, offset);
        } else {
          final neededFromDict = historyWindow - offset;
          final takeFromDict =
              dictLen > neededFromDict ? neededFromDict : dictLen;
          // We need to construct a combined dictionary buffer.
          // This is expensive (allocation), but necessary for correct compression
          // of the boundary region with dependent blocks + external dictionary.
          final combined = Uint8List(takeFromDict + offset);
          combined.setRange(
              0,
              takeFromDict,
              Uint8List.sublistView(
                  dictionary!, dictLen - takeFromDict, dictLen));
          combined.setRange(takeFromDict, combined.length,
              Uint8List.sublistView(src, 0, offset));
          blockDict = combined;
        }
      }
    }

    // Reserve space for block size (4 bytes)
    final blockStart = writer.length;
    writer.writeUint32LE(0); // placeholder

    final payloadStart = writer.length;

    switch (options.compression) {
      case Lz4FrameCompression.fast:
        lz4BlockCompressToWriter(
          writer,
          chunk,
          dictionary: blockDict,
          acceleration: options.acceleration,
        );
        break;
      case Lz4FrameCompression.hc:
        lz4HcBlockCompressToWriter(
          writer,
          chunk,
          dictionary: blockDict,
          options: options.hcOptions,
        );
        break;
    }

    final compressedLen = writer.length - payloadStart;
    final useCompressed = compressedLen < chunk.length;

    if (useCompressed) {
      // Update block size header
      final blockSizeRaw = compressedLen; // Compressed flag bit 31 is 0
      writer.writeUint32LEAt(blockStart, blockSizeRaw);

      if (options.blockChecksum) {
        // We need to calculate checksum of the COMPRESSED payload
        final payloadView = Uint8List.sublistView(
            writer.bytesView(), payloadStart, writer.length);
        writer.writeUint32LE(xxh32(payloadView, seed: 0));
      }
    } else {
      // Discard compressed data and write uncompressed
      writer.length = blockStart; // Rewind
      final blockSizeRaw = 0x80000000 | chunk.length;
      writer.writeUint32LE(blockSizeRaw);
      writer.writeBytes(chunk);

      if (options.blockChecksum) {
        writer.writeUint32LE(xxh32(chunk, seed: 0));
      }
    }

    offset = end;
  }

  writer.writeUint32LE(0);

  if (options.contentChecksum) {
    writer.writeUint32LE(contentHasher!.digest());
  }

  if (contentSize != null && src.length != contentSize) {
    throw Lz4FormatException('contentSize does not match src length');
  }

  return writer.toBytes();
}
