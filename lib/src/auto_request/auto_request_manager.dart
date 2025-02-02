// Copyright (c) 2019-present,  SurfStudio LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:math';

import 'package:auto_reload/src/auto_request/auto_future_manager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

const _defaultMinReloadDurationSeconds = 1;
const _defaultMaxReloadDurationSeconds = 1800;

/// Manager of automatic sending of request to the server
///
/// each new attempt will pass through a greater amount of time
/// from [_minReloadDurationSeconds] to [_maxReloadDurationSeconds]
/// exponentially increasing
class AutoRequestManager implements AutoFutureManager {
  AutoRequestManager({
    int? minReloadDurationSeconds,
    int? maxReloadDurationSeconds,
  })  : _minReloadDurationSeconds =
            minReloadDurationSeconds ?? _defaultMinReloadDurationSeconds,
        _maxReloadDurationSeconds =
            maxReloadDurationSeconds ?? _defaultMaxReloadDurationSeconds {
    _currentReloadDuration = _minReloadDurationSeconds;
  }
  final int _minReloadDurationSeconds;
  final int _maxReloadDurationSeconds;
  final _connectivity = Connectivity();

  final _queue = <String, Future<void> Function()>{};
  final _callbacks = <String, AutoFutureCallback>{};

  late int _currentReloadDuration;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  Timer? _requestTimer;

  /// register request for auto reload
  @override
  Future<void> autoReload({
    required String id,
    required Future<void> Function() toReload,
    AutoFutureCallback? onComplete,
  }) async {
    _queue.putIfAbsent(id, () {
      if (onComplete != null) {
        _callbacks[id] = onComplete;
      }
      return toReload;
    });

    return _tryReload();
  }

  /// dispose, when need kill manager
  Future<void> dispose() async {
    _queue.clear();
    _callbacks.clear();
    await _connectivitySubscription?.cancel();
    _requestTimer?.cancel();
  }

  Future<void> _tryReload() async {
    await _connectivity.checkConnectivity();
    _connectivitySubscription ??=
        _connectivity.onConnectivityChanged.listen(_reloadRequest);
  }

  void _reloadRequest(List<ConnectivityResult> connection) {
    if (!_needToReload(connection) || _requestTimer != null) {
      return;
    }

    _currentReloadDuration = _minReloadDurationSeconds;

    _reRunTimer();
  }

  void _reRunTimer() {
    _closeTimer();
    _requestTimer = Timer.periodic(
      Duration(seconds: _currentReloadDuration),
      _timerHandler,
    );

    _currentReloadDuration = min(
      _currentReloadDuration * 2,
      _maxReloadDurationSeconds,
    );
  }

  void _closeTimer() {
    _requestTimer?.cancel();
    _requestTimer = null;
  }

  Future<void> _timerHandler(Timer timer) async {
    final keys = _queue.keys.toList();
    for (final key in keys) {
      try {
        await _handleItemQueue(key);
      } on Exception catch (e) {
        // do nothing, the timer will restart request
        // ignore: avoid_print
        print('unsuccessful attempt to execute request with error: $e');
      }
    }

    _queue.isEmpty ? _closeTimer() : _reRunTimer();
  }

  Future<void> _handleItemQueue(String key) async {
    final queueValue = _queue.remove(key);
    if (queueValue != null) {
      await queueValue();
    }

    final callbacksValue = _callbacks.remove(key);
    if (callbacksValue != null) {
      callbacksValue(key);
    }
  }

  bool _needToReload(List<ConnectivityResult> connection) =>
      _haveConnection(connection);

  bool _haveConnection(List<ConnectivityResult> connections) {
    for (final connection in connections) {
      switch (connection) {
        case ConnectivityResult.wifi:
        case ConnectivityResult.mobile:
          return true;
        default:
          return false;
      }
    }
    return false;
  }
}
