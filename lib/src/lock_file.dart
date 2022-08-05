// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart' hide mapMap;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'io.dart';
import 'language_version.dart';
import 'log.dart' as log;
import 'package_config.dart';
import 'package_name.dart';
import 'packages_file.dart' as packages_file;
import 'sdk.dart' show sdk;
import 'source/hosted.dart';
import 'system_cache.dart';
import 'utils.dart';

/// A parsed and validated `pubspec.lock` file.
class LockFile {
  /// The packages this lockfile pins.
  final Map<String, PackageId> packages;

  /// The intersections of all SDK constraints for all locked packages, indexed
  /// by SDK identifier.
  Map<String, VersionConstraint> sdkConstraints;

  /// Dependency names that appeared in the root package's `dependencies`
  /// section.
  final Set<String> mainDependencies;

  /// Dependency names that appeared in the root package's `dev_dependencies`
  /// section.
  final Set<String> devDependencies;

  /// Dependency names that appeared in the root package's
  /// `dependency_overrides` section.
  final Set<String> overriddenDependencies;

  /// Creates a new lockfile containing [ids].
  ///
  /// If passed, [mainDependencies], [devDependencies], and
  /// [overriddenDependencies] indicate which dependencies should be marked as
  /// being listed in the main package's `dependencies`, `dev_dependencies`, and
  /// `dependency_overrides` sections, respectively. These are consumed by the
  /// analysis server to provide better auto-completion.
  LockFile(Iterable<PackageId> ids,
      {Map<String, VersionConstraint>? sdkConstraints,
      Set<String>? mainDependencies,
      Set<String>? devDependencies,
      Set<String>? overriddenDependencies})
      : this._(
            Map.fromIterable(ids.where((id) => !id.isRoot),
                key: (id) => id.name),
            sdkConstraints ?? {'dart': VersionConstraint.any},
            mainDependencies ?? const UnmodifiableSetView.empty(),
            devDependencies ?? const UnmodifiableSetView.empty(),
            overriddenDependencies ?? const UnmodifiableSetView.empty());

  LockFile._(Map<String, PackageId> packages, this.sdkConstraints,
      this.mainDependencies, this.devDependencies, this.overriddenDependencies)
      : packages = UnmodifiableMapView(packages);

  LockFile.empty()
      : packages = const {},
        sdkConstraints = {'dart': VersionConstraint.any},
        mainDependencies = const UnmodifiableSetView.empty(),
        devDependencies = const UnmodifiableSetView.empty(),
        overriddenDependencies = const UnmodifiableSetView.empty();

  /// Loads a lockfile from [filePath].
  factory LockFile.load(String filePath, SourceRegistry sources) {
    return LockFile._parse(filePath, readTextFile(filePath), sources);
  }

  /// Parses a lockfile whose text is [contents].
  ///
  /// If [filePath] is given, path-dependencies will be interpreted relative to
  /// that.
  factory LockFile.parse(String contents, SourceRegistry sources,
      {String? filePath}) {
    return LockFile._parse(filePath, contents, sources);
  }

  /// Parses the lockfile whose text is [contents].
  ///
  /// [filePath] is the system-native path to the lockfile on disc. It may be
  /// `null`.
  static LockFile _parse(
      String? filePath, String contents, SourceRegistry sources) {
    if (contents.trim() == '') return LockFile.empty();

    Uri? sourceUrl;
    if (filePath != null) sourceUrl = p.toUri(filePath);
    var parsed = loadYamlNode(contents, sourceUrl: sourceUrl);

    _validate(parsed is Map, 'The lockfile must be a YAML mapping.', parsed);
    var parsedMap = parsed as YamlMap;

    var sdkConstraints = <String, VersionConstraint>{};
    var sdkNode = parsedMap.nodes['sdk'];
    if (sdkNode != null) {
      // Lockfiles produced by pub versions from 1.14.0 through 1.18.0 included
      // a top-level "sdk" field which encoded the unified constraint on the
      // Dart SDK. They had no way of specifying constraints on other SDKs.
      sdkConstraints['dart'] = _parseVersionConstraint(sdkNode);
    } else if (parsedMap.containsKey('sdks')) {
      var sdksField = parsedMap['sdks'];
      _validate(sdksField is Map, 'The "sdks" field must be a mapping.',
          parsedMap.nodes['sdks']);

      sdksField.nodes.forEach((name, constraint) {
        _validate(name.value is String, 'SDK names must be strings.', name);
        sdkConstraints[name.value as String] =
            _parseVersionConstraint(constraint);
      });
    }

    var packages = <String, PackageId>{};
    var packageEntries = parsedMap['packages'];
    if (packageEntries != null) {
      _validate(packageEntries is Map, 'The "packages" field must be a map.',
          parsedMap.nodes['packages']);

      packageEntries.forEach((name, spec) {
        // Parse the version.
        _validate(spec.containsKey('version'),
            'Package $name is missing a version.', spec);
        var version = Version.parse(spec['version']);

        // Parse the source.
        _validate(spec.containsKey('source'),
            'Package $name is missing a source.', spec);
        var sourceName = spec['source'];

        _validate(spec.containsKey('description'),
            'Package $name is missing a description.', spec);
        var description = spec['description'];

        // Let the source parse the description.
        var source = sources(sourceName);
        PackageId id;
        try {
          id = source.parseId(name, version, description,
              containingDir: filePath == null ? null : p.dirname(filePath));
        } on FormatException catch (ex) {
          throw SourceSpanFormatException(
              ex.message, spec.nodes['description'].span);
        }

        // Validate the name.
        _validate(name == id.name,
            "Package name $name doesn't match ${id.name}.", spec);

        packages[name] = id;
      });
    }

    return LockFile._(
        packages,
        sdkConstraints,
        const UnmodifiableSetView.empty(),
        const UnmodifiableSetView.empty(),
        const UnmodifiableSetView.empty());
  }

