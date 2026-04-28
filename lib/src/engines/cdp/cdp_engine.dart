/// Built-in CDP engine — pure Dart implementation of `BrowserEnginePort`.
///
/// Talks directly to Chromium's DevTools Protocol over WebSocket (no
/// puppeteer, no Node runtime). All navigation/read/execute/subscribe
/// primitives map to CDP commands and events.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../_internal.dart';

import 'cdp_client.dart';
import 'cdp_launcher.dart';

/// Engine-side payload — attached target session id + bookkeeping.
class CdpEnginePayload {
  const CdpEnginePayload({
    required this.targetId,
    required this.sessionId,
    this.browserContextId,
  });

  /// Target (tab) identifier.
  final String targetId;

  /// Flattened session id used for per-target commands.
  final String sessionId;

  /// Optional BrowserContext (incognito) id.
  final String? browserContextId;
}

/// Singleton CDP client shared across engine + context port.
///
/// Hosts normally don't interact with this directly — they construct
/// [CdpEngine] / [CdpContextPort] and the client is lazily booted on first
/// use.
class CdpConnection {
  CdpConnection({ChromiumLauncher? launcher})
      : _launcher = launcher ?? ChromiumLauncher.shared();

  final ChromiumLauncher _launcher;
  CdpClient? _client;

  Future<CdpClient> client() async {
    if (_client != null) return _client!;
    final chromium = await _launcher.browser();
    _client = await CdpClient.connect(chromium.wsUrl);
    return _client!;
  }

  Future<void> close() async {
    await _client?.close();
    _client = null;
    await _launcher.close();
  }
}

class CdpEngine implements BrowserEnginePort {
  CdpEngine({CdpConnection? connection})
      : _connection = connection ?? CdpConnection();

  final CdpConnection _connection;

  @override
  EngineDescriptor describe() => const EngineDescriptor(
        id: 'cdp',
        name: 'Built-in CDP (pure Dart)',
        version: '0.1.0',
        capabilities: <EngineCapability>{
          EngineCapability.headless,
          EngineCapability.headful,
          EngineCapability.readDom,
          EngineCapability.readScreenshot,
          EngineCapability.readPdf,
          EngineCapability.executeNavigate,
          EngineCapability.executeClick,
          EngineCapability.executeType,
          EngineCapability.executeFill,
          EngineCapability.executeEval,
          EngineCapability.subscribeConsole,
          EngineCapability.subscribeNetwork,
          EngineCapability.contextEmulation,
        },
      );

  @override
  Future<void> initialize() async {
    final c = await _connection.client();
    // Enable domain events at the browser level once.
    await c.send('Target.setDiscoverTargets', params: <String, dynamic>{
      'discover': true,
    });
  }

  @override
  Future<void> shutdown() async {
    await _connection.close();
  }

