// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Helpers for dealing with HTTP.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:pool/pool.dart';
import 'package:source_span/source_span.dart';

import 'command.dart';
import 'crc32c.dart';
import 'io.dart';
import 'log.dart' as log;
import 'package.dart';
import 'sdk.dart';
import 'utils.dart';

Future<String> decodeString(
  Stream<List<int>> stream,
  Map<String, String> headers,
) =>
    utf8.decodeStream(stream);

Pool _pool = Pool(16);
int _maxRetries =
    int.tryParse(Platform.environment['PUB_MAX_HTTP_RETRIES'] ?? '') ?? 8;
Duration timeout = Duration(seconds: 10);

/// Sends a http request to [url] with the given [headers] and [method].
///
/// Decodes the response body with [decode].
///
/// [decode] is expected to be idempotent. It should always consume the entire
/// stream.
///
/// [decode] is supposed to throw a [FormatException] if the body cannot be
/// decoded, and it is likely due to a corrupted download. Other exceptions will
/// cause a retry.
///
/// If the response after redirects is not 2xx a [FetchException] will be
/// thrown.
///
/// If the response error code is 4xx (though not 406 or 426) and [decodeErrors]
/// is given it will be run to decode the error message. It should be idempotent
/// and throw FormatException if the request should be retried.
///
/// If [body] is passed it should return a stream of the bytes that will be the
/// body of the request. It should be idempotent.
///
/// If [body] is not passed the request will have an empty body.
///
/// If [maxBytes] is passed and the contentLength (or the decompressed body if
/// the response has no content-length) of the response is larger than that many
/// bytes, a [FetchException] will be thrown.
///
/// if [handleJsonErrors] is `true` error messages from the server will be
/// displayed according to `doc/repository-spec-v2.md`.
///
/// Metadata headers are added to the request with [_metadata] if
/// [_shouldAddMetadata].
///
/// The number of concurrent requests via this method is throttled.
///
/// If the response has a x-goog-hash header with a 'crc32c=' value that will be
/// validated.
///
/// ## Timeout behavior:
///
/// * The request times out if headers have not arrived after 30 seconds.
///
/// * The request times out if in the last minute less data has been received
///   than what would make the request take more than 3 hours to complete.
///
/// If the request times out the request is retried.
///
/// ## Retry behavior
///
/// Will try [_maxRetries] times at most. Will do back-off according to
/// [_delay].
///
/// The underlying http client of dart:io will check the content-length of the
/// response (a too long response is cut off at content-length, a too short will
/// result in a FetchException).
Future<T> fetch<T>(
  String url, {
  String method = 'GET',
  required Map<String, String> headers,
  required Future<T> Function(Stream<List<int>>, Map<String, String>) decode,
  Stream<List<int>> Function()? body,
  int? maxBytes,
  Future<Never> Function(
    int statusCode,
    Stream<List<int>> body,
    Map<String, String> headers,
  )?
      decodeError,
  bool followRedirects = true,
}) async {
  /// Will find and parse the crc32c checksum from a x-goog-hash header (if
  /// present). Returns null if no header was present.
  ///
  /// Will throw a [FetchException] if the header is present but malformed.
  int? _parseCrc32cHeader(Map<String, String> headers) {
    final header = headers['x-goog-hash'];
    if (header == null) return null;

    final crc32header = header
        .split(',')
        .firstWhereOrNull((line) => line.startsWith('crc32c='));
    if (crc32header != null) {
      final expectedChecksumBytes =
          base64Decode(crc32header.substring('crc32c='.length));
      if (expectedChecksumBytes.length != 4) {
        throw FetchException(url,
            message: 'Bad checksum header', canBeRetried: true);
      }
      // This reads the value as big-endian.
      return ByteData.view(expectedChecksumBytes.buffer).getUint32(0);
    }
    return null;
  }

  /// Passes through the contents of [stream] while keeping track of the content
  /// length, and the delivery rate and maintaining a checksum.
  Stream<List<int>> _checkStream(Stream<List<int>> stream,
      int? expectedChecksum, int? contentLength) async* {
    /// How many bytes has been downloaded yet.
    var length = 0;

    /// How many bytes was downloaded last time [timer] ran.
    var lastLength = 0;
    var timeout = false;
    final timer = Timer.periodic(Duration(minutes: 1), (timer) {
      final sinceLast = length - lastLength;

      if (contentLength != null && (contentLength - length) / sinceLast > 180) {
        timeout = true;
      }
      lastLength = length;
    });

    final crc32 = expectedChecksum == null ? null : Crc32c();
    try {
      await for (final value in stream) {
        if (timeout) {
          throw FetchException(url,
              message:
                  'Download stalled, only received few bytes in the last minute.',
              canBeRetried: true);
        }
        length += value.length;
        if (crc32 != null) {
          crc32.update(value);
        }
        yield value;
      }
    } on IOException catch (e, st) {
      // If an exception happens while streaming the body we catch it here.
      throw FetchException(url,
          innerException: e, innerStackTrace: st, canBeRetried: true);
    }
    timer.cancel();
    if (crc32 != null && expectedChecksum != crc32.finalize()) {
      throw FetchException(
        url,
        message: 'Checksum mismatch',
        canBeRetried: true,
      );
    }
  }

  final uri = Uri.parse(url);
  final requestHeaders = {
    ...headers,
    if (_shouldAddMetadata(uri)) ..._metadata(),
    HttpHeaders.userAgentHeader: 'Dart pub ${sdk.version}',
  };

  int attempts = 0;
  final requestIdentity = Object();
  _requestStopwatches[requestIdentity] = Stopwatch()..start();
  // Retry until success or the retry-logic says enough is enough.
  while (true) {
    try {
      return await _pool.withResource(() async {
        _logRequest(url, method, requestHeaders);
        late final http.StreamedResponse response;

        try {
          final request = http.StreamedRequest(method, uri);
          request.headers.addAll(requestHeaders);

          request.followRedirects = followRedirects;
          if (body != null) {
            // TODO: handle errors from the body.
            body().listen(request.sink.add, onDone: request.sink.close);
          } else {
            request.sink.close();
          }

          response = await innerHttpClient
              .send(request)
              .timeout(Duration(seconds: 30), onTimeout: () {
            // TODO(sigurdm): Implement cancellation of requests. This probably
            // requires resolution of: https://github.com/dart-lang/sdk/issues/22265.
            throw FetchException(
              url,
              message: 'Request timed out.',
              canBeRetried: true,
            );
          });
          _logResponse(method, url, response, requestIdentity);
        } on IOException catch (error, st) {
          throw FetchException(
            url,
            message: 'Caught connection error',
            innerException: error,
            innerStackTrace: st,
            canBeRetried: true,
          );
        }
        final status = response.statusCode;
        if (status == 406 &&
            requestHeaders['Accept'] == pubApiHeaders['Accept']) {
          throw await FetchExceptionWithResponse.fromResponse(
            url,
            response,
            message:
                'Pub ${sdk.version} is incompatible with the current version of '
                '${uri.host}.\n'
                'Upgrade pub to the latest version and try again.',
          );
        } else if (status == 429) {
          final retryAfterHeader = response.headers['Retry-After'];
          final retryAfterSeconds =
              retryAfterHeader == null ? null : int.tryParse(retryAfterHeader);
          if (retryAfterSeconds != null && retryAfterSeconds > 30) {
            // Don't retry here. Just quit
            throw await FetchExceptionWithResponse.fromResponse(
              url,
              response,
              message:
                  'Server overloaded, response 429. Retry after $retryAfterSeconds seconds',
            );
          }
          throw await FetchExceptionWithResponse.fromResponse(url, response,
              message: 'Too many requests',
              retryAfter: retryAfterSeconds == null
                  ? null
                  : Duration(seconds: retryAfterSeconds),
              canBeRetried: true);
        } else if (status >= 400 && status < 500) {
          if (decodeError == null) {
            print(await utf8.decodeStream(response.stream));
            throw await FetchExceptionWithResponse.fromResponse(url, response);
          } else {
            await decodeError(status, response.stream, headers);
          }
        } else if (status >= 500 && status < 600) {
          throw await FetchExceptionWithResponse.fromResponse(
            url,
            response,
            message: 'HTTP error $status: Internal Server Error at $uri.\n'
                'This is likely a transient error. Please try again later.',
            canBeRetried: true,
          );
        }

        final expectedChecksum = _parseCrc32cHeader(response.headers);

        final contentLength = response.contentLength;
        if (maxBytes != null &&
            contentLength != null &&
            maxBytes < contentLength) {
          throw FetchException(url, message: 'Response too large.');
        }

        late final T result;
        try {
          result = await decode(
              _checkStream(
                  response.stream, expectedChecksum, response.contentLength),
              response.headers);
        } on FormatException catch (e, st) {
          throw FetchException(url,
              message: 'Invalid server response.',
              innerException: e,
              innerStackTrace: st,
              canBeRetried: true);
        }
        return result;
      });
    } on FetchException catch (e) {
      if (!e.canBeRetried) rethrow;
      if (_maxRetries <= attempts) rethrow;

      log.io('Retry #${attempts + 1} for '
          '$method $url...');
      if (attempts == 3 && _retriedHosts.add(uri.host)) {
        log.message('It looks like ${uri.host} is having some trouble.\n'
            'Pub will wait for a while before trying to connect again.');
      }
      log.fine('Retrying fetching $url (${e.message})');
      await Future.delayed(e.retryAfter ?? _delay(attempts));
      attempts++;
    }
  }
}

