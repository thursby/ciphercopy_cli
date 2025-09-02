import 'dart:io';
import 'package:crypto/crypto.dart';

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
Future<void> copyFilesFromList(String listFile, String destDir) async {
  final lines = await File(listFile).readAsLines();
  final hashFile =
      '${destDir.endsWith('/') ? destDir.substring(0, destDir.length - 1) : destDir}.sha1';
  await deleteFile(hashFile);
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (await FileSystemEntity.isDirectory(trimmed)) continue;
    // Try to preserve the relative path if possible
    final relPath = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    final destPath = destDir.endsWith('/')
        ? '$destDir$relPath'
        : '$destDir/$relPath';
    await Directory(
      destPath.substring(0, destPath.lastIndexOf('/')),
    ).create(recursive: true);
    await copyFile(trimmed, destPath, hashFile);
  }
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