  @override
  Future<BrowserPayloadEnvelope> read(
    BrowserContextHandle handle,
    BrowserReadSpec spec,
  ) async {
    final payload = handle.enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    switch (spec.kind) {
      case BrowserReadKind.html:
        final doc = await client.send(
          'DOM.getDocument',
          params: <String, dynamic>{'depth': -1},
          sessionId: payload.sessionId,
        );
        final root = Map<String, dynamic>.from(doc['root'] as Map);
        final outer = await client.send(
          'DOM.getOuterHTML',
          params: <String, dynamic>{'nodeId': root['nodeId']},
          sessionId: payload.sessionId,
        );
        final body = spec.selector == null
            ? (outer['outerHTML'] as String? ?? '')
            : await _evalReturnValue<String>(
                client,
                payload.sessionId,
                'document.querySelector(${jsonEncode(spec.selector)})?.outerHTML ?? ""',
              );
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'text/html',
          body: body,
          meta: <String, dynamic>{'pageUrl': await _currentUrl(client, payload)},
        );
      case BrowserReadKind.text:
        final body = spec.selector == null
            ? await _evalReturnValue<String>(
                client,
                payload.sessionId,
                'document.body?.innerText ?? ""',
              )
            : await _evalReturnValue<String>(
                client,
                payload.sessionId,
                'document.querySelector(${jsonEncode(spec.selector)})?.innerText ?? ""',
              );
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'text/plain',
          body: body,
          meta: <String, dynamic>{'pageUrl': await _currentUrl(client, payload)},
        );
      case BrowserReadKind.markdown:
      case BrowserReadKind.dom:
      case BrowserReadKind.extract:
        // Return HTML; runtime post-processes (mcp_ingest / ExtractionRegistry).
        final outer = await _evalReturnValue<String>(
          client,
          payload.sessionId,
          'document.documentElement?.outerHTML ?? ""',
        );
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'text/html',
          body: outer,
          meta: <String, dynamic>{'pageUrl': await _currentUrl(client, payload)},
        );
      case BrowserReadKind.ariaTree:
        final tree = await client.send(
          'Accessibility.getFullAXTree',
          sessionId: payload.sessionId,
        );
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'application/json',
          body: (tree['nodes'] as Object?) ?? const <dynamic>[],
          meta: <String, dynamic>{'pageUrl': await _currentUrl(client, payload)},
        );
      case BrowserReadKind.screenshot:
        final fullPage = (spec.options['fullPage'] as bool?) ?? false;
        final shot = await client.send(
          'Page.captureScreenshot',
          params: <String, dynamic>{
            'format': 'png',
            if (fullPage) 'captureBeyondViewport': true,
          },
          sessionId: payload.sessionId,
        );
        final bytes =
            base64Decode(shot['data'] as String? ?? '');
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'image/png',
          body: Uint8List.fromList(bytes),
          meta: <String, dynamic>{
            'pageUrl': await _currentUrl(client, payload),
            'fullPage': fullPage,
            'sizeBytes': bytes.length,
          },
        );
      case BrowserReadKind.pdf:
        final pdf = await client.send(
          'Page.printToPDF',
          sessionId: payload.sessionId,
        );
        final bytes = base64Decode(pdf['data'] as String? ?? '');
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'application/pdf',
          body: Uint8List.fromList(bytes),
          meta: <String, dynamic>{
            'pageUrl': await _currentUrl(client, payload),
            'sizeBytes': bytes.length,
          },
        );
      case BrowserReadKind.cookies:
        final result = await client.send(
          'Network.getCookies',
          sessionId: payload.sessionId,
        );
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'application/json',
          body: (result['cookies'] as Object?) ?? const <dynamic>[],
        );
      case BrowserReadKind.storage:
        final result = await _evalReturnValue<Map<String, dynamic>>(
          client,
          payload.sessionId,
          '({localStorage: Object.fromEntries(Object.entries(localStorage)),'
          ' sessionStorage: Object.fromEntries(Object.entries(sessionStorage))})',
        );
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'application/json',
          body: result,
        );
      case BrowserReadKind.har:
        return BrowserPayloadEnvelope(
          contextId: handle.contextId,
          mime: 'application/har+json',
          body: const <String, dynamic>{
            'log': <String, dynamic>{'version': '1.2', 'entries': <dynamic>[]},
          },
          meta: const <String, dynamic>{'harNotAvailable': true},
        );
    }
  }

  @override
  Future<BrowserActionResult> execute(
    BrowserContextHandle handle,
    BrowserAction action,
  ) async {
    final payload = handle.enginePayload as CdpEnginePayload;
    final client = await _connection.client();
    try {
      switch (action.kind) {
        case BrowserActionKind.navigate:
          final url = action.params['url'] as String;
          await client.send(
            'Page.enable',
            sessionId: payload.sessionId,
          );
          final navPromise = client.send(
            'Page.navigate',
            params: <String, dynamic>{'url': url},
            sessionId: payload.sessionId,
          );
          final waitUntil = (action.params['waitUntil'] as String?) ?? 'load';
          await navPromise;
          await _waitForLoad(client, payload.sessionId, waitUntil);
          return const BrowserActionResult(success: true);
        case BrowserActionKind.reload:
          await client.send('Page.reload', sessionId: payload.sessionId);
          await _waitForLoad(client, payload.sessionId, 'load');
          return const BrowserActionResult(success: true);
        case BrowserActionKind.back:
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            'history.back()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.forward:
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            'history.forward()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.click:
        case BrowserActionKind.dblclick:
          final selector = action.params['selector'] as String;
          final clicks =
              action.kind == BrowserActionKind.dblclick ? 2 : 1;
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            '(() => { const el = document.querySelector(${jsonEncode(selector)}); '
            'if (!el) throw new Error("selector not found: ${_escape(selector)}"); '
            'for (let i=0; i<$clicks; i++) el.click(); })()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.hover:
          final selector = action.params['selector'] as String;
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            '(() => { const el = document.querySelector(${jsonEncode(selector)}); '
            'if (!el) throw new Error("selector not found"); '
            'el.dispatchEvent(new MouseEvent("mouseover", {bubbles:true})); })()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.type:
        case BrowserActionKind.fill:
          final selector = action.params['selector'] as String;
          final value = action.params['value'] as String? ?? '';
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            '(() => { const el = document.querySelector(${jsonEncode(selector)}); '
            'if (!el) throw new Error("selector not found"); '
            'el.focus(); el.value = ${jsonEncode(value)}; '
            'el.dispatchEvent(new Event("input", {bubbles:true})); '
            'el.dispatchEvent(new Event("change", {bubbles:true})); })()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.press:
          final key = action.params['key'] as String;
          await client.send(
            'Input.dispatchKeyEvent',
            params: <String, dynamic>{'type': 'keyDown', 'key': key},
            sessionId: payload.sessionId,
          );
          await client.send(
            'Input.dispatchKeyEvent',
            params: <String, dynamic>{'type': 'keyUp', 'key': key},
            sessionId: payload.sessionId,
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.select:
          final selector = action.params['selector'] as String;
          final raw = action.params['value'];
          final values = raw is List ? List<String>.from(raw) : <String>[raw as String];
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            '(() => { const el = document.querySelector(${jsonEncode(selector)}); '
            'if (!el) throw new Error("selector not found"); '
            'const vs = ${jsonEncode(values)}; '
            '[...el.options].forEach(o => o.selected = vs.includes(o.value)); '
            'el.dispatchEvent(new Event("change", {bubbles:true})); })()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.check:
          final selector = action.params['selector'] as String;
          await _evalReturnValue<void>(
            client,
            payload.sessionId,
            '(() => { const el = document.querySelector(${jsonEncode(selector)}); '
            'if (!el) throw new Error("selector not found"); '
            'el.checked = true; el.dispatchEvent(new Event("change", {bubbles:true})); })()',
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.upload:
          final selector = action.params['selector'] as String;
          final raw = action.params['file'];
          final files = raw is List ? List<String>.from(raw) : <String>[raw as String];
          final doc = await client.send('DOM.getDocument',
              sessionId: payload.sessionId);
          final rootId = (doc['root'] as Map)['nodeId'];
          final node = await client.send(
            'DOM.querySelector',
            params: <String, dynamic>{
              'nodeId': rootId,
              'selector': selector,
            },
            sessionId: payload.sessionId,
          );
          await client.send(
            'DOM.setFileInputFiles',
            params: <String, dynamic>{
              'files': files,
              'nodeId': node['nodeId'],
            },
            sessionId: payload.sessionId,
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.evalJs:
          final expression = action.params['expression'] as String;
          final value = await _evalReturnValue<dynamic>(
            client,
            payload.sessionId,
            expression,
          );
          return BrowserActionResult(
            success: true,
            output: <String, dynamic>{'result': value},
          );
        case BrowserActionKind.setViewport:
          final width = (action.params['width'] as num?)?.toInt() ?? 1280;
          final height = (action.params['height'] as num?)?.toInt() ?? 800;
          await client.send(
            'Emulation.setDeviceMetricsOverride',
            params: <String, dynamic>{
              'width': width,
              'height': height,
              'deviceScaleFactor': 1,
              'mobile': false,
            },
            sessionId: payload.sessionId,
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.setLocale:
          final locale = action.params['locale'] as String?;
          if (locale != null) {
            await client.send(
              'Emulation.setLocaleOverride',
              params: <String, dynamic>{'locale': locale},
              sessionId: payload.sessionId,
            );
          }
          return const BrowserActionResult(success: true);
        case BrowserActionKind.setTimezone:
          final tz = action.params['timezone'] as String?;
          if (tz != null) {
            await client.send(
              'Emulation.setTimezoneOverride',
              params: <String, dynamic>{'timezoneId': tz},
              sessionId: payload.sessionId,
            );
          }
          return const BrowserActionResult(success: true);
        case BrowserActionKind.emulateDevice:
          return const BrowserActionResult(success: true);
        case BrowserActionKind.intercept:
          await client.send(
            'Fetch.enable',
            sessionId: payload.sessionId,
          );
          return const BrowserActionResult(success: true);
        case BrowserActionKind.setAuth:
        case BrowserActionKind.search:
        case BrowserActionKind.crawl:
        case BrowserActionKind.download:
        case BrowserActionKind.openContext:
        case BrowserActionKind.closeContext:
        case BrowserActionKind.drag:
          return BrowserActionResult(
            success: false,
            errorCode: 'E1000',
            errorMessage:
                '${action.kind.name} is routed outside the engine layer',
          );
      }
    } on CdpError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E3001',
        errorMessage: e.message,
      );
    } on Object catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E3001',
        errorMessage: '$e',
      );
    }
  }

  @override
  Stream<BrowserEvent> subscribe(
    BrowserContextHandle handle,
    BrowserTopic topic,
  ) {
    final payload = handle.enginePayload as CdpEnginePayload;
    return _subscribeEvents(handle, payload, topic);
  }

  Stream<BrowserEvent> _subscribeEvents(
    BrowserContextHandle handle,
    CdpEnginePayload payload,
    BrowserTopic topic,
  ) async* {
    final client = await _connection.client();
    // Enable the relevant domain on first subscribe; repeated calls are
    // idempotent at the CDP level.
    switch (topic.kind) {
      case BrowserTopicKind.consoleLog:
      case BrowserTopicKind.consoleWarn:
      case BrowserTopicKind.consoleError:
        await client.send('Runtime.enable', sessionId: payload.sessionId);
        await for (final event in client.events.where(
          (CdpEvent e) =>
              e.sessionId == payload.sessionId &&
              (e.method == 'Runtime.consoleAPICalled' ||
                  e.method == 'Runtime.exceptionThrown'),
        )) {
          final kind = event.method == 'Runtime.exceptionThrown'
              ? BrowserTopicKind.consoleError
              : _consoleKindOf(event.params['type'] as String?);
          if (kind != topic.kind) continue;
          yield BrowserEvent(
            topic: kind,
            contextId: handle.contextId,
            payload: _flattenConsoleParams(event.params),
          );
        }
        return;
      case BrowserTopicKind.request:
        await client.send('Network.enable', sessionId: payload.sessionId);
        await for (final event in client.events.where(
          (CdpEvent e) =>
              e.sessionId == payload.sessionId &&
              e.method == 'Network.requestWillBeSent',
        )) {
          final request = event.params['request'] as Map? ?? <String, dynamic>{};
          yield BrowserEvent(
            topic: topic.kind,
            contextId: handle.contextId,
            payload: <String, dynamic>{
              'url': request['url'],
              'method': request['method'],
              'resourceType': event.params['type'],
            },
          );
        }
        return;
      case BrowserTopicKind.response:
        await client.send('Network.enable', sessionId: payload.sessionId);
        await for (final event in client.events.where(
          (CdpEvent e) =>
              e.sessionId == payload.sessionId &&
              e.method == 'Network.responseReceived',
        )) {
          final response = event.params['response'] as Map? ?? <String, dynamic>{};
          yield BrowserEvent(
            topic: topic.kind,
            contextId: handle.contextId,
            payload: <String, dynamic>{
              'url': response['url'],
              'status': response['status'],
              'statusText': response['statusText'],
            },
          );
        }
        return;
      case BrowserTopicKind.requestFailed:
        await client.send('Network.enable', sessionId: payload.sessionId);
        await for (final event in client.events.where(
          (CdpEvent e) =>
              e.sessionId == payload.sessionId &&
              e.method == 'Network.loadingFailed',
        )) {
          yield BrowserEvent(
            topic: topic.kind,
            contextId: handle.contextId,
            payload: <String, dynamic>{
              'requestId': event.params['requestId'],
              'errorText': event.params['errorText'],
              'canceled': event.params['canceled'],
            },
          );
        }
        return;
      case BrowserTopicKind.dialog:
        await client.send('Page.enable', sessionId: payload.sessionId);
        await for (final event in client.events.where(
          (CdpEvent e) =>
              e.sessionId == payload.sessionId &&
              e.method == 'Page.javascriptDialogOpening',
        )) {
          yield BrowserEvent(
            topic: topic.kind,
            contextId: handle.contextId,
            payload: <String, dynamic>{
              'type': event.params['type'],
              'message': event.params['message'],
              'url': event.params['url'],
            },
          );
        }
        return;
      case BrowserTopicKind.domMutation:
      case BrowserTopicKind.downloadStarted:
      case BrowserTopicKind.downloadFinished:
      case BrowserTopicKind.crawlProgress:
        return;
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Future<void> _waitForLoad(
    CdpClient client,
    String sessionId,
    String waitUntil,
  ) async {
    switch (waitUntil) {
      case 'domcontentloaded':
        await client.waitForEvent(
          'Page.domContentEventFired',
          sessionId: sessionId,
          timeout: const Duration(seconds: 30),
        );
        return;
      case 'networkidle':
      case 'networkIdle':
        // Best-effort: wait for the load event then settle 500ms. A real
        // networkidle tracker would count in-flight requests; we approximate
        // to keep the pure-Dart implementation small.
        await client.waitForEvent(
          'Page.loadEventFired',
          sessionId: sessionId,
          timeout: const Duration(seconds: 30),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return;
      case 'load':
      default:
        await client.waitForEvent(
          'Page.loadEventFired',
          sessionId: sessionId,
          timeout: const Duration(seconds: 30),
        );
        return;
    }
  }

  Future<T> _evalReturnValue<T>(
    CdpClient client,
    String sessionId,
    String expression,
  ) async {
    final result = await client.send(
      'Runtime.evaluate',
      params: <String, dynamic>{
        'expression': expression,
        'returnByValue': true,
        'awaitPromise': true,
      },
      sessionId: sessionId,
    );
    final exception = result['exceptionDetails'];
    if (exception is Map) {
      final msg =
          (exception['text'] as String?) ?? 'evaluation failed';
      throw CdpError(message: msg);
    }
    final inner = result['result'] as Map? ?? const <String, dynamic>{};
    final value = inner['value'];
    if (value == null) return null as T;
    return value as T;
  }

  Future<String?> _currentUrl(
    CdpClient client,
    CdpEnginePayload payload,
  ) async {
    try {
      return await _evalReturnValue<String>(
        client,
        payload.sessionId,
        'document.location?.href ?? ""',
      );
    } on Object {
      return null;
    }
  }

  BrowserTopicKind _consoleKindOf(String? type) {
    switch (type) {
      case 'warning':
        return BrowserTopicKind.consoleWarn;
      case 'error':
        return BrowserTopicKind.consoleError;
      default:
        return BrowserTopicKind.consoleLog;
    }
  }

  Map<String, dynamic> _flattenConsoleParams(Map<String, dynamic> params) {
    final args = params['args'] as List?;
    String? text;
    if (args != null && args.isNotEmpty) {
      text = args
          .map((dynamic a) {
            if (a is Map && a['value'] != null) return a['value'].toString();
            return (a as Map?)?['description']?.toString() ?? '';
          })
          .join(' ');
    }
    return <String, dynamic>{
      if (text != null) 'text': text,
      'type': params['type'] ?? 'log',
    };
  }

  static String _escape(String s) =>
      s.replaceAll('\\', r'\\').replaceAll('"', r'\"');
}