Map<String, String> _metadata() {
  final environment = Platform.environment['PUB_ENVIRONMENT'];
  final type = Zone.current[#_dependencyType];
  return {
    'X-Pub-OS': Platform.operatingSystem,
    'X-Pub-Command': PubCommand.command,
    'X-Pub-Session-ID': _sessionId,
    if (environment != null) 'X-Pub-Environment': environment,
    if (type != null && type != DependencyType.none)
      'X-Pub-Reason': type.toString()
  };
}

/// Computes the delay to wait after the given number of retries.
///
/// Will initially do exponential
///   back-off with a delay of 0.5 * 1.5^[retryCount] + randomness.
///
/// After the first 3 attempts takes a 30 seconds pause each time.
Duration _delay(int retryCount) {
  if (retryCount < 3) {
    // Retry quickly a couple times in case of a short transient error.
    //
    // Add a random delay to avoid retrying a bunch of parallel requests
    // all at the same time.
    return Duration(milliseconds: 500) * math.pow(1.5, retryCount) +
        Duration(milliseconds: random.nextInt(500));
  } else {
    // If the error persists, wait a long time. This works around issues
    // where an AppEngine instance will go down and need to be rebooted,
    // which takes about a minute.
    return Duration(seconds: 30);
  }
}

/// Headers and field names that should be censored in the log output.
const _censoredFields = ['refresh_token', 'authorization'];

/// Headers required for pub.dartlang.org API requests.
///
/// The Accept header tells pub.dartlang.org which version of the API we're
/// expecting, so it can either serve that version or give us a 406 error if
/// it's not supported.
const pubApiHeaders = {'Accept': 'application/vnd.pub.v2+json'};

/// A unique ID to identify this particular invocation of pub.
final _sessionId = createUuid();

/// Whether extra metadata headers should be added to [request].
bool _shouldAddMetadata(Uri uri) {
  if (runningFromTest && Platform.environment.containsKey('PUB_HOSTED_URL')) {
    if (uri.origin != Platform.environment['PUB_HOSTED_URL']) {
      return false;
    }
  } else {
    if (uri.origin != 'https://pub.dartlang.org') return false;
  }

  if (Platform.environment.containsKey('CI') &&
      Platform.environment['CI'] != 'false') {
    return false;
  }
  return true;
}

/// Logs the fact that a request was sent, and information about it.
void _logRequest(
  String url,
  String method,
  Map<String, String> headers,
) {
  var requestLog = StringBuffer();
  requestLog.writeln('HTTP $method $url');
  headers.forEach((name, value) => requestLog.writeln(_logField(name, value)));

  log.io(requestLog.toString().trim());
}

/// Logs the fact that [response] was received, and information about it.
void _logResponse(
  String method,
  String url,
  http.StreamedResponse response,
  Object requestIdentity,
) {
  // TODO(nweiz): Fork the response stream and log the response body. Be
  // careful not to log OAuth2 private data, though.

  var responseLog = StringBuffer();
  var stopwatch = _requestStopwatches.remove(requestIdentity)!..stop();
  responseLog.writeln('HTTP response ${response.statusCode} '
      '${response.reasonPhrase} for $method $url');
  responseLog.writeln('took ${stopwatch.elapsed}');
  response.headers
      .forEach((name, value) => responseLog.writeln(_logField(name, value)));

  log.io(responseLog.toString().trim());
}

/// Returns a log-formatted string for the HTTP field or header with the given
/// [name] and [value].
String _logField(String name, String value) {
  if (_censoredFields.contains(name.toLowerCase())) {
    return '$name: <censored>';
  } else {
    return '$name: $value';
  }
}

final _requestStopwatches = <Object, Stopwatch>{};

/// A set of all hostnames for which we've printed a message indicating that
/// we're waiting for them to come back up.
final _retriedHosts = <String>{};

/// The underlying [http.Client] used by [fetch]. Can be overridden from tests.
http.Client innerHttpClient = http.Client();

/// Runs [callback] in a zone where all HTTP requests sent to `pub.dartlang.org`
/// will indicate the [type] of the relationship between the root package and
/// the package being requested.
///
/// If [type] is [DependencyType.none], no extra metadata is added.
Future<T> withDependencyType<T>(
  DependencyType type,
  Future<T> Function() callback,
) {
  return runZoned(callback, zoneValues: {#_dependencyType: type});
}

/// Parses a response body, assuming it's JSON-formatted.
///
/// Throws a user-friendly error if the response body is invalid JSON, or if
/// it's not a map.
Future<Map<String, Object?>> parseJsonResponse(
    Stream<List<int>> stream, Map<String, String> headers) async {
  final Object? value =
      await Utf8Decoder().fuse(JsonDecoder()).bind(stream).first;

  if (value is Map<String, Object?>) return value;
  throw FormatException('Did not encode a map');
}

/// Throws an error describing an invalid response from the server.
Never invalidServerResponse(String response) =>
    fail(log.red('Invalid server response:\n$response'));

/// Exception thrown when an HTTP operation fails.
class FetchException implements Exception {
  final String url;
  final String? message;
  final bool canBeRetried;
  final Duration? retryAfter;
  final Exception? innerException;
  final StackTrace? innerStackTrace;

  const FetchException(this.url,
      {this.message,
      this.canBeRetried = false,
      this.innerException,
      this.innerStackTrace,
      this.retryAfter});

  @override
  String toString() {
    final messagePart = message == null ? '' : ' $message';

    if (innerException != null) {
      return 'HTTP error ${innerException.toString()}: $messagePart';
    }
    return message!;
  }
}

/// This exception can be thrown when the response arrived but is not successful.
class FetchExceptionWithResponse extends FetchException {
  final int status;
  final Map<String, String> headers;
  final String? reasonPhrase;
  final String responseBody;

  static Future<FetchExceptionWithResponse> fromResponse(
          String url, http.StreamedResponse response,
          {String? message,
          bool canBeRetried = false,
          Duration? retryAfter}) async =>
      FetchExceptionWithResponse._(
          url,
          message,
          canBeRetried,
          retryAfter,
          response.statusCode,
          response.headers,
          response.reasonPhrase,
          await Utf8Codec(allowMalformed: true).decodeStream(response.stream));

  FetchExceptionWithResponse._(
      String url,
      String? message,
      bool canBeRetried,
      Duration? retryAfter,
      this.status,
      this.headers,
      this.reasonPhrase,
      this.responseBody)
      : super(url,
            message: message,
            canBeRetried: canBeRetried,
            retryAfter: retryAfter);

  @override
  String toString() {
    final messagePart = message == null ? '' : ' $message';
    return 'HTTP error $status: $reasonPhrase$messagePart';
  }
}

/// Handles an unsuccessful JSON-formatted response from pub.dev.
///
/// These responses are expected to be of the form `{"error": {"message": "some
/// message"}}`. If the format is correct, the message will be raised as an
/// error; otherwise an [invalidServerResponse] error will be raised.
Future<Never> handleJsonError(
  int status,
  Stream<List<int>> stream,
  Map<String, String> headers,
) async {
  final s = await utf8.decodeStream(stream);
  final errorMap = json.decode(s);

  if (errorMap is! Map ||
      errorMap['error'] is! Map ||
      !errorMap['error'].containsKey('message') ||
      errorMap['error']['message'] is! String) {
    invalidServerResponse(s);
  }
  fail(log.red(errorMap['error']['message']));
}
