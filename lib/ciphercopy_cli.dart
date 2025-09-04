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
  final hashLines = <String>[];
  final receivePort = ReceivePort();
  final copied = <String>[];
  final errored = <String>[];
  int active = 0;
  bool done = false;

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
    if (msg == 'done') {
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
    } else if (msg is _CopyFileError) {
      logger.severe('Error copying file ${msg.file['source']}: ${msg.error}');
      errored.add(msg.file['source'] ?? '');
    }
  }

  // Write all hash lines at once (or could append as received)
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

// Worker isolate entry: copies file, computes hash, sends hash line back
void _copyFileEntrySingleWriter(List args) async {
  final Map<String, String> file = args[0];
  final SendPort sendPort = args[1];
  try {
    final source = File(file['source']!);
    final dest = File(file['dest']!);
    final List<int> bytes = await source.readAsBytes();
    await dest.writeAsBytes(bytes);
    final digest = sha1.convert(bytes);
    final hashLine = '${digest.toString()}  ${file['dest']!}\n';
    sendPort.send(hashLine);
  } catch (e, st) {
    sendPort.send(_CopyFileError(error: e, stackTrace: st, file: file));
  } finally {
    sendPort.send('done');
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
