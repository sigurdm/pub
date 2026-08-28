// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
library;

import 'package:pub/src/package_name.dart';
import 'package:pub/src/solver/incompatibility.dart';
import 'package:pub/src/solver/incompatibility_cause.dart';
import 'package:pub/src/solver/package_lister.dart';
import 'package:pub/src/solver/partial_solution.dart';
import 'package:pub/src/solver/set_relation.dart';
import 'package:pub/src/solver/term.dart';
import 'package:pub/src/source/hosted.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final hostedRef = PackageRef(
    'foo',
    HostedDescription('foo', 'https://pub.dartlang.org'),
  );
  final gitRef = PackageRef(
    'foo',
    HostedDescription('foo', 'https://other.dartlang.org'),
  );

  PackageId idFor(PackageRef ref, Version version) => PackageId(
    ref.name,
    version,
    ResolvedHostedDescription(
      ref.description as HostedDescription,
      sha256: null,
    ),
  );

  Term term(
    PackageRef ref,
    VersionConstraint constraint, {
    bool isPositive = true,
  }) => Term(ref.withConstraint(constraint), isPositive);

  PackageVersionIndex indexFor(PackageRef ref, List<Version> versions) =>
      PackageVersionIndex(versions.map((v) => idFor(ref, v)).toList());

  group('Term.relation with PackageVersionIndex', () {
    final versions = [
      Version(1, 0, 0),
      Version(1, 1, 0),
      Version(1, 2, 0),
      Version(2, 0, 0),
      Version(2, 1, 0),
      Version(3, 0, 0),
    ];
    final index = indexFor(hostedRef, versions);

    group('Positive vs Positive (+t1, +t2)', () {
      test('subset when t2 contains all versions in t1', () {
        final t1 = term(hostedRef, VersionConstraint.parse('^1.1.0'));
        final t2 = term(hostedRef, VersionConstraint.parse('^1.0.0'));
        expect(t1.relation(t2, index), SetRelation.subset);
        expect(t1.satisfies(t2, index), isTrue);
      });

      test('disjoint when no versions overlap', () {
        final t1 = term(hostedRef, VersionConstraint.parse('^1.0.0'));
        final t2 = term(hostedRef, VersionConstraint.parse('^2.0.0'));
        expect(t1.relation(t2, index), SetRelation.disjoint);
        expect(t1.satisfies(t2, index), isFalse);
      });

      test(
        'overlapping when some versions match but neither contains the other',
        () {
          final t1 = term(hostedRef, VersionConstraint.parse('>=1.1.0 <2.1.0'));
          final t2 = term(hostedRef, VersionConstraint.parse('^1.0.0'));
          expect(t1.relation(t2, index), SetRelation.overlapping);
          expect(t1.satisfies(t2, index), isFalse);
        },
      );

      test('disjoint for incompatible package sources', () {
        final t1 = term(hostedRef, VersionConstraint.any);
        final t2 = term(gitRef, VersionConstraint.any);
        expect(t1.relation(t2, index), SetRelation.disjoint);
      });
    });

    group('Positive vs Negative (+t1, -t2)', () {
      test('subset when t2 forbids no versions in t1', () {
        final t1 = term(hostedRef, VersionConstraint.parse('^2.0.0'));
        final t2 = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
          isPositive: false,
        );
        expect(t1.relation(t2, index), SetRelation.subset);
        expect(t1.satisfies(t2, index), isTrue);
      });

      test('disjoint when t2 forbids all versions in t1', () {
        final t1 = term(hostedRef, VersionConstraint.parse('^1.1.0'));
        final t2 = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
          isPositive: false,
        );
        expect(t1.relation(t2, index), SetRelation.disjoint);
        expect(t1.satisfies(t2, index), isFalse);
      });

      test('overlapping when t2 forbids some but not all versions in t1', () {
        final t1 = term(hostedRef, VersionConstraint.parse('>=1.0.0 <3.0.0'));
        final t2 = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
          isPositive: false,
        );
        expect(t1.relation(t2, index), SetRelation.overlapping);
        expect(t1.satisfies(t2, index), isFalse);
      });

      test('subset for incompatible package sources', () {
        final t1 = term(hostedRef, VersionConstraint.any);
        final t2 = term(gitRef, VersionConstraint.any, isPositive: false);
        expect(t1.relation(t2, index), SetRelation.subset);
      });
    });

    group('Negative vs Positive (-t1, +t2)', () {
      test('disjoint when t1 forbids all versions in t2', () {
        final t1 = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
          isPositive: false,
        );
        final t2 = term(hostedRef, VersionConstraint.parse('^1.1.0'));
        expect(t1.relation(t2, index), SetRelation.disjoint);
        expect(t1.satisfies(t2, index), isFalse);
      });

      test('overlapping when t1 does not forbid all versions in t2', () {
        final t1 = term(
          hostedRef,
          VersionConstraint.parse('^1.1.0'),
          isPositive: false,
        );
        final t2 = term(hostedRef, VersionConstraint.parse('^1.0.0'));
        expect(t1.relation(t2, index), SetRelation.overlapping);
        expect(t1.satisfies(t2, index), isFalse);
      });

      test('overlapping for incompatible package sources', () {
        final t1 = term(hostedRef, VersionConstraint.any, isPositive: false);
        final t2 = term(gitRef, VersionConstraint.any);
        expect(t1.relation(t2, index), SetRelation.overlapping);
      });
    });

    group('Negative vs Negative (-t1, -t2)', () {
      test('subset when t1 forbids all versions forbidden by t2', () {
        final t1 = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
          isPositive: false,
        );
        final t2 = term(
          hostedRef,
          VersionConstraint.parse('^1.1.0'),
          isPositive: false,
        );
        expect(t1.relation(t2, index), SetRelation.subset);
        expect(t1.satisfies(t2, index), isTrue);
      });

      test('overlapping when t1 does not forbid everything t2 forbids', () {
        final t1 = term(
          hostedRef,
          VersionConstraint.parse('^1.1.0'),
          isPositive: false,
        );
        final t2 = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
          isPositive: false,
        );
        expect(t1.relation(t2, index), SetRelation.overlapping);
        expect(t1.satisfies(t2, index), isFalse);
      });

      test('overlapping for incompatible package sources', () {
        final t1 = term(hostedRef, VersionConstraint.any, isPositive: false);
        final t2 = term(gitRef, VersionConstraint.any, isPositive: false);
        expect(t1.relation(t2, index), SetRelation.overlapping);
      });
    });

    test('Equivalence with symbolic relations on diverse version universe', () {
      for (final minorCount in [10, 20, 30, 40]) {
        // Generate versions spanning 0.x, 1.x, 2.x, 3.x
        final verList = <Version>[];
        for (var major = 0; major < 4; major++) {
          for (var minor = 0; minor < minorCount; minor++) {
            verList.add(Version(major, minor, 0));
          }
        }
        verList.sort();
        final verIndex = indexFor(hostedRef, verList);

        final sampleConstraints = [
          VersionConstraint.empty,
          VersionConstraint.any,
          Version(1, 0, 0),
          Version(1, 5, 0),
          Version(2, 0, 0),
          VersionRange(
            min: Version(1, 0, 0),
            max: Version(2, 0, 0),
            includeMin: true,
          ),
          VersionRange(
            min: Version(1, 5, 0),
            max: Version(2, 5, 0),
            includeMin: true,
          ),
          VersionConstraint.parse('^1.0.0'),
          VersionConstraint.parse('^2.0.0'),
          VersionConstraint.parse('>=1.2.0 <1.8.0'),
        ];

        for (final c1 in sampleConstraints) {
          for (final c2 in sampleConstraints) {
            for (final p1 in [true, false]) {
              for (final p2 in [true, false]) {
                final t1 = term(hostedRef, c1, isPositive: p1);
                final t2 = term(hostedRef, c2, isPositive: p2);

                final expected = t1.relation(t2);
                final actual = t1.relation(t2, verIndex);
                expect(
                  actual,
                  equals(expected),
                  reason:
                      'Failed relation($t1, $t2) for minorCount=$minorCount',
                );
              }
            }
          }
        }
      }
    });
  });

  group('PartialSolution with VersionIndexProvider', () {
    final versions = [
      Version(1, 0, 0),
      Version(1, 1, 0),
      Version(1, 2, 0),
      Version(2, 0, 0),
    ];
    final index = indexFor(hostedRef, versions);
    final cause = Incompatibility([
      term(hostedRef, VersionConstraint.any),
    ], NoVersionsIncompatibilityCause());

    test(
      'relation and satisfier use index provider for positive assignments',
      () {
        final solution = PartialSolution(
          {},
          (ref) => ref.name == 'foo' ? index : null,
        );

        solution.decide(idFor(hostedRef, Version(1, 1, 0)));

        final satisfiedTerm = term(
          hostedRef,
          VersionConstraint.parse('^1.0.0'),
        );
        expect(solution.relation(satisfiedTerm), SetRelation.subset);
        expect(solution.satisfies(satisfiedTerm), isTrue);
        expect(solution.satisfier(satisfiedTerm).index, 0);

        final disjointTerm = term(hostedRef, VersionConstraint.parse('^2.0.0'));
        expect(solution.relation(disjointTerm), SetRelation.disjoint);
        expect(solution.satisfies(disjointTerm), isFalse);
      },
    );

    test(
      'relation and satisfier use index provider for negative assignments',
      () {
        final solution = PartialSolution(
          {},
          (ref) => ref.name == 'foo' ? index : null,
        );

        solution.derive(
          hostedRef.withConstraint(VersionConstraint.parse('^1.0.0')),
          false,
          cause,
        );

        // Term forbidding ^1.1.0 is a subset of forbidding ^1.0.0 (satisfied)
        final satisfiedTerm = term(
          hostedRef,
          VersionConstraint.parse('^1.1.0'),
          isPositive: false,
        );
        expect(solution.relation(satisfiedTerm), SetRelation.subset);
        expect(solution.satisfies(satisfiedTerm), isTrue);

        // Term requiring ^1.1.0 is disjoint from forbidding ^1.0.0
        final disjointTerm = term(hostedRef, VersionConstraint.parse('^1.1.0'));
        expect(solution.relation(disjointTerm), SetRelation.disjoint);
        expect(solution.satisfies(disjointTerm), isFalse);

        // Term requiring ^2.0.0 is overlapping with forbidding ^1.0.0
        final overlappingTerm = term(
          hostedRef,
          VersionConstraint.parse('^2.0.0'),
        );
        expect(solution.relation(overlappingTerm), SetRelation.overlapping);
        expect(solution.satisfies(overlappingTerm), isFalse);
      },
    );
  });

  group('PackageVersionIndex edge cases', () {
    test('matches VersionRange.allows exactly with pre-releases', () {
      final versions = [
        Version.parse('1.0.0'),
        Version.parse('1.5.0-dev'),
        Version.parse('1.5.0'),
        Version.parse('2.0.0-alpha'),
        Version.parse('2.0.0'),
      ];
      final index = indexFor(hostedRef, versions);

      // ^1.0.0 allows 1.0.0, 1.5.0-dev, 1.5.0, but excludes 2.0.0-alpha and 2.0.0
      final mask = index.maskFor(VersionConstraint.parse('^1.0.0'));
      expect(mask.allows(0), isTrue); // 1.0.0
      expect(mask.allows(1), isTrue); // 1.5.0-dev (allowed by pub_semver)
      expect(mask.allows(2), isTrue); // 1.5.0
      expect(mask.allows(3), isFalse); // 2.0.0-alpha (excluded by pub_semver!)
      expect(mask.allows(4), isFalse); // 2.0.0
      expect(mask.count(), 3);
      for (var i = 0; i < versions.length; i++) {
        expect(
          mask.allows(i),
          equals(VersionConstraint.parse('^1.0.0').allows(versions[i])),
        );
      }
    });

    test('pre-computes emptyMask and allVersionsMask', () {
      final versions = [Version(1, 0, 0)];
      final index = indexFor(hostedRef, versions);
      expect(index.maskFor(VersionConstraint.empty), same(index.emptyMask));
      expect(index.maskFor(VersionConstraint.any), same(index.allVersionsMask));
    });
  });
}
