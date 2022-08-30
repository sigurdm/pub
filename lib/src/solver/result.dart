// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

import '../exceptions.dart';
import '../io.dart';
import '../lock_file.dart';
import '../log.dart' as log;
import '../package.dart';
import '../package_name.dart';
import '../pub_embeddable_command.dart';
import '../pubspec.dart';
import '../source/hosted.dart';
import '../system_cache.dart';
import '../utils.dart';
import 'report.dart';
import 'type.dart';

/// The result of a successful version resolution.
class SolveResult {
  /// The list of concrete package versions that were selected for each package
  /// reachable from the root.
  final List<PackageId> packages;

  /// The root package of this resolution.
  final Package _root;

  /// A map from package names to the pubspecs for the versions of those
  /// packages that were installed.
  final Map<String, Pubspec> pubspecs;

  /// The available versions of all selected packages from their source.
  ///
  /// An entry here may not include the full list of versions available if the
  /// given package was locked and did not need to be unlocked during the solve.
  ///
  /// No version list will not contain any retracted package versions.
  final Map<String, List<Version>> availableVersions;

  /// The number of solutions that were attempted before either finding a
  /// successful solution or exhausting all options.
  ///
  /// In other words, one more than the number of times it had to backtrack
  /// because it found an invalid solution.
  final int attemptedSolutions;

  /// The wall clock time the resolution took.
  final Duration resolutionTime;

  /// Downloads all the packages selected by this version.
  ///
  /// Returns the [LockFile] representing the packages selected by this version
  /// resolution. Any resolved ids will correspond
  Future<LockFile> downloadPackages(
    SystemCache cache, {
    required bool allowOutdatedHashChecks,
  }) async {
    await cache.downloadPackages(
      _root,
      packages,
      allowOutdatedHashChecks: allowOutdatedHashChecks,
    );
    // Don't factor in overridden dependencies' SDK constraints, because we'll
    // accept those packages even if their constraints don't match.
    var nonOverrides = pubspecs.values
        .where(
            (pubspec) => !_root.dependencyOverrides.containsKey(pubspec.name))
        .toList();

    var sdkConstraints = <String, VersionConstraint>{};
    for (var pubspec in nonOverrides) {
      pubspec.sdkConstraints.forEach((identifier, constraint) {
        sdkConstraints[identifier] = constraint
            .intersect(sdkConstraints[identifier] ?? VersionConstraint.any);
      });
    }
    return LockFile(
      packages.map((id) {
        var description = id.description;
        // Use the cached content-hashes after downloading to ensure that
        // content-hashes from legacy servers gets used.
        if (description is ResolvedHostedDescription) {
          Uint8List? cachedHash =
              description.description.source.sha256FromCache(id, cache);
          if (cachedHash == null) {
            // This should not happen.
            throw StateError(
                'Archive for ${id.name}-${id.version} has no content hash.');
          }
          return PackageId(
              id.name, id.version, description.withSha256(cachedHash));
        }
        return id;
      }).toList(),
      sdkConstraints: sdkConstraints,
      mainDependencies: MapKeySet(_root.dependencies),
      devDependencies: MapKeySet(_root.devDependencies),
      overriddenDependencies: MapKeySet(_root.dependencyOverrides),
    );
  }

  final LockFile _previousLockFile;

  /// Returns the names of all packages that were changed.
  ///
  /// This includes packages that were added or removed.
  Set<String> get changedPackages {
    var changed = packages
        .where((id) => _previousLockFile.packages[id.name] != id)
        .map((id) => id.name)
        .toSet();

    return changed.union(_previousLockFile.packages.keys
        .where((package) => !availableVersions.containsKey(package))
        .toSet());
  }

  SolveResult(this._root, this._previousLockFile, this.packages, this.pubspecs,
      this.availableVersions, this.attemptedSolutions, this.resolutionTime);

  /// Warns if the content-hash of some hosted package locked
  /// in this [lockFile] differs from the one in the [cache].
  Future<void> checkContentHashes(LockFile lockFile, SystemCache cache) {
    for (final package in lockFile.packages.values) {
      if (package.description is ResolvedHostedDescription) {}
    }
  }

  /// Displays a one-line message summarizing what changes were made (or would
  /// be made) to the lockfile.
  ///
  /// If [type] is `SolveType.UPGRADE` it also shows the number of packages
  /// that are not at the latest available version.
  ///
  /// [type] is the type of version resolution that was run.
  Future<void> summarizeChanges(SolveType type, SystemCache cache,
      {bool dryRun = false}) async {
    report.summarize(dryRun: dryRun);
    if (type == SolveType.upgrade) {
      await report.reportDiscontinued();
      report.reportOutdated();
    }
  }

  /// Send analytics about the package resolution.
  void sendAnalytics(PubAnalytics pubAnalytics) {
    ArgumentError.checkNotNull(pubAnalytics);
    final analytics = pubAnalytics.analytics;
    if (analytics == null) return;

    final dependenciesForAnalytics = <PackageId>[];
    for (final package in packages) {
      // Only send analytics for packages from pub.dev.
      if (HostedSource.isFromPubDev(package) ||
          (package.source is HostedSource && runningFromTest)) {
        dependenciesForAnalytics.add(package);
      }
    }
    // Randomize the dependencies, such that even if some analytics events don't
    // get sent, the results will still be representative.
    shuffle(dependenciesForAnalytics);
    for (final package in dependenciesForAnalytics) {
      final dependencyKind = const {
        DependencyType.dev: 'dev',
        DependencyType.direct: 'direct',
        DependencyType.none: 'transitive'
      }[_root.dependencyType(package.name)]!;
      analytics.sendEvent(
        'pub-get',
        package.name,
        label: package.version.canonicalizedVersion,
        value: 1,
        parameters: {
          'ni': '1', // We consider a pub-get a non-interactive event.
          pubAnalytics.dependencyKindCustomDimensionName: dependencyKind,
        },
      );
      log.fine(
          'Sending analytics hit for "pub-get" of ${package.name} version ${package.version} as dependency-kind $dependencyKind');
    }

    analytics.sendTiming(
      'resolution',
      resolutionTime.inMilliseconds,
      category: 'pub-get',
    );
    log.fine(
        'Sending analytics timing "pub-get" took ${resolutionTime.inMilliseconds} miliseconds');
  }

  @override
  String toString() => 'Took $attemptedSolutions tries to resolve to\n'
      '- ${packages.join("\n- ")}';
}
