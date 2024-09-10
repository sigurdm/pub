// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import '../command.dart';
import '../log.dart';

import 'package:path/path.dart' as p;

class WorkspaceListCommand extends PubCommand {
  @override
  String get description =>
      'List all packages in the workspace, and their directory';

  @override
  String get name => 'list';

  WorkspaceListCommand() {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'output information in a json format',
    );
  }

  @override
  void runProtected() {
    if (argResults.flag('json')) {
      message(
        const JsonEncoder.withIndent('  ').convert({
          'packages': [
            ...entrypoint.workspaceRoot.transitiveWorkspace.map(
              (package) => {
                'name': package.name,
                'path': p.canonicalize(package.dir),
              },
            ),
          ],
        }),
      );
    } else {
      for (final package in entrypoint.workspaceRoot.transitiveWorkspace) {
        message('${package.name}: ${p.relative(p.absolute(package.dir))}');
      }
    }
  }
}
