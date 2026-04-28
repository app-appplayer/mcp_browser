/// BrowserDownloadPort - file download contract for mcp_browser.
library;

import '../types/browser_types.dart';

/// Surface for triggering and observing file downloads.
abstract class BrowserDownloadPort {
  /// Execute a download. Returns the final descriptor on success.
  Future<BrowserDownloadDescriptor> download(BrowserDownloadSpec spec);

  /// Lookup a previously recorded download by id.
  Future<BrowserDownloadDescriptor?> getDownload(String id);

  /// List recorded downloads, optionally filtered by tenant/context.
  Future<List<BrowserDownloadDescriptor>> listDownloads({
    String? tenantId,
    String? contextScopeId,
  });

  /// Remove the descriptor record (and the file when present on disk).
  Future<void> deleteDownload(String id);

  /// Broadcast stream of lifecycle events.
  Stream<BrowserDownloadEvent> get downloadEvents;
}
