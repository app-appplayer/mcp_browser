/// Test-only fakes that satisfy `BrowserEnginePort` + `BrowserContextPort`.
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';

class FakeEnginePayload {
  FakeEnginePayload(this.label);
  final String label;
  bool closed = false;
  Map<String, dynamic> storageState = <String, dynamic>{};
  List<BrowserCookie> cookies = <BrowserCookie>[];
  Map<String, String> extraHeaders = <String, String>{};
  String? downloadDirectory;
}

class FakeEngine implements BrowserEnginePort {

  FakeEngine({
    this.engineId = 'fake',
    Set<EngineCapability>? capabilities,
  }) : capabilities = capabilities ??
            <EngineCapability>{
              EngineCapability.headless,
              EngineCapability.executeNavigate,
              EngineCapability.executeClick,
              EngineCapability.readDom,
              EngineCapability.readScreenshot,
              EngineCapability.subscribeConsole,
            };
  final String engineId;
  final Set<EngineCapability> capabilities;
  bool initialized = false;
  bool wasShutdown = false;
  int readCalls = 0;
  int executeCalls = 0;

  /// Optional override for [read] results.
  BrowserPayloadEnvelope Function(
      BrowserContextHandle handle, BrowserReadSpec spec)? readImpl;

  /// Optional override for [execute] results.
  BrowserActionResult Function(
      BrowserContextHandle handle, BrowserAction action)? executeImpl;

  /// Optional override for [subscribe] streams.
  Stream<BrowserEvent> Function(
      BrowserContextHandle handle, BrowserTopic topic)? subscribeImpl;

  @override
  EngineDescriptor describe() => EngineDescriptor(
        id: engineId,
        name: 'FakeEngine',
        version: '0.0.1',
        capabilities: capabilities,
      );

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<void> shutdown() async {
    wasShutdown = true;
  }

  @override
  Future<BrowserPayloadEnvelope> read(
    BrowserContextHandle handle,
    BrowserReadSpec spec,
  ) async {
    readCalls++;
    if (readImpl != null) return readImpl!(handle, spec);
    return BrowserPayloadEnvelope(
      contextId: handle.contextId,
      mime: 'text/plain',
      body: 'fake:${spec.kind.name}',
    );
  }

  @override
  Future<BrowserActionResult> execute(
    BrowserContextHandle handle,
    BrowserAction action,
  ) async {
    executeCalls++;
    if (executeImpl != null) return executeImpl!(handle, action);
    return const BrowserActionResult(success: true);
  }

  @override
  Stream<BrowserEvent> subscribe(
    BrowserContextHandle handle,
    BrowserTopic topic,
  ) {
    if (subscribeImpl != null) return subscribeImpl!(handle, topic);
    return const Stream<BrowserEvent>.empty();
  }
}

class FakeContextPort implements BrowserContextPort {
  int openCalls = 0;
  int closeCalls = 0;
  int saveStateCalls = 0;
  int restoreStateCalls = 0;
  Map<String, dynamic>? lastRestoredState;

  @override
  Future<Object> openContext(BrowserContextSpec spec) async {
    openCalls++;
    return FakeEnginePayload('${spec.tenantId}|${spec.actorId ?? ''}');
  }

  @override
  Future<void> closeContext(Object enginePayload) async {
    closeCalls++;
    if (enginePayload is FakeEnginePayload) {
      enginePayload.closed = true;
    }
  }

  @override
  Future<Map<String, dynamic>> saveStorageState(Object enginePayload) async {
    saveStateCalls++;
    if (enginePayload is FakeEnginePayload) {
      return Map<String, dynamic>.from(enginePayload.storageState);
    }
    return <String, dynamic>{};
  }

  @override
  Future<void> restoreStorageState(
    Object enginePayload,
    Map<String, dynamic> state,
  ) async {
    restoreStateCalls++;
    lastRestoredState = state;
    if (enginePayload is FakeEnginePayload) {
      enginePayload.storageState = Map<String, dynamic>.from(state);
    }
  }

  @override
  Future<void> setCookies(
    BrowserContextHandle handle,
    List<BrowserCookie> cookies,
  ) async {
    if (handle.enginePayload is FakeEnginePayload) {
      (handle.enginePayload as FakeEnginePayload).cookies =
          List<BrowserCookie>.from(cookies);
    }
  }

  @override
  Future<void> setExtraHeaders(
    BrowserContextHandle handle,
    Map<String, String> headers,
  ) async {
    if (handle.enginePayload is FakeEnginePayload) {
      (handle.enginePayload as FakeEnginePayload).extraHeaders =
          Map<String, String>.from(headers);
    }
  }

  @override
  Future<void> setDownloadHandler(
    BrowserContextHandle handle,
    String directory,
  ) async {
    if (handle.enginePayload is FakeEnginePayload) {
      (handle.enginePayload as FakeEnginePayload).downloadDirectory = directory;
    }
  }
}
