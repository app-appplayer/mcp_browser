/// Minimal CDP (Chrome DevTools Protocol) JSON-RPC client.
///
/// Talks to the Chromium browser-level WebSocket endpoint returned by
/// [ChromiumLauncher]. Supports flat session routing: a single WebSocket
/// multiplexes browser-level and target-level messages via `sessionId`.
///
/// Pure Dart — no puppeteer, no Node. Uses `web_socket_channel`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Error thrown when CDP returns an `error` payload.
class CdpError implements Exception {

  CdpError({this.code, required this.message, this.data});
  final int? code;
  final String message;
  final Map<String, dynamic>? data;

  @override
  String toString() => 'CdpError(code=$code, message=$message)';
}

/// A single CDP event (no `id`, has `method`).
class CdpEvent {

  const CdpEvent({
    required this.method,
    required this.params,
    this.sessionId,
  });
  final String method;
  final Map<String, dynamic> params;
  final String? sessionId;
}

class CdpClient {
  CdpClient._(this._channel) {
    _sub = _channel.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  /// Connect to [wsUrl] (as reported by Chromium's `/json/version`).
  static Future<CdpClient> connect(String wsUrl) async {
    final channel = IOWebSocketChannel.connect(Uri.parse(wsUrl));
    await channel.ready;
    return CdpClient._(channel);
  }

  final WebSocketChannel _channel;
  late final StreamSubscription<dynamic> _sub;
  int _idCounter = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final StreamController<CdpEvent> _events =
      StreamController<CdpEvent>.broadcast();

  bool _closed = false;

  /// Broadcast stream of all incoming CDP events.
  Stream<CdpEvent> get events => _events.stream;

  /// Issue a CDP command. When [sessionId] is null the command targets the
  /// browser-level session (e.g. `Target.*`, `Browser.*`).
  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic>? params,
    String? sessionId,
  }) async {
    if (_closed) {
      throw StateError('CdpClient is closed; cannot send $method');
    }
    final id = ++_idCounter;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final payload = <String, dynamic>{
      'id': id,
      'method': method,
      if (params != null) 'params': params,
      if (sessionId != null) 'sessionId': sessionId,
    };
    _channel.sink.add(jsonEncode(payload));
    return completer.future;
  }

  /// Wait for the first event matching [method] (optionally scoped to
  /// [sessionId]). Useful for `Page.loadEventFired` etc.
  Future<CdpEvent> waitForEvent(
    String method, {
    String? sessionId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return events
        .firstWhere(
          (CdpEvent e) =>
              e.method == method &&
              (sessionId == null || e.sessionId == sessionId),
        )
        .timeout(timeout);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      await _channel.sink.close();
    } on Object {/* swallow */}
    if (!_events.isClosed) await _events.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('CdpClient closed before response arrived'),
        );
      }
    }
    _pending.clear();
  }

  void _onData(dynamic raw) {
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    } on Object {
      return;
    }
    final id = json['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = json['error'];
      if (error is Map) {
        completer.completeError(CdpError(
          code: (error['code'] as num?)?.toInt(),
          message: (error['message'] as String?) ?? 'unknown CDP error',
          data: error['data'] is Map
              ? Map<String, dynamic>.from(error['data'] as Map)
              : null,
        ));
      } else {
        completer.complete(
          json['result'] is Map
              ? Map<String, dynamic>.from(json['result'] as Map)
              : const <String, dynamic>{},
        );
      }
    } else if (json['method'] is String) {
      _events.add(CdpEvent(
        method: json['method'] as String,
        params: json['params'] is Map
            ? Map<String, dynamic>.from(json['params'] as Map)
            : const <String, dynamic>{},
        sessionId: json['sessionId'] as String?,
      ));
    }
  }

  void _onError(Object error, StackTrace stack) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }
    _pending.clear();
  }

  void _onDone() {
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('CDP WebSocket closed before response arrived'),
        );
      }
    }
    _pending.clear();
    if (!_events.isClosed) _events.close();
  }
}
