/// Built-in Bing Web Search (Microsoft) adapter.
library;

import '../../_internal.dart';

import '../../ops/http_fetcher.dart';
import '_common.dart';

class BingSearchAdapter implements BrowserSearchPort {
  BingSearchAdapter({required this.apiKey, required this.fetcher});

  final String apiKey;
  final HttpFetcher fetcher;

  @override
  BrowserSearchProviderDescriptor describe() {
    return const BrowserSearchProviderDescriptor(
      id: 'bing',
      name: 'Bing Web Search',
      supportedModes: <BrowserSearchMode>{BrowserSearchMode.api},
      supportedIntents: <BrowserSearchIntent>{
        BrowserSearchIntent.web,
        BrowserSearchIntent.news,
        BrowserSearchIntent.images,
        BrowserSearchIntent.videos,
      },
      requiresKey: true,
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    final endpoint = switch (options.intent) {
      BrowserSearchIntent.news => '/v7.0/news/search',
      BrowserSearchIntent.images => '/v7.0/images/search',
      BrowserSearchIntent.videos => '/v7.0/videos/search',
      _ => '/v7.0/search',
    };
    final url =
        Uri.https('api.bing.microsoft.com', endpoint, <String, String>{
      'q': query,
      'count': options.limit.clamp(1, 50).toString(),
      'offset': options.offset.toString(),
      if (options.language != null) 'setLang': options.language!,
      if (options.region != null) 'mkt': options.region!,
    }).toString();
    final response = await fetcher.fetch(url, headers: <String, String>{
      'Ocp-Apim-Subscription-Key': apiKey,
    });
    final json = await decodeJsonResponse(response, providerId: 'bing');
    final results = switch (options.intent) {
          BrowserSearchIntent.news =>
            (json['value'] as List<dynamic>?) ?? const <dynamic>[],
          BrowserSearchIntent.images =>
            (json['value'] as List<dynamic>?) ?? const <dynamic>[],
          BrowserSearchIntent.videos =>
            (json['value'] as List<dynamic>?) ?? const <dynamic>[],
          _ => ((json['webPages'] as Map?)?['value'] as List<dynamic>?) ??
              const <dynamic>[],
        };
    return results.asMap().entries.map<BrowserSearchResult>(
        (MapEntry<int, dynamic> entry) {
      final m = Map<String, dynamic>.from(entry.value as Map);
      final published =
          m['datePublished'] as String? ?? m['dateLastCrawled'] as String?;
      return BrowserSearchResult(
        title: (m['name'] as String?) ?? '',
        url: (m['url'] as String?) ?? (m['webSearchUrl'] as String?) ?? '',
        snippet:
            (m['snippet'] as String?) ?? (m['description'] as String?),
        source: (m['displayUrl'] as String?) ??
            (m['provider'] is List
                ? ((m['provider'] as List).isEmpty
                    ? null
                    : ((m['provider'] as List).first as Map)['name']
                        as String?)
                : null),
        published:
            published != null ? DateTime.tryParse(published) : null,
        rank: entry.key + options.offset,
      );
    }).toList(growable: false);
  }
}
