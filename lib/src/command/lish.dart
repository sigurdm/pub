// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../ascii_tree.dart' as tree;
import '../authentication/client.dart';
import '../command.dart';
import '../exceptions.dart' show DataException;
import '../exit_codes.dart' as exit_codes;
import '../http.dart';
import '../io.dart';
import '../log.dart' as log;
import '../oauth2.dart' as oauth2;
import '../source/hosted.dart' show validateAndNormalizeHostedUrl;
import '../utils.dart';
import '../validator.dart';

/// Handles the `lish` and `publish` pub commands.
class LishCommand extends PubCommand {
  @override
  String get name => 'publish';
  @override
  String get description => 'Publish the current package to pub.dartlang.org.';
  @override
  String get argumentsDescription => '[options]';
  @override
  String get docUrl => 'https://dart.dev/tools/pub/cmd/pub-lish';
  @override
  bool get takesArguments => false;

  /// The URL of the server to which to upload the package.
  late final Uri server = _createServer();

  Uri _createServer() {
    // An explicit argument takes precedence.
    if (argResults.wasParsed('server')) {
      try {
        return validateAndNormalizeHostedUrl(argResults['server']);
      } on FormatException catch (e) {
        usageException('Invalid server: $e');
      }
    }

    // Otherwise, use the one specified in the pubspec.
    final publishTo = entrypoint.root.pubspec.publishTo;
    if (publishTo != null) {
      try {
        return validateAndNormalizeHostedUrl(publishTo);
      } on FormatException catch (e) {
        throw DataException('Invalid publish_to: $e');
      }
    }

    // Use the default server if nothing else is specified
    return cache.sources.hosted.defaultUrl;
  }

  /// Whether the publish is just a preview.
  bool get dryRun => argResults['dry-run'];

  /// Whether the publish requires confirmation.
  bool get force => argResults['force'];

  LishCommand() {
    argParser.addFlag('dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Validate but do not publish the package.');
    argParser.addFlag('force',
        abbr: 'f',
        negatable: false,
        help: 'Publish without confirmation if there are no errors.');
    argParser.addOption('server',
        help: 'The package server to which to upload this package.',
        hide: true);

    argParser.addOption('directory',
        abbr: 'C', help: 'Run this in the directory<dir>.', valueHelp: 'dir');
  }

