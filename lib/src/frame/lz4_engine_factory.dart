import '../block/lz4_block_encoder.dart';
import '../hc/lz4_hc_block_encoder.dart';
import '../hc/lz4_hc_options.dart';
import '../internal/lz4_engine.dart';
import 'lz4_frame_options.dart';

/// Creates an [Lz4CompressionEngine] based on the provided [options].
Lz4CompressionEngine createLz4Engine(Lz4FrameOptions options) {
  switch (options.compression) {
    case Lz4FrameCompression.fast:
      return PureDartLz4FastEngine(acceleration: options.acceleration);
    case Lz4FrameCompression.hc:
      return PureDartLz4HcEngine(options: options.hcOptions ?? Lz4HcOptions());
  }
}
