// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:test_process/test_process.dart';

import 'test_pub.dart';

Future<TestProcess> startPubUploader(PackageServer server, List<String> args) {
  var tokenEndpoint = Uri.parse(server.url).resolve('/token').toString();
  var allArgs = ['uploader', ...args];
  return startPub(
      args: allArgs,
      tokenEndpoint: tokenEndpoint,
      environment: {'PUB_HOSTED_URL': tokenEndpoint});
}

void main() {}
