/// Built-in Brave Search adapter.
///
/// Calls `https://api.search.brave.com/res/v1/web/search` with an
/// `X-Subscription-Token` header.
library;

import '../../_internal.dart';

import '../../ops/http_fetcher.dart';
import '_common.dart';

class BraveSearchAdapter implements BrowserSearchPort {
  BraveSearchAdapter({required this.apiKey, required this.fetcher});

  final String apiKey;
  final HttpFetcher fetcher;

  @override
  BrowserSearchProviderDescriptor describe() {
    return const BrowserSearchProviderDescriptor(
      id: 'brave',
      name: 'Brave Search',
      supportedModes: <BrowserSearchMode>{BrowserSearchMode.api},
      supportedIntents: <BrowserSearchIntent>{
        BrowserSearchIntent.web,
        BrowserSearchIntent.news,
      },
      requiresKey: true,
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    final path = options.intent == BrowserSearchIntent.news
        ? '/res/v1/news/search'
        : '/res/v1/web/search';
    final url = Uri.https('api.search.brave.com', path, <String, String>{
      'q': query,
      'count': options.limit.clamp(1, 20).toString(),
      'offset': options.offset.toString(),
      if (options.language != null) 'search_lang': options.language!,
      if (options.region != null) 'country': options.region!,
    }).toString();
    final response = await fetcher.fetch(url, headers: <String, String>{
      'Accept': 'application/json',
      'X-Subscription-Token': apiKey,
    });
    final json = await decodeJsonResponse(response, providerId: 'brave');
    final results =
        (((json['web'] as Map?)?['results'] ?? json['results']) as List<dynamic>?)
                ?.cast<dynamic>() ??
            const <dynamic>[];
    return results.asMap().entries.map<BrowserSearchResult>(
        (MapEntry<int, dynamic> entry) {
      final m = Map<String, dynamic>.from(entry.value as Map);
      final published = m['page_age'] as String? ?? m['age'] as String?;
      return BrowserSearchResult(
        title: (m['title'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
        snippet:
            (m['description'] as String?) ?? (m['snippet'] as String?),
        source: (m['profile'] is Map
                ? (m['profile'] as Map)['name'] as String?
                : null) ??
            (m['netloc'] as String?),
        published:
            published != null ? DateTime.tryParse(published) : null,
        rank: entry.key + options.offset,
      );
    }).toList(growable: false);
  }
}
