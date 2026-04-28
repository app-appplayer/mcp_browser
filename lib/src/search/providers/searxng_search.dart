/// Built-in SearXNG adapter (self-hosted metasearch).
///
/// Points at any SearXNG instance that exposes the JSON format
/// (`?format=json`). No API key required by default, but hosts can add a
/// `SEARXNG_API_KEY` header when their instance mandates it.
library;

import '../../_internal.dart';

import '../../ops/http_fetcher.dart';
import '_common.dart';

class SearxngSearchAdapter implements BrowserSearchPort {
  SearxngSearchAdapter({
    required this.baseUrl,
    required this.fetcher,
    this.apiKey,
  });

  /// Base URL of the SearXNG instance, e.g. `https://searxng.example.com`.
  final String baseUrl;
  final HttpFetcher fetcher;
  final String? apiKey;

  @override
  BrowserSearchProviderDescriptor describe() {
    return BrowserSearchProviderDescriptor(
      id: 'searxng',
      name: 'SearXNG ($baseUrl)',
      supportedModes: const <BrowserSearchMode>{BrowserSearchMode.api},
      supportedIntents: const <BrowserSearchIntent>{
        BrowserSearchIntent.web,
        BrowserSearchIntent.news,
        BrowserSearchIntent.images,
        BrowserSearchIntent.videos,
      },
      requiresKey: apiKey != null,
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    final category = switch (options.intent) {
      BrowserSearchIntent.news => 'news',
      BrowserSearchIntent.images => 'images',
      BrowserSearchIntent.videos => 'videos',
      BrowserSearchIntent.academic => 'science',
      _ => 'general',
    };
    final uri = Uri.parse(baseUrl).replace(
      path: '/search',
      queryParameters: <String, String>{
        'q': query,
        'format': 'json',
        'categories': category,
        'pageno': ((options.offset ~/ options.limit) + 1).toString(),
        if (options.language != null) 'language': options.language!,
      },
    );
    final response = await fetcher.fetch(uri.toString(), headers: <String, String>{
      'Accept': 'application/json',
      if (apiKey != null) 'Authorization': 'Bearer $apiKey',
    });
    final json = await decodeJsonResponse(response, providerId: 'searxng');
    final results =
        (json['results'] as List<dynamic>?) ?? const <dynamic>[];
    final limit = options.limit;
    return results
        .take(limit)
        .toList()
        .asMap()
        .entries
        .map<BrowserSearchResult>((MapEntry<int, dynamic> entry) {
      final m = Map<String, dynamic>.from(entry.value as Map);
      final publishedRaw = m['publishedDate'] as String?;
      return BrowserSearchResult(
        title: (m['title'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
        snippet: m['content'] as String?,
        source: m['engine'] as String?,
        published:
            publishedRaw != null ? DateTime.tryParse(publishedRaw) : null,
        rank: entry.key + options.offset,
      );
    }).toList(growable: false);
  }
}
