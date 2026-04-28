/// BrowserSearchPort - search-provider adapter contract.
library;

import '../types/browser_types.dart';

/// Search provider adapter. Implementations may be API-backed (Google CSE,
/// Brave API, ...) or browser-backed (SERP scraping). The advertised
/// mode(s) live on [describe].
abstract class BrowserSearchPort {
  /// Self-description used by the router for capability negotiation.
  BrowserSearchProviderDescriptor describe();

  /// Execute the search.
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  );
}
