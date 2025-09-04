import 'dart:io';
import 'dart:isolate';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:ciphercopy_cli/ciphercopy_logger.dart';

/// Simple Result type for success/failure with error message
class Result<T> {
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
  Result.success(this.value) : error = null, stackTrace = null;
  Result.failure(this.error, [this.stackTrace]) : value = null;
  bool get isSuccess => error == null;
  bool get isFailure => error != null;
}

/// Copies files listed in [listFile] to [destDir], preserving relative paths as much as possible.
/// For each file, uses [copyFile] and writes the hash to a single .sha1 file in [destDir].

Future<void> copyFilesFromList(
  String listFile,
  String destDir, {
  int? threadCount,
  bool saveLists = false,
}) async {
  final lines = await File(listFile).readAsLines();
  final hashFile = destDir.endsWith('/')
      ? '${destDir}hashes.sha1'
      : '$destDir/hashes.sha1';
  await deleteFile(hashFile);
  logger.info('Copying files from list: $listFile to $destDir');
  final files = <Map<String, String>>[];

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (await FileSystemEntity.isDirectory(trimmed)) continue;
    final relPath = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    final destPath = destDir.endsWith('/')
        ? '$destDir$relPath'
        : '$destDir/$relPath';
    await Directory(
      destPath.substring(0, destPath.lastIndexOf('/')),
    ).create(recursive: true);
    files.add({'source': trimmed, 'dest': destPath});
  }

  final cpuCount = threadCount ?? Platform.numberOfProcessors;
  final fileQueue = List<Map<String, String>>.from(files);
  final int totalFiles = fileQueue.length;
  logger.info('Total files to copy: $totalFiles using $cpuCount threads.');
  final hashLines = <String>[];
  final receivePort = ReceivePort();
  final copied = <String>[];
  final errored = <String>[];
  final overallThrottle = Stopwatch()..start();
  const overallUpdateMs = 250;
  int active = 0;
  bool done = false;
  final multi = _MultiProgress(totalFiles: totalFiles);

  void startNext() {
    if (fileQueue.isEmpty) {
      if (active == 0 && !done) {
        done = true;
        receivePort.close();
      }
      return;
    }
    final file = fileQueue.removeAt(0);
    active++;
    Isolate.spawn(_copyFileEntrySingleWriter, [file, receivePort.sendPort]);
  }

  for (int i = 0; i < cpuCount && fileQueue.isNotEmpty; i++) {
    startNext();
  }

  await for (final msg in receivePort) {
    if (msg is Map && msg['type'] == 'done') {
      // File finished
      final dest = (msg['dest'] ?? '') as String;
      multi.done(dest);
      multi.incrementCompleted();
      multi.render();
      active--;
      startNext();
      if (fileQueue.isEmpty && active == 0 && !done) {
        done = true;
        receivePort.close();
      }
    } else if (msg == 'done') {
      // Backward-compat if any isolate still sends bare 'done'
      multi.incrementCompleted();
      multi.render();
      active--;
      startNext();
      if (fileQueue.isEmpty && active == 0 && !done) {
        done = true;
        receivePort.close();
      }
    } else if (msg is String) {
      hashLines.add(msg);
      // Log successful copy (extract file path from hash line)
      final parts = msg.split('  ');
      if (parts.length == 2) {
        final copiedPath = parts[1].trim();
        logger.info('Copied file: $copiedPath');
        copied.add(copiedPath);
      }
    } else if (msg is Map && msg['type'] == 'progress') {
      final dest = (msg['dest'] ?? '') as String;
      final copiedNow = (msg['copied'] ?? 0) as int;
      final total = (msg['total'] ?? 0) as int;
      multi.update(dest, copiedNow, total);
      if (overallThrottle.elapsedMilliseconds >= overallUpdateMs) {
        multi.render();
        overallThrottle.reset();
      }
    } else if (msg is _CopyFileError) {
      logger.severe('Error copying file ${msg.file['source']}: ${msg.error}');
      errored.add(msg.file['source'] ?? '');
    }
  }

  if (hashLines.isNotEmpty) {
    final sha1File = File(hashFile);
    await sha1File.writeAsString(hashLines.join(''), mode: FileMode.append);
    logger.info('Hashes written to $hashFile');
  }

  if (saveLists) {
    final copiedFile = File(
      destDir.endsWith('/') ? '${destDir}copied.txt' : '$destDir/copied.txt',
    );
    final erroredFile = File(
      destDir.endsWith('/') ? '${destDir}errored.txt' : '$destDir/errored.txt',
    );
    if (copied.isNotEmpty) {
      await copiedFile.writeAsString('${copied.join('\n')}\n');
      logger.info('Copied file list written to ${copiedFile.path}');
    } else {
      await copiedFile.writeAsString('');
    }
    if (errored.isNotEmpty) {
      await erroredFile.writeAsString('${errored.join('\n')}\n');
      logger.info('Errored file list written to ${erroredFile.path}');
    } else {
      await erroredFile.writeAsString('');
    }
  }
}

class _MultiProgress {
  final _items = <String, _PBItem>{};
  final int totalFiles;
  int _completedFiles = 0;
  int _renderedLines = 0;
  bool _cursorHidden = false;

  _MultiProgress({required this.totalFiles});

