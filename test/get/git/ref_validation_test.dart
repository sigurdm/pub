// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'package:pub/src/exit_codes.dart' as exit_codes;
import 'package:pub/src/source/git.dart';
import 'package:test/test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

void main() {
  test('rejects a git ref starting with a hyphen in pubspec', () async {
    await d
        .appDir(
          dependencies: {
            'foo': {
              'git': {'url': '../foo.git', 'ref': '--version'},
            },
          },
        )
        .create();

    await pubGet(
      error: contains(
        '"--version" is not a valid Git ref, it must not start with "-".',
      ),
      exitCode: exit_codes.DATA,
    );
  });

  test('rejects a git ref containing whitespace in pubspec', () async {
    await d
        .appDir(
          dependencies: {
            'foo': {
              'git': {'url': '../foo.git', 'ref': 'main branch'},
            },
          },
        )
        .create();

    await pubGet(
      error: contains(
        '"main branch" is not a valid Git ref, it must not contain '
        'whitespace or control characters.',
      ),
      exitCode: exit_codes.DATA,
    );
  });

  test('rejects a non-hexadecimal resolved-ref in the lockfile', () async {
    await d
        .appDir(
          dependencies: {
            'foo': {
              'git': {'url': '../foo.git'},
            },
          },
        )
        .create();
    await d.dir(appPath, [
      d.file('pubspec.lock', '''
packages:
  foo:
    dependency: "direct main"
    description:
      path: "."
      ref: HEAD
      resolved-ref: "--version"
      url: "../foo.git"
    source: git
    version: "1.0.0"
sdks:
  dart: ">=3.0.2 <4.0.0"
'''),
    ]).create();

    await pubGet(
      error: allOf(
        contains('Failed parsing lock file:'),
        contains(
          "The 'resolved-ref' field of the description must be a hexadecimal "
          'commit id, was "--version".',
        ),
      ),
      exitCode: exit_codes.DATA,
    );
  });

  group('GitDescription', () {
    GitDescription describe(String? ref) => GitDescription(
      url: 'https://example.com/foo.git',
      ref: ref,
      path: '.',
      containingDir: null,
      tagPattern: null,
    );

    test('accepts common refs and revision expressions', () {
      for (final ref in [
        null,
        'main',
        'v1.2.3+build.4',
        'feature/issue#12',
        'release_2026.01',
        '7d48f902b0326fc2ce0615c20f1aab6c811fe55b',
        'HEAD~1',
        'main^',
        '^BAD_REF',
        'origin/main',
        'v1.0.0^{}',
        'grén',
      ]) {
        expect(() => describe(ref), returnsNormally, reason: 'ref: $ref');
      }
    });

    test('rejects refs git could misinterpret', () {
      for (final ref in [
        '',
        '-',
        '--version',
        'main branch',
        'main\tbranch',
        'main\nbranch',
        'main\x00',
        'main\x7f',
      ]) {
        expect(
          () => describe(ref),
          throwsA(isA<FormatException>()),
          reason: 'ref: ${ref.codeUnits}',
        );
      }
    });
  });
}
