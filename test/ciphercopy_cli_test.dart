import 'dart:io';

import 'package:ciphercopy_cli/ciphercopy_cli.dart' as ciphercopy_cli;
import 'package:test/test.dart';

void main() {
  test('hardcoded files', () async {
    await ciphercopy_cli.deleteFile('./testfiles/hardcoded/list2.txt');
    await ciphercopy_cli.deleteFile('./testfiles/hardcoded/test.sha1');
    String file1 = './testfiles/hardcoded/list.txt';
    String file2 = './testfiles/hardcoded/list2.txt';
    await ciphercopy_cli.copyFile(
      file1,
      file2,
      './testfiles/hardcoded/test.sha1',
    );
    // Assert that the output file exists
    expect(File(file2).existsSync(), isTrue);

    // Assert that the hash file exists
    final hashFile = File('./testfiles/hardcoded/test.sha1');
    expect(hashFile.existsSync(), isTrue);

    // Assert the contents of the hash file
    final hashContents = hashFile.readAsStringSync().trim();
    expect(
      hashContents,
      'bbde2519f76febed0b1d9e4bcf34cf279e8dab66  ./testfiles/hardcoded/list2.txt',
    );

    // Assert that the copied file matches the source file
    final src = File('./testfiles/hardcoded/list.txt').readAsBytesSync();
    final dest = File('./testfiles/hardcoded/list2.txt').readAsBytesSync();
    expect(dest, src);
  });

  test('list', () async {
    await ciphercopy_cli.deleteDirectory('./testfiles/list/dest1');
    await ciphercopy_cli.copyFilesFromList(
      './testfiles/list/list.txt',
      './testfiles/list/dest1',
    );
    // Assert that the output directory exists
    expect(Directory('./testfiles/list/dest1').existsSync(), isTrue);
    expect(
      Directory(
        './testfiles/list/dest1/testfiles/list/test1/dir1',
      ).existsSync(),
      isTrue,
    );
    expect(File('./testfiles/list/dest1.sha1').existsSync(), isTrue);
    expect(
      File(
        './testfiles/list/dest1/testfiles/list/test1/sample-5.webp',
      ).existsSync(),
      isTrue,
    );
  });
}
