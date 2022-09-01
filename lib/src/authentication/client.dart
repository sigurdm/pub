// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:http_parser/http_parser.dart';

import '../system_cache.dart';

/// Adds authentication for [hostedUrl] headers to a copy of [headers].
///
/// Importantly, requests to URLs not under [hostedUrl] will not be
/// authenticated.
Future<Map<String, String>> addAuthHeader(
  Map<String, String> headers,
  SystemCache systemCache, {
  required String hostedUrl,
  required String urlToFetch,
}) async {
  final credential = systemCache.tokenStore.findCredential(hostedUrl);
  if (credential == null) {
    return headers;
  }
  return {
    ...headers,
    if (credential.canAuthenticate(urlToFetch))
      HttpHeaders.authorizationHeader:
          await credential.getAuthorizationHeaderValue(),
  };
}

/// Parse the message from WWW-Authenticate header according to
/// [RFC 7235 section 4.1][RFC] specifications.
///
/// [RFC]: https://datatracker.ietf.org/doc/html/rfc7235#section-4.1
String? extractServerMessage(Map<String, String> headers) {
  if (headers.containsKey(HttpHeaders.wwwAuthenticateHeader)) {
    try {
      final header = headers[HttpHeaders.wwwAuthenticateHeader]!;
      final challenge = AuthenticationChallenge.parseHeader(header)
          .firstWhereOrNull((challenge) =>
              challenge.scheme == 'bearer' &&
              challenge.parameters['realm'] == 'pub' &&
              challenge.parameters['message'] != null);
      if (challenge != null) {
        final rawMessage = challenge.parameters['message']!;
        // Only allow printable ASCII, map anything else to whitespace, take
        // at-most 1024 characters.
        return String.fromCharCodes(rawMessage.runes
            .map((r) => 32 <= r && r <= 127 ? r : 32)
            .take(1024));
      }
    } on FormatException {
      // Ignore errors might be caused when parsing invalid header values
    }
  }
  return null;
}