  /// Asserts that [node] is a version constraint, and parses it.
  static VersionConstraint _parseVersionConstraint(YamlNode node) {
    _validate(node.value is String,
        'Invalid version constraint: must be a string.', node);

    return _wrapFormatException('version constraint', node.span,
        () => VersionConstraint.parse(node.value));
  }

  /// Runs [fn] and wraps any [FormatException] it throws in a
  /// [SourceSpanFormatException].
  ///
  /// [description] should be a noun phrase that describes whatever's being
  /// parsed or processed by [fn]. [span] should be the location of whatever's
  /// being processed within the pubspec.
  static T _wrapFormatException<T>(
      String description, SourceSpan span, T Function() fn) {
    try {
      return fn();
    } on FormatException catch (e) {
      throw SourceSpanFormatException(
          'Invalid $description: ${e.message}', span);
    }
  }

  /// If [condition] is `false` throws a format error with [message] for [node].
  static void _validate(bool condition, String message, YamlNode? node) {
    if (condition) return;
    throw SourceSpanFormatException(message, node!.span);
  }

  /// Returns a copy of this LockFile with a package named [name] removed.
  ///
  /// Returns an identical [LockFile] if there's no package named [name].
  LockFile removePackage(String name) {
    if (!this.packages.containsKey(name)) return this;

    var packages = Map<String, PackageId>.from(this.packages);
    packages.remove(name);
    return LockFile._(
      packages,
      sdkConstraints,
      mainDependencies,
      devDependencies,
      overriddenDependencies,
    );
  }

  /// Returns the contents of the `.packages` file generated from this lockfile.
  ///
  /// If [entrypoint] is passed, a relative entry is added for its "lib/"
  /// directory.
  String packagesFile(
    SystemCache cache, {
    String? entrypoint,
    String? relativeFrom,
  }) {
    var header = '''
This file is deprecated. Tools should instead consume
`.dart_tool/package_config.json`.

For more info see: https://dart.dev/go/dot-packages-deprecation

Generated by pub on ${DateTime.now()}.''';

    var map = Map<String, Uri>.fromIterable(ordered<String>(packages.keys),
        value: (name) {
      var id = packages[name]!;
      return p.toUri(
        p.join(
          cache.getDirectory(id, relativeFrom: relativeFrom),
          'lib',
        ),
      );
    });

    if (entrypoint != null) map[entrypoint] = Uri.parse('lib/');

    var text = StringBuffer();
    packages_file.write(text, map, comment: header);
    return text.toString();
  }

  /// Returns the contents of the `.dart_tool/package_config` file generated
  /// from this lockfile.
  ///
  /// This file will replace the `.packages` file.
  ///
  /// If [entrypoint] is passed, an accompanying [entrypointSdkConstraint]
  /// should be given, these identify the current package in which this file is
  /// written. Passing `null` as [entrypointSdkConstraint] is correct if the
  /// current package has no SDK constraint.
  Future<String> packageConfigFile(
    SystemCache cache, {
    String? entrypoint,
    VersionConstraint? entrypointSdkConstraint,
    String? relativeFrom,
  }) async {
    final entries = <PackageConfigEntry>[];
    for (final name in ordered(packages.keys)) {
      final id = packages[name]!;
      final rootPath = cache.getDirectory(id, relativeFrom: relativeFrom);
      Uri rootUri;
      if (p.isRelative(rootPath)) {
        // Relative paths are relative to the root project, we want them
        // relative to the `.dart_tool/package_config.json` file.
        rootUri = p.toUri(p.join('..', rootPath));
      } else {
        rootUri = p.toUri(rootPath);
      }
      final pubspec = await cache.describe(id);
      final sdkConstraint = pubspec.sdkConstraints[sdk.identifier];
      entries.add(PackageConfigEntry(
        name: name,
        rootUri: rootUri,
        packageUri: p.toUri('lib/'),
        languageVersion: LanguageVersion.fromSdkConstraint(sdkConstraint),
      ));
    }

    if (entrypoint != null) {
      entries.add(PackageConfigEntry(
        name: entrypoint,
        rootUri: p.toUri('../'),
        packageUri: p.toUri('lib/'),
        languageVersion: LanguageVersion.fromSdkConstraint(
          entrypointSdkConstraint,
        ),
      ));
    }

    final packageConfig = PackageConfig(
      configVersion: 2,
      packages: entries,
      generated: DateTime.now(),
      generator: 'pub',
      generatorVersion: sdk.version,
    );

    return '${JsonEncoder.withIndent('  ').convert(packageConfig.toJson())}\n';
  }

