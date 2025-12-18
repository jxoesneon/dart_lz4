import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  var baselinePath = 'benchmark/baseline/macos.txt';
  String? currentPath;
  var runBench = false;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--baseline':
        if (i + 1 >= args.length) {
          stderr.writeln('Missing value for --baseline');
          exitCode = 2;
          return;
        }
        baselinePath = args[++i];
        break;
      case '--current':
        if (i + 1 >= args.length) {
          stderr.writeln('Missing value for --current');
          exitCode = 2;
          return;
        }
        currentPath = args[++i];
        break;
      case '--run':
        runBench = true;
        break;
      case '--help':
      case '-h':
        _printUsage();
        return;
      default:
        stderr.writeln('Unknown argument: $a');
        _printUsage();
        exitCode = 2;
        return;
    }
  }

  final repoRoot = _findRepoRoot();
  if (repoRoot != null) {
    Directory.current = repoRoot;
  }

  final baselineText = await File(baselinePath).readAsString();
  final baselineOut = _extractBenchmarkOutput(baselineText) ?? baselineText;
  final baseline = _parseOutput(baselineOut);

  String currentText;
  if (runBench) {
    final result = await Process.run(
      'dart',
      const ['run', 'benchmark/lz4_benchmark.dart'],
      runInShell: true,
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    if (result.exitCode != 0) {
      stderr.writeln('benchmark run failed (exit ${result.exitCode})');
      stderr.write(utf8.decode(result.stderr as List<int>));
      exitCode = result.exitCode;
      return;
    }

    currentText = utf8.decode(result.stdout as List<int>);
  } else if (currentPath != null) {
    currentText = await File(currentPath).readAsString();
  } else {
    currentText = await stdin.transform(utf8.decoder).join();
    if (currentText.trim().isEmpty) {
      stderr.writeln('No current benchmark output provided.');
      _printUsage();
      exitCode = 2;
      return;
    }
  }

  final current = _parseOutput(currentText);

  _printComparison(baseline: baseline, current: current);
}

String? _findRepoRoot() {
  Directory dir;
  try {
    dir = File.fromUri(Platform.script).parent;
  } catch (_) {
    return null;
  }

  for (var i = 0; i < 6; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    if (candidate.existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }

  return null;
}

String? _extractBenchmarkOutput(String text) {
  final marker = '---- benchmark output ----';
  final idx = text.indexOf(marker);
  if (idx < 0) {
    return null;
  }
  final start = idx + marker.length;
  return text.substring(start).trimLeft();
}

Map<String, Map<String, Map<String, num>>> _parseOutput(String text) {
  final out = <String, Map<String, Map<String, num>>>{};

  String? dataset;

  final datasetRe = RegExp(r'^---\s+(.*?)\s+---\s*$');
  final compressedRe = RegExp(
      r'^\[([^\]]+)\]\s+compressed:\s+(\d+)\s+bytes\s+\(ratio:\s+([0-9.]+)\)\s*$');
  final throughputRe = RegExp(
      r'^\[([^\]]+)\]\s+(compress|decompress|encode|decode):\s+([0-9.]+)\s+MiB/s\s*$');

  for (final line in const LineSplitter().convert(text)) {
    final ds = datasetRe.firstMatch(line);
    if (ds != null) {
      dataset = ds.group(1);
      continue;
    }

    if (dataset == null) {
      continue;
    }

    final cm = compressedRe.firstMatch(line);
    if (cm != null) {
      final label = cm.group(1)!;
      final bytes = int.parse(cm.group(2)!);
      final ratio = double.parse(cm.group(3)!);

      final m = out.putIfAbsent(dataset, () => <String, Map<String, num>>{});
      final lm = m.putIfAbsent(label, () => <String, num>{});
      lm['compressed_bytes'] = bytes;
      lm['ratio'] = ratio;
      continue;
    }

    final tm = throughputRe.firstMatch(line);
    if (tm != null) {
      final label = tm.group(1)!;
      final metric = tm.group(2)!;
      final mib = double.parse(tm.group(3)!);

      final m = out.putIfAbsent(dataset, () => <String, Map<String, num>>{});
      final lm = m.putIfAbsent(label, () => <String, num>{});
      lm[metric] = mib;
      continue;
    }
  }

  return out;
}

void _printComparison({
  required Map<String, Map<String, Map<String, num>>> baseline,
  required Map<String, Map<String, Map<String, num>>> current,
}) {
  final datasets = <String>{...baseline.keys, ...current.keys}.toList()..sort();

  for (final dataset in datasets) {
    stdout.writeln('--- $dataset ---');

    final baseLabels = baseline[dataset] ?? const {};
    final currLabels = current[dataset] ?? const {};

    final labels = <String>{...baseLabels.keys, ...currLabels.keys}.toList()
      ..sort();

    for (final label in labels) {
      final b = baseLabels[label] ?? const {};
      final c = currLabels[label] ?? const {};

      final metrics = <String>{...b.keys, ...c.keys}.toList()
        ..sort(_metricSort);

      for (final metric in metrics) {
        final bv = b[metric];
        final cv = c[metric];

        final baseStr = bv == null ? '—' : _format(metric, bv);
        final currStr = cv == null ? '—' : _format(metric, cv);

        String deltaStr;
        if (bv == null || cv == null) {
          deltaStr = '';
        } else if (metric == 'compressed_bytes') {
          final delta = (cv as int) - (bv as int);
          deltaStr = '  (${_signedInt(delta)})';
        } else {
          final baseD = (bv as num).toDouble();
          final currD = (cv as num).toDouble();
          final delta = currD - baseD;
          final pct = baseD == 0 ? null : (delta / baseD) * 100.0;
          deltaStr = pct == null
              ? '  (${_signed(delta)})'
              : '  (${_signed(delta)}, ${_signed(pct)}%)';
        }

        stdout.writeln('[$label] $metric: $baseStr -> $currStr$deltaStr');
      }
    }

    stdout.writeln('');
  }
}

int _metricSort(String a, String b) {
  int rank(String m) {
    switch (m) {
      case 'ratio':
        return 0;
      case 'compressed_bytes':
        return 1;
      case 'compress':
        return 2;
      case 'decompress':
        return 3;
      case 'encode':
        return 4;
      case 'decode':
        return 5;
      default:
        return 100;
    }
  }

  final ra = rank(a);
  final rb = rank(b);
  if (ra != rb) {
    return ra.compareTo(rb);
  }
  return a.compareTo(b);
}

String _format(String metric, num value) {
  switch (metric) {
    case 'compressed_bytes':
      return value.toInt().toString();
    case 'ratio':
      return value.toDouble().toStringAsFixed(3);
    default:
      return value.toDouble().toStringAsFixed(1);
  }
}

String _signed(num v) {
  final d = v.toDouble();
  final sign = d >= 0 ? '+' : '';
  return '$sign${d.toStringAsFixed(1)}';
}

String _signedInt(int v) {
  final sign = v >= 0 ? '+' : '';
  return '$sign$v';
}

void _printUsage() {
  stdout.writeln('Usage: dart run tool/benchmark_compare.dart [options]');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln(
      '  --baseline <path>   Baseline file (default: benchmark/baseline/macos.txt)');
  stdout.writeln(
      '  --current <path>    Current benchmark output file (if not using --run)');
  stdout.writeln(
      '  --run               Run benchmark/lz4_benchmark.dart and compare stdout');
  stdout.writeln('  -h, --help          Show this help');
  stdout.writeln('');
  stdout.writeln(
      'If neither --current nor --run is provided, current output is read from stdin.');
}
