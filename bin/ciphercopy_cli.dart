import 'dart:io';
import 'package:ansicolor/ansicolor.dart';
import 'package:args/args.dart';
import 'package:ciphercopy_cli/ciphercopy_cli.dart' as ciphercopy_cli;

void main(List<String> arguments) async {
  final redPen = AnsiPen()..red(bold: true);
  final greenPen = AnsiPen()..green(bold: true);
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
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
      'Copy files listed in a file to a destination directory, preserving paths. While files are being copied, their SHA-1 hashes are computed and written to a .sha1 file in the destination directory.',
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
      'Usage: dart run bin/ciphercopy_cli.dart <list_file> <destination_directory>',
    );
    print(parser.usage);
    exit(64); // EX_USAGE
  }
  final listFile = rest[0];
  final destDir = rest[1];
  try {
    await ciphercopy_cli.copyFilesFromList(listFile, destDir);
    print(greenPen('Files copied and hashes written successfully.'));
  } catch (error, stackTrace) {
    print(redPen('Error: $error\n$stackTrace'));
    exit(2);
  }
}
