// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:pub_semver/pub_semver.dart';

import 'lock_file.dart';
import 'package.dart';
import 'solver/failure.dart';
import 'solver/result.dart';
import 'solver/type.dart';
import 'solver/version_solver.dart';
import 'system_cache.dart';

export 'solver/failure.dart';
export 'solver/result.dart';
export 'solver/type.dart';

/// Attempts to select the best concrete versions for all of the transitive
/// dependencies of [root] taking into account all of the [VersionConstraint]s
/// that those dependencies place on each other and the requirements imposed by
/// [lockFile].
///
/// If [unlock] is given, then only packages listed in [unlock] will be unlocked
/// from [lockFile]. This is useful for a upgrading specific packages only.
///
/// If [unlock] is empty [SolveType.get] interprets this as lock everything,
/// while [SolveType.upgrade] and [SolveType.downgrade] interprets an empty
/// [unlock] as unlock everything.
///
/// [extraConstraints] can contain a list of extra constraints for this
/// resolution.
Future<SolveResult> resolveVersions(
  SolveType type,
  SystemCache cache,
  Package root, {
  LockFile? lockFile,
  Iterable<String> unlock = const [],
  Iterable<ConstraintAndCause>? extraConstraints,
}) {
  lockFile ??= LockFile.empty();
  final solver = VersionSolver(
    type,
    cache,
    root,
    lockFile,
    unlock,
  );
  if (extraConstraints != null) {
    solver.addConstraints(extraConstraints);
  }
  return solver.solve();
}

/// Attempts to select the best concrete versions for all of the transitive
/// dependencies of [root] taking into account all of the [VersionConstraint]s
/// that those dependencies place on each other and the requirements imposed by
/// [lockFile].
///
/// Like [resolveVersions] except that this function returns `null` where a
/// similar call to [resolveVersions] would throw a [SolveFailure].
///
/// If [unlock] is given, only packages listed in [unlock] will be unlocked
/// from [lockFile]. This is useful for a upgrading specific packages only.
///
/// If [unlock] is empty [SolveType.get] interprets this as lock everything,
/// while [SolveType.upgrade] and [SolveType.downgrade] interprets an empty
/// [unlock] as unlock everything.
Future<SolveResult?> tryResolveVersions(
  SolveType type,
  SystemCache cache,
  Package root, {
  LockFile? lockFile,
  Iterable<String>? unlock,
  Iterable<ConstraintAndCause>? extraConstraints,
}) async {
  try {
    return await resolveVersions(
      type,
      cache,
      root,
      lockFile: lockFile,
      unlock: unlock ?? [],
      extraConstraints: extraConstraints,
    );
  } on SolveFailure {
    return null;
  }
}
