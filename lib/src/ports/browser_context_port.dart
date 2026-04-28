/// BrowserContextPort - lifecycle contract for engine-managed browser contexts.
///
/// Engine adapters implement this in tandem with [BrowserEnginePort]; the
/// core's `ContextRegistry` calls into it to acquire/release handles and to
/// snapshot/restore storage state for persistent profiles.
library;

import '../types/browser_types.dart';

/// Lifecycle surface for browser contexts.
abstract class BrowserContextPort {
  /// Create a new engine-side context for [spec]. Returns the engine-opaque
  /// payload to embed in [BrowserContextHandle.enginePayload].
  Future<Object> openContext(BrowserContextSpec spec);

  /// Tear down the engine-side context identified by [enginePayload].
  Future<void> closeContext(Object enginePayload);

  /// Capture a serializable storage state snapshot (cookies, localStorage,
  /// IndexedDB if supported) for later [restoreStorageState].
  Future<Map<String, dynamic>> saveStorageState(Object enginePayload);

  /// Replay a previously captured storage state into [enginePayload].
  Future<void> restoreStorageState(
    Object enginePayload,
    Map<String, dynamic> state,
  );

  /// Inject [cookies] into the context.
  Future<void> setCookies(
    BrowserContextHandle handle,
    List<BrowserCookie> cookies,
  );

  /// Inject extra request [headers] applied to all requests in the context.
  Future<void> setExtraHeaders(
    BrowserContextHandle handle,
    Map<String, String> headers,
  );

  /// Configure the directory where downloads triggered in [handle] are saved.
  Future<void> setDownloadHandler(
    BrowserContextHandle handle,
    String directory,
  );
}
