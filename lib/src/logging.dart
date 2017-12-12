// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:logging/logging.dart';

final Logger _log = new Logger('pana');

final _key = new Object();

Future<R> withLogger<R>(Future<R> fn(), {Logger logger}) => runZoned(
      fn,
      zoneValues: {_key: logger},
    );

Logger get log => Zone.current[_key] ?? _log;