  Future<void> _publish(
    String packagePath,
    Map<String, String> headers,
  ) async {
    try {
      await log.progress('Uploading', () async {
        final newUri = server.resolve('api/packages/versions/new');
        late String responseBody;
        late String cloudStorageUrl;
        late Map<String, String> fields;
        try {
          await fetch(
            newUri.toString(),
            headers: {...pubApiHeaders, ...headers},
            decode: (stream, headers) async {
              responseBody = await decodeString(stream, headers);
              late final Object? parameters;
              // try {
              parameters = jsonDecode(responseBody);
              // } on FormatException {
              //   invalidServerResponse(responseBody);
              // }
              if (parameters is! Map) invalidServerResponse(responseBody);
              final url = _expectField<String>(parameters, 'url', responseBody);
              final fieldsMap =
                  _expectField<Map>(parameters, 'fields', responseBody);
              fields = <String, String>{};
              fieldsMap.forEach((key, value) {
                if (value is! String) invalidServerResponse(responseBody);
                fields[key] = value;
              });
              cloudStorageUrl = Uri.parse(url).toString();
            },
            decodeError: handleJsonError,
          );
        } on FetchException {
          invalidServerResponse(responseBody);
        }

        // TODO(nweiz): Cloud Storage can provide an XML-formatted error. We
        // should report that error and exit.

        final finalizeUploadUrl = await fetch(
          cloudStorageUrl,
          method: 'POST',
          body: () async* {
            final request = http.MultipartRequest(
                // These args are never used. We construct the request just to
                // get to the body.
                'POST',
                Uri.parse(cloudStorageUrl));
            request.files.add(await http.MultipartFile.fromPath(
                'file', packagePath,
                filename: 'package.tar.gz'));
            request.fields.addAll(fields);
            yield* request.finalize();
          },
          decode: (stream, headers) async {
            await stream.drain();
            final location = headers['location'];
            if (location == null) {
              invalidServerResponse(
                'Did not provide a location',
              ); // TODO: better error
            }
            return Uri.parse(location).toString();
          },
          headers: {},
          followRedirects: false,
        );

        final message = await fetch(
          finalizeUploadUrl,
          headers: pubApiHeaders,
          decode: (stream, headers) async {
            final responseBody = await utf8.decodeStream(stream);
            final Object? response = jsonDecode(responseBody);
            if (response is! Map ||
                response['success'] is! Map ||
                !response['success'].containsKey('message') ||
                response['success']['message'] is! String) {
              invalidServerResponse(responseBody);
            }

            return response['success']['message'];
          },
          decodeError: handleJsonError,
        );

        /// These response is expected to be of the form `{"success":
        /// {"message": "some message"}}`. If the format is correct, the message
        /// will be printed; otherwise an error will be raised.

        log.message(log.green(message));
      });
    } on FetchException catch (error) {
      if (error is FetchExceptionWithResponse) {
        final serverMessage = extractServerMessage(error.headers);
        final serverMessagePart =
            serverMessage?.isNotEmpty == true ? '\n$serverMessage\n' : '';
        if (error.status == 401) {
          dataError('$server package repository requested authentication!\n'
              'You can provide credentials using:\n'
              '    pub token add $server\n$serverMessagePart${log.red('Authentication failed!')}');
        }
        if (error.status == 403) {
          dataError('Insufficient permissions to the resource at the $server '
              'package repository.\nYou can modify credentials using:\n'
              '    pub token add $server\n$serverMessagePart${log.red('Authentication failed!')}');
        }
        // TODO: what's here?
        // var url = error.response.request!.url;
        // if (url == cloudStorageUrl) {
        //   // TODO(nweiz): the response may have XML-formatted information about
        //   // the error. Try to parse that out once we have an easily-accessible
        //   // XML parser.
        //   fail(log.red('Failed to upload the package.'));
        // } else if (Uri.parse(url.origin) == Uri.parse(server.origin)) {
        //   handleJsonError(await http.Response.fromStream(error.body));
        // } else {
        //   rethrow;
        // }
        fail('${error.message}:\n${error.responseBody}');
      }
      // final message = error.message;
      // if (message != null) {
      //   log.error(message);
      // }
      // final inner = error.innerException;
      // if (inner != null) {
      //   log.exception(inner);
      // }

      fail('${error.message}');
    }
  }

  Future<Map<String, String>> _getAuthorizationHeaders() async {
    final officialPubServers = {
      'https://pub.dartlang.org',
      'https://pub.dev',

      // Pub uses oauth2 credentials only for authenticating official pub
      // servers for security purposes (to not expose pub.dev access token to
      // 3rd party servers).
      // For testing publish command we're using mock servers hosted on
      // localhost address which is not a known pub server address. So we
      // explicitly have to define mock servers as official server to test
      // publish command with oauth2 credentials.
      if (runningFromTest &&
          Platform.environment.containsKey('PUB_HOSTED_URL') &&
          Platform.environment['_PUB_TEST_AUTH_METHOD'] == 'oauth2')
        Platform.environment['PUB_HOSTED_URL'],
    };

    late final Map<String, String> headers;
    // Use the credential token for the server if present.
    final credential = cache.tokenStore.findCredential(server.toString());
    if (credential != null) {
      headers = {
        'authorization': await credential.getAuthorizationHeaderValue()
      };
    } else if (officialPubServers.contains(server.toString())) {
      // Using OAuth2 authentication client for the official pub servers
      final credentials = await oauth2.getCredentials(cache);
      headers = {'authorization': 'Bearer ${credentials.accessToken}'};
    } else {
      headers = {};
    }
    return headers;
  }

