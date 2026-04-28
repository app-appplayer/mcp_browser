/// BrowserAuditPort - Audit contract for browser runtime operations.
///
/// Captures every read/execute call with redacted parameters and a decision
/// marker. Records flow into a [BrowserAuditSink] which is responsible for
/// long-term persistence (KV, file, external system).
library;

import '../types/browser_types.dart';

/// Contract surfaced to the browser runtime.
abstract class BrowserAuditPort {
  /// Record a non-mutating read.
  Future<void> recordRead(
    String? contextId,
    BrowserReadSpec spec,
    Map<String, dynamic> meta,
  );

  /// Record a state-changing execute call.
  Future<void> recordExecute(
    String? contextId,
    BrowserAction action,
    BrowserActionResult result,
    BrowserPolicyDecision decision,
  );

  /// Stream records matching [filter]. Order is sink-defined but typically
  /// chronological.
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter);

  /// Force any buffered records to be written through to the sink.
  Future<void> flush();
}

/// Persistence contract for [BrowserAuditPort] implementations.
abstract class BrowserAuditSink {
  /// Persist a single record.
  Future<void> write(BrowserAuditRecord record);

  /// Optional explicit flush hook (e.g., to commit a batch).
  Future<void> flush();

  /// Stream stored records matching [filter].
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter);

  /// Optional cleanup hook (e.g., close file handles, drop subscriptions).
  Future<void> close();
}
