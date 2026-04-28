/// BrowserEnginePort - 4-Primitive contract for browser engine adapters.
///
/// Engines (cdp, playwright, puppeteer, webkit, ...) implement this single
/// interface. The mcp_browser core dispatches reads/executes/subscribes
/// against the resolved engine for each context handle.
library;

import '../types/browser_types.dart';

/// Engine-side surface of the 4-Primitive Contract.
abstract class BrowserEnginePort {
  /// Self-description for capability negotiation and `describe()` output.
  EngineDescriptor describe();

  /// Initialize engine resources (e.g., spawn Chromium, prewarm pool).
  Future<void> initialize();

  /// Release all engine resources. Idempotent.
  Future<void> shutdown();

  /// Non-mutating extraction.
  Future<BrowserPayloadEnvelope> read(
    BrowserContextHandle handle,
    BrowserReadSpec spec,
  );

  /// State-changing command.
  Future<BrowserActionResult> execute(
    BrowserContextHandle handle,
    BrowserAction action,
  );

  /// Stream of events for [topic] within [handle]. The stream completes when
  /// the handle is closed or the topic is no longer available.
  Stream<BrowserEvent> subscribe(
    BrowserContextHandle handle,
    BrowserTopic topic,
  );
}
