/// MOD-REG-005 — SearchRouter + SearchCache.
///
/// See `docs/03_DDD/08-search.md` for the design specification and
/// `docs/04_TEST/08-search.md` for the test plan.
library;

import 'dart:convert';

import '../_internal.dart';

/// Error thrown when a provider id is missing or doesn't support the
/// requested mode. Maps to E6001.
class SearchProviderNotRegisteredError extends StateError {
  SearchProviderNotRegisteredError(String message)
      : super('E6001 SearchProviderNotRegistered: $message');
}

/// Error thrown when an external provider rate-limited us. Maps to E6002.
class SearchRateLimitedError extends StateError {
  SearchRateLimitedError(String providerId)
      : super('E6002 SearchProviderRateLimited: $providerId');
}

/// Error thrown when browser-mode SERP parsing fails. Maps to E6003.
class SearchSerpParseError extends StateError {
  SearchSerpParseError(String providerId, String reason)
      : super('E6003 SearchSerpParseFailed: $providerId — $reason');
}

/// Marker interface adapters may implement to opt into the router's
/// rate-limit handling (otherwise plain exceptions are passed through).
class SearchProviderRateLimitException implements Exception {
  SearchProviderRateLimitException(this.message);
  final String message;
  @override
  String toString() => 'SearchProviderRateLimitException: $message';
}

/// In-memory + optional KV-backed result cache.
class SearchCache {

  SearchCache({this.kv, DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final KvStoragePort? kv;
  final DateTime Function() _now;
  final Map<String, _CacheEntry> _hot = <String, _CacheEntry>{};

  String keyOf(
    String providerId,
    String query,
    BrowserSearchOptions options,
  ) =>
      options.hashFor(providerId, query);

  /// Returns cached results when present and within [ttl]; otherwise null.
  Future<List<BrowserSearchResult>?> get(String key, Duration ttl) async {
    if (ttl == Duration.zero) return null;
    final hot = _hot[key];
    final now = _now();
    if (hot != null && now.difference(hot.storedAt) < ttl) {
      return hot.results;
    }
    if (kv != null) {
      final raw = await kv!.get(_kvKey(key));
      if (raw is String) {
        try {
          final json = jsonDecode(raw) as Map<dynamic, dynamic>;
          final ts = DateTime.parse(json['storedAt'] as String);
          if (now.difference(ts) < ttl) {
            final results = (json['results'] as List<dynamic>)
                .map((dynamic e) => BrowserSearchResult.fromJson(
                    Map<String, dynamic>.from(e as Map)))
                .toList(growable: false);
            _hot[key] = _CacheEntry(results, ts);
            return results;
          }
        } on Object {/* fall through to miss */}
      }
    }
    return null;
  }

  Future<void> put(String key, List<BrowserSearchResult> value) async {
    final stamp = _now();
    _hot[key] = _CacheEntry(value, stamp);
    if (kv != null) {
      await kv!.set(_kvKey(key), jsonEncode(<String, dynamic>{
        'storedAt': stamp.toIso8601String(),
        'results':
            value.map((BrowserSearchResult r) => r.toJson()).toList(),
      }));
    }
  }

  static String _kvKey(String key) => 'mcp_browser/search_cache/$key';
}

class _CacheEntry {
  _CacheEntry(this.results, this.storedAt);
  final List<BrowserSearchResult> results;
  final DateTime storedAt;
}

/// Router over registered [BrowserSearchPort] adapters with caching and
/// mode validation.
class SearchRouter {

  SearchRouter({SearchCache? cache}) : cache = cache ?? SearchCache();
  final SearchCache cache;
  final Map<String, BrowserSearchPort> _providers =
      <String, BrowserSearchPort>{};

  void register(String providerId, BrowserSearchPort adapter) {
    _providers[providerId] = adapter;
  }

  void unregister(String providerId) {
    _providers.remove(providerId);
  }

  /// Snapshot of all registered providers' descriptors.
  List<BrowserSearchProviderDescriptor> providers() => _providers.values
      .map((BrowserSearchPort p) => p.describe())
      .toList(growable: false);

  /// Execute a search.
  Future<List<BrowserSearchResult>> search(
    String query, {
    required String providerId,
    BrowserSearchOptions options = const BrowserSearchOptions(),
  }) async {
    final provider = _providers[providerId];
    if (provider == null) {
      throw SearchProviderNotRegisteredError(providerId);
    }
    final descriptor = provider.describe();
    final mode = options.mode;
    if (mode != null && !descriptor.supports(mode)) {
      throw SearchProviderNotRegisteredError(
        '$providerId does not support mode ${mode.name}',
      );
    }

    final cacheKey = cache.keyOf(providerId, query, options);
    final cached = await cache.get(cacheKey, options.cacheTtl);
    if (cached != null) return cached;

    try {
      final results = await provider.search(query, options);
      await cache.put(cacheKey, results);
      return results;
    } on SearchProviderRateLimitException catch (e) {
      throw SearchRateLimitedError('$providerId: ${e.message}');
    } on SearchSerpParseError {
      rethrow;
    } on Object {
      rethrow;
    }
  }
}
