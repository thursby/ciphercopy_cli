import 'dart:io';
import 'package:ansicolor/ansicolor.dart';
import 'package:args/args.dart';
import 'package:ciphercopy_cli/ciphercopy_cli.dart' as ciphercopy_cli;
import 'package:ciphercopy_cli/ciphercopy_logger.dart';

String logo =
    '  ______ ___  __ _________  ________  _____  __\n'
    ' ╱ ___(_) _ ╲╱ ╱╱ ╱ __╱ _ ╲╱ ___╱ _ ╲╱ _ ╲ ╲╱ ╱\n'
    '╱ ╱__╱ ╱ ___╱ _  ╱ _╱╱ , _╱ ╱__╱ (/ ╱ ___╱╲  ╱ \n'
    '╲___╱_╱_╱  ╱_╱╱_╱___╱_╱│_│╲___╱╲___╱_╱    ╱_╱  \n'
    'CiPHERC0PY';

void main(List<String> arguments) async {
  final redPen = AnsiPen()..red(bold: true);
  final greenPen = AnsiPen()..green(bold: true);
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    )
    ..addOption(
      'threads',
      abbr: 't',
      help:
          'Number of concurrent threads to use. Default: number of CPU cores.',
      valueHelp: 'count',
    );

  ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } catch (e) {
    print(redPen('Argument error: $e'));
    print('');
    print('Usage:');
    print(parser.usage);
    exit(64); // EX_USAGE
  }

  if (argResults['help'] as bool) {
    print(
      '${logo}Copy files listed in a file to a destination directory, preserving paths. While files are being copied, their SHA-1 hashes are computed and written to a .sha1 file in the destination directory.',
    );
    print('');
    print(
      'Usage: dart run bin/ciphercopy_cli.dart <list_file> <destination_directory>',
    );
    print(parser.usage);
    exit(0);
  }

  final rest = argResults.rest;
  if (rest.length != 2) {
    print(redPen('Error: Missing required arguments.'));
    print('');
    print(
      '${logo}Usage: dart run bin/ciphercopy_cli.dart <list_file> <destination_directory>',
    );
    print(parser.usage);
    exit(64); // EX_USAGE
  }
  final listFile = rest[0];
  final destDir = rest[1];
  final logPath = await initLogging(destDir);
  int? threadCount;
  if (argResults.wasParsed('threads')) {
    final threadStr = argResults['threads'] as String?;
    if (threadStr != null && threadStr.isNotEmpty) {
      final parsed = int.tryParse(threadStr);
      if (parsed == null || parsed < 1) {
        print(redPen('Error: --threads must be a positive integer.'));
        exit(64);
      }
      threadCount = parsed;
    }
  }

  try {
    logger.info(
      'Starting copy from list: $listFile to $destDir using $threadCount threads.',
    );
    await ciphercopy_cli.copyFilesFromList(
      listFile,
      destDir,
      threadCount: threadCount,
    );
    logger.info('Files copied and hashes written successfully.');
    print(greenPen('Files copied and hashes written successfully.'));
  } catch (error, stackTrace) {
    logger.severe('Error: $error', error, stackTrace);
    print(redPen('Error: $error\n$stackTrace'));
    exit(2);
  } finally {
    await shutdownLogging();
    print('Log written to: $logPath');
  }
}