  void update(String key, int copied, int total) {
    _items[key] = _PBItem(copied: copied, total: total, name: key);
  }

  void done(String key) {
    _items.remove(key);
    render();
    if (_items.isEmpty) {
      _showCursor();
    }
  }

  void incrementCompleted() {
    _completedFiles++;
  }

  void render() {
    // Move cursor up to start of previous render
    if (_renderedLines > 0) {
      stdout.write('\u001B[' + _renderedLines.toString() + 'A');
    }
    if (!_cursorHidden) {
      stdout.write('\u001B[?25l'); // hide cursor
      _cursorHidden = true;
    }
    final bars = <String>[];
    // Stable order
    final keys = _items.keys.toList()..sort();
    for (final k in keys) {
      bars.add(_formatBar(_items[k]!));
    }
    // Overall bar last
    bars.add(_formatOverallBar());
    // Clear and print
    for (var i = 0; i < _renderedLines; i++) {
      stdout.writeln('\u001B[2K');
    }
    for (final line in bars) {
      stdout.writeln(line);
    }
    _renderedLines = bars.length;
    if (_items.isEmpty) {
      // Show cursor even while keeping overall bar visible
      _showCursor();
    }
  }

  String _formatBar(_PBItem item) {
    final width = 28;
    final total = item.total == 0 ? 1 : item.total;
    final ratio = (item.copied / total).clamp(0, 1);
    final filled = (ratio * width).round();
    final bar = '${'█' * filled}${'.' * (width - filled)}';
    final pct = (ratio * 100).toStringAsFixed(1).padLeft(5);
    final name = _basename(item.name);
    return '$name : $bar ${_human(item.copied)}/${_human(total)} ${pct}%';
  }

  String _basename(String path) {
    final idx = path.lastIndexOf('/');
    if (idx >= 0) return path.substring(idx + 1);
    return path;
  }

  String _human(int n) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = n.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return (u == 0 ? n.toString() : v.toStringAsFixed(1)) + units[u];
  }

  void _showCursor() {
    if (_cursorHidden) {
      stdout.write('\u001B[?25h');
      _cursorHidden = false;
    }
  }

  String _formatOverallBar() {
    final width = 28;
    final total = totalFiles == 0 ? 1 : totalFiles;
    final ratio = (_completedFiles / total).clamp(0, 1);
    final filled = (ratio * width).round();
    final bar = '${'█' * filled}${'.' * (width - filled)}';
    final pct = (ratio * 100).toStringAsFixed(1).padLeft(5);
    return 'Overall: $bar  $_completedFiles/$totalFiles ${pct}%';
  }
}

class _PBItem {
  final int copied;
  final int total;
  final String name;
  _PBItem({required this.copied, required this.total, required this.name});
}

// Worker isolate entry: copies file, computes hash, sends hash line back
void _copyFileEntrySingleWriter(List args) async {
  final Map<String, String> file = args[0];
  final SendPort sendPort = args[1];
  try {
    final source = File(file['source']!);
    final dest = File(file['dest']!);
    final total = await source.length();
    var copiedBytes = 0;
    final out = dest.openWrite();
    final throttle = Stopwatch()..start();
    const updateMs = 100;
    // Hash while streaming
    final capture = _DigestCaptureSink();
    final hasher = sha1.startChunkedConversion(capture);
    await for (final chunk in source.openRead()) {
      out.add(chunk);
      hasher.add(chunk);
      copiedBytes += chunk.length;
      if (throttle.elapsedMilliseconds >= updateMs) {
        sendPort.send({
          'type': 'progress',
          'dest': file['dest'],
          'copied': copiedBytes,
          'total': total,
        });
        throttle.reset();
      }
    }
    await out.close();
    hasher.close();
    final digest = capture.digest!;
    final hashLine = '${digest.toString()}  ${file['dest']!}\n';
    sendPort.send(hashLine);
  } catch (e, st) {
    sendPort.send(_CopyFileError(error: e, stackTrace: st, file: file));
  } finally {
    sendPort.send({'type': 'done', 'dest': file['dest']});
  }
}

class _CopyFileError {
  final Object error;
  final StackTrace stackTrace;
  final Map<String, String> file;

  _CopyFileError({
    required this.error,
    required this.stackTrace,
    required this.file,
  });
}

class _DigestCaptureSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

Future<Result<void>> copyFile(
  String sourceFile,
  String destFile,
  String hashFile,
) async {
  try {
    final source = File(sourceFile);
    final dest = File(destFile);
    final List<int> bytes = [];
    final input = source.openRead();
    final output = dest.openWrite();

    await for (final chunk in input) {
      output.add(chunk);
      bytes.addAll(chunk);
    }
    await output.close();

    final digest = sha1.convert(bytes);

    final sha1File = File(hashFile);
    await sha1File.writeAsString(
      '${digest.toString()}  $destFile\n',
      mode: FileMode.append,
    );
    return Result.success(null);
  } catch (exception, stackTrace) {
    return Result.failure(exception, stackTrace);
  }
}

Future<void> deleteFile(String filePath) async {
  final file = File(filePath);
  if (await file.exists()) {
    await file.delete();
  }
}

Future<void> deleteDirectory(String dirPath) async {
  final dir = Directory(dirPath);
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
