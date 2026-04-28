/// BrowserExtractionTemplatePort - CRUD + evaluation contract for
/// extraction templates.
library;

import '../types/browser_types.dart';

/// Storage and evaluation surface for [BrowserExtractionTemplate].
abstract class BrowserExtractionTemplatePort {
  /// Persist [template]. Existing `(id, version)` entries are overwritten.
  Future<void> register(BrowserExtractionTemplate template);

  /// Fetch a template. When [version] is `null` the latest semver is
  /// returned.
  Future<BrowserExtractionTemplate?> get(String id, {String? version});

  /// Metadata listing (no body).
  Future<List<BrowserExtractionTemplateMeta>> list();

  /// Remove a specific version.
  Future<void> remove(String id, String version);

  /// Apply [template] to [html] (with optional [pageUrl] base) and return
  /// the structured output. Throws [BrowserExtractionSchemaError] when
  /// required fields are missing (partial result attached to the error).
  Future<Map<String, dynamic>> evaluate(
    BrowserExtractionTemplate template, {
    required String html,
    String? pageUrl,
  });
}
