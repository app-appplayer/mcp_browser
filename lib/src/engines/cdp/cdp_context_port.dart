/// Built-in CDP context lifecycle port — pure Dart (no puppeteer).
///
/// Implements `BrowserContextPort` by driving `Target.*` and `Network.*`
/// CDP commands against the shared [CdpConnection].
library;

import 'dart:convert';

import '../../_internal.dart';

import 'cdp_engine.dart';

class CdpContextPort implements BrowserContextPort {
  CdpContextPort({CdpConnection? connection})
      : _connection = connection ?? CdpConnection();

  final CdpConnection _connection;

  @override
  Future<Object> openContext(BrowserContextSpec spec) async {
    final client = await _connection.client();

    // Incognito context for non-persistent specs; persistent specs share
    // the default browser context (cookies live across acquires).
    String? browserContextId;
    if (!spec.persistent) {
      final result = await client.send('Target.createBrowserContext');
      browserContextId = result['browserContextId'] as String;
    }

    // Create the tab in the target browser context.
    final targetResult = await client.send(
      'Target.createTarget',
      params: <String, dynamic>{
        'url': 'about:blank',
        if (browserContextId != null) 'browserContextId': browserContextId,
      },
    );
    final targetId = targetResult['targetId'] as String;

    // Attach with flatten=true so future commands use `sessionId` routing.
    final attachResult = await client.send(
      'Target.attachToTarget',
      params: <String, dynamic>{
        'targetId': targetId,
        'flatten': true,
      },
    );
    final sessionId = attachResult['sessionId'] as String;

    if (spec.viewport != null) {
      await client.send(
        'Emulation.setDeviceMetricsOverride',
        params: <String, dynamic>{
          'width': spec.viewport!['width'] ?? 1280,
          'height': spec.viewport!['height'] ?? 800,
          'deviceScaleFactor': 1,
          'mobile': false,
        },
        sessionId: sessionId,
      );
    }
    if (spec.userAgent != null) {
      await client.send(
        'Emulation.setUserAgentOverride',
        params: <String, dynamic>{'userAgent': spec.userAgent},
        sessionId: sessionId,
      );
    }
    if (spec.locale != null) {
      try {
        await client.send(
          'Emulation.setLocaleOverride',
          params: <String, dynamic>{'locale': spec.locale},
          sessionId: sessionId,
        );
      } on Object {
        // Some Chromium builds restrict setLocaleOverride.
      }
    }
    if (spec.timezone != null) {
      try {
        await client.send(
          'Emulation.setTimezoneOverride',
          params: <String, dynamic>{'timezoneId': spec.timezone},
          sessionId: sessionId,
        );
      } on Object {/* best-effort */}
    }

    return CdpEnginePayload(
      targetId: targetId,
      sessionId: sessionId,
      browserContextId: browserContextId,
    );
  }

  @override
  Future<void> closeContext(Object enginePayload) async {
    final payload = enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    try {
      await client.send(
        'Target.closeTarget',
        params: <String, dynamic>{'targetId': payload.targetId},
      );
    } on Object {/* target already closed */}
    if (payload.browserContextId != null) {
      try {
        await client.send(
          'Target.disposeBrowserContext',
          params: <String, dynamic>{
            'browserContextId': payload.browserContextId,
          },
        );
      } on Object {/* best-effort */}
    }
  }

  @override
  Future<Map<String, dynamic>> saveStorageState(Object enginePayload) async {
    final payload = enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    final cookies = await client.send(
      'Network.getCookies',
      sessionId: payload.sessionId,
    );
    final storage = await client.send(
      'Runtime.evaluate',
      params: <String, dynamic>{
        'expression':
            '({localStorage: Object.fromEntries(Object.entries(localStorage)),'
                ' sessionStorage: Object.fromEntries(Object.entries(sessionStorage))})',
        'returnByValue': true,
      },
      sessionId: payload.sessionId,
    );
    return <String, dynamic>{
      'cookies': cookies['cookies'] ?? const <dynamic>[],
      'storage':
          (storage['result'] as Map?)?['value'] ?? const <String, dynamic>{},
    };
  }

  @override
  Future<void> restoreStorageState(
    Object enginePayload,
    Map<String, dynamic> state,
  ) async {
    final payload = enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    final cookies = state['cookies'] as List?;
    if (cookies != null && cookies.isNotEmpty) {
      await client.send(
        'Network.setCookies',
        params: <String, dynamic>{'cookies': cookies},
        sessionId: payload.sessionId,
      );
    }
    final storage = state['storage'];
    if (storage is Map) {
      final encoded = jsonEncode(storage);
      await client.send(
        'Runtime.evaluate',
        params: <String, dynamic>{
          'expression': '(data => { '
              'if (data.localStorage) { for (const [k,v] of Object.entries(data.localStorage)) localStorage.setItem(k,v); } '
              'if (data.sessionStorage) { for (const [k,v] of Object.entries(data.sessionStorage)) sessionStorage.setItem(k,v); } '
              '})($encoded)',
          'returnByValue': true,
        },
        sessionId: payload.sessionId,
      );
    }
  }

  @override
  Future<void> setCookies(
    BrowserContextHandle handle,
    List<BrowserCookie> cookies,
  ) async {
    final payload = handle.enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    await client.send(
      'Network.setCookies',
      params: <String, dynamic>{
        'cookies': cookies
            .map((BrowserCookie c) => <String, dynamic>{
                  'name': c.name,
                  'value': c.value,
                  if (c.domain != null) 'domain': c.domain,
                  if (c.path != null) 'path': c.path,
                  if (c.expires != null)
                    'expires': c.expires!.millisecondsSinceEpoch / 1000.0,
                  'httpOnly': c.httpOnly,
                  'secure': c.secure,
                  if (c.sameSite != null) 'sameSite': c.sameSite,
                })
            .toList(growable: false),
      },
      sessionId: payload.sessionId,
    );
  }

  @override
  Future<void> setExtraHeaders(
    BrowserContextHandle handle,
    Map<String, String> headers,
  ) async {
    final payload = handle.enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    await client.send('Network.enable', sessionId: payload.sessionId);
    await client.send(
      'Network.setExtraHTTPHeaders',
      params: <String, dynamic>{'headers': headers},
      sessionId: payload.sessionId,
    );
  }

  @override
  Future<void> setDownloadHandler(
    BrowserContextHandle handle,
    String directory,
  ) async {
    final payload = handle.enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    try {
      await client.send(
        'Browser.setDownloadBehavior',
        params: <String, dynamic>{
          'behavior': 'allow',
          'downloadPath': directory,
          if (payload.browserContextId != null)
            'browserContextId': payload.browserContextId,
        },
      );
    } on Object {
      await client.send(
        'Page.setDownloadBehavior',
        params: <String, dynamic>{
          'behavior': 'allow',
          'downloadPath': directory,
        },
        sessionId: payload.sessionId,
      );
    }
  }
}