  /// Throws a [DataException] if the content-hash of some hosted package locked
  /// in this lock file differs from the one in the [cache].
  void checkContentHashes(SystemCache cache) {
    for (final id in packages.values) {
      var description = id.description;
      if (description is ResolvedHostedDescription) {
        if (description.sha256 != null) {
          final cachedHash =
              description.description.source.sha256FromCache(id, cache);
          if (cachedHash == null) {
            // This can happen if we resolve from a server not providing hashes,
            // but we are not downloading the archives. (eg. for a
            // dependency_services run).
            // TODO(sigurdm): What should we do here?
            log.fine('No hash of downloaded archive found');
          } else if (!bytesEquals(cachedHash, description.sha256)) {
            dataError(
                'Cache entry for ${id.name}-${id.version} does not have content-hash matching lockfile.');
          }
        }
      }
    }
  }

  /// Returns the serialized YAML text of the lock file.
  ///
  /// [packageDir] is the containing directory of the root package, used to
  /// serialize relative path package descriptions. If it is null, they will be
  /// serialized as absolute.
  String serialize(String? packageDir, SystemCache cache) {
    // Convert the dependencies to a simple object.
    var packageMap = {};
    packages.forEach((name, package) {
      var description = package.description;
      if (description is ResolvedHostedDescription) {
        Uint8List? hash =
            description.description.source.sha256FromCache(package, cache);
        if (hash == null) {
          // This can happen if we resolve from a server not providing hashes,
          // but we are not downloading the archives. (eg. for a
          // dependency_services run).
          // TODO(sigurdm): What should we do here?
          log.fine('No hash of downloaded archive found');
        } else if (description.sha256 == null) {
          // We have resolved from a server without archive_sha256 in the
          // version listing. Use the sha256 from the archive instead.
          description = description.withSha256(hash);
        } else {
          // TODO(Should we really not fail here???).
          if (!bytesEquals(hash, description.sha256)) {
            dataError(
                'Cache entry for $name-${package.version} does not have content-hash matching lockfile.');
          }
        }
      }

      packageMap[name] = {
        'version': package.version.toString(),
        'source': package.source.name,
        'description':
            description.serializeForLockfile(containingDir: packageDir),
        'dependency': _dependencyType(package.name)
      };
    });

    var data = {
      'sdks': mapMap(sdkConstraints,
          value: (_, constraint) => constraint.toString()),
      'packages': packageMap
    };
    return '''
# Generated by pub
# See https://dart.dev/tools/pub/glossary#lockfile
${yamlToString(data)}
''';
  }

  /// Saves the list of concrete package versions to [lockFilePath].
  ///
  /// Will use Windows line endings (`\r\n`) if the file already exists, and
  /// uses that.
  ///
  /// Relative paths will be resolved relative to [lockFilePath]
  void writeToFile(String lockFilePath, SystemCache cache) {
    final windowsLineEndings = fileExists(lockFilePath) &&
        detectWindowsLineEndings(readTextFile(lockFilePath));

    final serialized = serialize(p.dirname(lockFilePath), cache);
    writeTextFile(lockFilePath,
        windowsLineEndings ? serialized.replaceAll('\n', '\r\n') : serialized);
  }

  static const directMain = 'direct main';
  static const directDev = 'direct dev';
  static const directOverridden = 'direct overridden';
  static const transitive = 'transitive';

  /// Returns the dependency classification for [package].
  String _dependencyType(String package) {
    if (mainDependencies.contains(package)) return directMain;
    if (devDependencies.contains(package)) return directDev;

    // If a package appears in `dependency_overrides` and another dependency
    // section, the main section it appears in takes precedence.
    if (overriddenDependencies.contains(package)) {
      return directOverridden;
    }
    return transitive;
  }

  /// `true` if [other] has the same packages as `this` in the same versions
  /// from the same sources.
  bool samePackageIds(LockFile other) {
    if (packages.length != other.packages.length) {
      return false;
    }
    for (final id in packages.values) {
      final otherId = other.packages[id.name];
      if (id != otherId) return false;
    }
    return true;
  }
}

/// Returns `true` if the [text] looks like it uses windows line endings.
///
/// The heuristic used is to count all `\n` in the text and if stricly more than
/// half of them are preceded by `\r` we report `true`.
@visibleForTesting
bool detectWindowsLineEndings(String text) {
  var index = -1;
  var unixNewlines = 0;
  var windowsNewlines = 0;
  while ((index = text.indexOf('\n', index + 1)) != -1) {
    if (index != 0 && text[index - 1] == '\r') {
      windowsNewlines++;
    } else {
      unixNewlines++;
    }
  }
  return windowsNewlines > unixNewlines;
}
