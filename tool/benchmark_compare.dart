import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  String? baselinePath;
  String? currentPath;
  var runBench = false;
  double? threshold;
  var githubSummary = false;

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
      case '--threshold':
        if (i + 1 >= args.length) {
          stderr.writeln('Missing value for --threshold');
          exitCode = 2;
          return;
        }
        threshold = double.tryParse(args[++i]);
        if (threshold == null) {
          stderr.writeln('Invalid threshold: ${args[i]}');
          exitCode = 2;
          return;
        }
        break;
      case '--github-summary':
        githubSummary = true;
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

  if (baselinePath == null) {
    // Try to auto-detect baseline based on OS
    final os = Platform.isMacOS
        ? 'macos'
        : Platform.isWindows
            ? 'windows'
            : 'linux';
    final candidate = 'benchmark/baseline/$os.txt';
    if (File(candidate).existsSync()) {
      baselinePath = candidate;
    } else {
      // Fallback to macos.txt if it's the only one we have
      baselinePath = 'benchmark/baseline/macos.txt';
    }
  }

  if (!File(baselinePath).existsSync()) {
    stderr.writeln('Baseline file not found: $baselinePath');
    if (runBench) {
      stderr.writeln('Running benchmark anyway...');
    } else {
      exitCode = 2;
      return;
    }
  }

  Map<String, Map<String, Map<String, num>>>? baseline;
  if (File(baselinePath).existsSync()) {
    final baselineText = await File(baselinePath).readAsString();
    final baselineOut = _extractBenchmarkOutput(baselineText) ?? baselineText;
    baseline = _parseOutput(baselineOut);
  }

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

  if (baseline == null) {
    _printCurrentOnly(current);
    return;
  }

  final results = _compare(baseline: baseline, current: current);
  _printComparison(results);

  if (githubSummary) {
    await _writeGithubSummary(results);
  }

  if (threshold != null) {
    final regressions = _findRegressions(results, threshold);
    if (regressions.isNotEmpty) {
      stderr.writeln(
          '\nPerformance regressions detected (threshold: $threshold%):');
      for (final r in regressions) {
        stderr.writeln('  $r');
      }
      exitCode = 1;
    }
  }
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

class ComparisonResult {
  final String dataset;
  final String label;
  final String metric;
  final num? baseline;
  final num? current;
  final num? delta;
  final double? percent;

  ComparisonResult({
    required this.dataset,
    required this.label,
    required this.metric,
    this.baseline,
    this.current,
    this.delta,
    this.percent,
  });
}

List<ComparisonResult> _compare({
  required Map<String, Map<String, Map<String, num>>> baseline,
  required Map<String, Map<String, Map<String, num>>> current,
}) {
  final results = <ComparisonResult>[];
  final datasets = <String>{...baseline.keys, ...current.keys}.toList()..sort();

  for (final dataset in datasets) {
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

        num? delta;
        double? percent;

        if (bv != null && cv != null) {
          if (metric == 'compressed_bytes') {
            delta = (cv as int) - (bv as int);
          } else {
            final baseD = bv.toDouble();
            final currD = cv.toDouble();
            delta = currD - baseD;
            if (baseD != 0) {
              percent = (delta / baseD) * 100.0;
            }
          }
        }

        results.add(ComparisonResult(
          dataset: dataset,
          label: label,
          metric: metric,
          baseline: bv,
          current: cv,
          delta: delta,
          percent: percent,
        ));
      }
    }
  }
  return results;
}

void _printComparison(List<ComparisonResult> results) {
  String? lastDataset;
  for (final r in results) {
    if (r.dataset != lastDataset) {
      stdout.writeln('--- ${r.dataset} ---');
      lastDataset = r.dataset;
    }

    final baseStr = r.baseline == null ? '—' : _format(r.metric, r.baseline!);
    final currStr = r.current == null ? '—' : _format(r.metric, r.current!);

    String deltaStr = '';
    if (r.delta != null) {
      if (r.metric == 'compressed_bytes') {
        deltaStr = '  (${_signedInt(r.delta!.toInt())})';
      } else {
        deltaStr = r.percent == null
            ? '  (${_signed(r.delta!)})'
            : '  (${_signed(r.delta!)}, ${_signed(r.percent!)})';
      }
    }

    stdout.writeln('[${r.label}] ${r.metric}: $baseStr -> $currStr$deltaStr');
  }
}

void _printCurrentOnly(Map<String, Map<String, Map<String, num>>> current) {
  for (final dataset in current.keys.toList()..sort()) {
    stdout.writeln('--- $dataset ---');
    final labels = current[dataset]!.keys.toList()..sort();
    for (final label in labels) {
      final metrics = current[dataset]![label]!.keys.toList()
        ..sort(_metricSort);
      for (final metric in metrics) {
        final val = current[dataset]![label]![metric]!;
        stdout.writeln('[$label] $metric: ${_format(metric, val)}');
      }
    }
    stdout.writeln('');
  }
}

Future<void> _writeGithubSummary(List<ComparisonResult> results) async {
  final summaryFile = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summaryFile == null) return;

  final sink = File(summaryFile).openWrite(mode: FileMode.append);
  sink.writeln('## Benchmark Comparison');
  sink.writeln('');
  sink.writeln('| Dataset | Label | Metric | Baseline | Current | Delta | % |');
  sink.writeln('|---------|-------|--------|----------|---------|-------|---|');

  for (final r in results) {
    final baseStr = r.baseline == null ? '—' : _format(r.metric, r.baseline!);
    final currStr = r.current == null ? '—' : _format(r.metric, r.current!);
    final deltaStr = r.delta == null ? '—' : _format(r.metric, r.delta!);
    final pctStr = r.percent == null ? '—' : '${_signed(r.percent!)}%';

    sink.writeln(
        '| ${r.dataset} | ${r.label} | ${r.metric} | $baseStr | $currStr | $deltaStr | $pctStr |');
  }

  sink.writeln('');
  await sink.close();
}

List<String> _findRegressions(
    List<ComparisonResult> results, double threshold) {
  final regressions = <String>[];
  for (final r in results) {
    // Only check throughput metrics (compress, decompress, encode, decode)
    if (r.metric == 'ratio' || r.metric == 'compressed_bytes') continue;

    if (r.percent != null && r.percent! < -threshold) {
      regressions.add(
          '${r.dataset} [${r.label}] ${r.metric}: ${_signed(r.percent!)}% (threshold: -$threshold%)');
    }
  }
  return regressions;
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
  stdout.writeln('  --baseline <path>     Baseline file');
  stdout.writeln(
      '  --current <path>      Current benchmark output file (if not using --run)');
  stdout.writeln(
      '  --run                 Run benchmark/lz4_benchmark.dart and compare stdout');
  stdout.writeln(
      '  --threshold <%>       Exit with 1 if throughput drops more than %');
  stdout.writeln(
      '  --github-summary      Write Markdown table to GITHUB_STEP_SUMMARY');
  stdout.writeln('  -h, --help            Show this help');
  stdout.writeln('');
  stdout.writeln(
      'If neither --current nor --run is provided, current output is read from stdin.');
}