  @override
  Future runProtected() async {
    if (argResults.wasParsed('server')) {
      await log.warningsOnlyUnlessTerminal(() {
        log.message(
          '''
The --server option is deprecated. Use `publish_to` in your pubspec.yaml or set
the \$PUB_HOSTED_URL environment variable.''',
        );
      });
    }

    if (force && dryRun) {
      usageException('Cannot use both --force and --dry-run.');
    }

    if (entrypoint.root.pubspec.isPrivate) {
      dataError('A private package cannot be published.\n'
          'You can enable this by changing the "publish_to" field in your '
          'pubspec.');
    }

    var files = entrypoint.root.listFiles();
    log.fine('Archiving and publishing ${entrypoint.root}.');

    // Show the package contents so the user can verify they look OK.
    var package = entrypoint.root;
    log.message('Publishing ${package.name} ${package.version} to $server:\n'
        '${tree.fromFiles(files, baseDir: entrypoint.root.dir)}');

    await withTempDir((dir) async {
      final tempPackagePath = p.join(dir, 'package.tar.gz');
      final file = File(p.join(dir, 'package.tar.gz'));
      final sink = File(p.join(dir, 'package.tar.gz')).openWrite();
      await sink.addStream(createTarGz(files, baseDir: entrypoint.root.dir));
      await sink.close();
      final size = file.statSync().size;
      // Validate the package.
      var isValid = await _validate(size);
      if (!isValid) {
        overrideExitCode(exit_codes.DATA);
        return;
      } else if (dryRun) {
        log.message('The server may enforce additional checks.');
        return;
      } else {
        await _publish(
          tempPackagePath,
          await _getAuthorizationHeaders(),
        );
      }
    });
  }

  /// Returns the value associated with [key] in [map]. Throws a user-friendly
  /// error if [map] doesn't contain [key].
  T _expectField<T>(Map map, String key, String response) {
    if (map.containsKey(key)) {
      final result = map[key];
      if (result is! T) {
        invalidServerResponse(response);
      }
      return result;
    }
    invalidServerResponse(response);
  }

  /// Validates the package. Completes to false if the upload should not
  /// proceed.
  Future<bool> _validate(int packageSize) async {
    final hints = <String>[];
    final warnings = <String>[];
    final errors = <String>[];

    await Validator.runAll(
      entrypoint,
      packageSize,
      server,
      hints: hints,
      warnings: warnings,
      errors: errors,
    );

    if (errors.isNotEmpty) {
      log.error('Sorry, your package is missing '
          "${(errors.length > 1) ? 'some requirements' : 'a requirement'} "
          "and can't be published yet.\nFor more information, see: "
          'https://dart.dev/tools/pub/cmd/pub-lish.\n');
      return false;
    }

    if (force) return true;

    String formatWarningCount() {
      final hs = hints.length == 1 ? '' : 's';
      final hintText = hints.isEmpty ? '' : ' and ${hints.length} hint$hs.';
      final ws = warnings.length == 1 ? '' : 's';
      return '\nPackage has ${warnings.length} warning$ws$hintText.';
    }

    if (dryRun) {
      log.warning(formatWarningCount());
      return warnings.isEmpty;
    }

    log.message('\nPublishing is forever; packages cannot be unpublished.'
        '\nPolicy details are available at https://pub.dev/policy');

    final package = entrypoint.root;
    var message = 'Do you want to publish ${package.name} ${package.version}';

    if (warnings.isNotEmpty || hints.isNotEmpty) {
      final warning = formatWarningCount();
      message = '${log.bold(log.red(warning))}. $message';
    }

    var confirmed = await confirm('\n$message');
    if (!confirmed) {
      log.error('Package upload canceled.');
      return false;
    }
    return true;
  }
}
