// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import '../command.dart';
import '../http.dart';
import '../log.dart' as log;
import '../oauth2.dart' as oauth2;
import '../utils.dart';

/// Handles the `login` pub command.
class LoginCommand extends PubCommand {
  @override
  String get name => 'login';
  @override
  String get description => 'Log into pub.dev.';
  @override
  String get invocation => 'pub login';

  LoginCommand();

  @override
  Future<void> runProtected() async {
    final credentials = oauth2.loadCredentials(cache);
    final userInfo = await _retrieveUserInfo();
    if (userInfo == null) {
      fail('Your credentials seems broken.\n'
          'Run `pub logout` to delete your credentials  and try again.');
    }
    if (credentials == null) {
      log.message('You are now logged in as $userInfo');
    } else {
      log.warning('You are already logged in as $userInfo\n'
          'Run `pub logout` to log out and try again.');
    }
  }

  Future<_UserInfo?> _retrieveUserInfo() async {
    final credentials = await oauth2.getCredentials(cache);
    print(credentials.accessToken);
    try {
      final discovery = await fetch(
          'https://accounts.google.com/.well-known/openid-configuration',
          headers: {}, //{'authorization': 'Bearer ${credentials.accessToken}'},
          decode: parseJsonResponse);
      final userInfoEndpoint = discovery['userinfo_endpoint'];
      print(userInfoEndpoint);
      if (userInfoEndpoint is! String) return null;
      final userInfo = await fetch(userInfoEndpoint,
          headers: {'authorization': 'Bearer ${credentials.accessToken}'},
          decode: parseJsonResponse);
      print(userInfo);
      final name = userInfo['name'];
      final email = userInfo['email'];
      if (name is! String || email is! String) return null;
      return _UserInfo(name, email);
    } on FetchException catch (e) {
      print(e);
      return null;
    }
  }
}

class _UserInfo {
  final String name;
  final String email;
  _UserInfo(this.name, this.email);
  @override
  String toString() => ['<$email>', name].join(' ');
}
