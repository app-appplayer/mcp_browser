/// Built-in Google Custom Search (CSE) adapter.
///
/// Calls the Google Custom Search JSON API. Requires `apiKey` + `cx`
/// (search engine id) from a Google Cloud project.
library;

import '../../_internal.dart';

import '../../ops/http_fetcher.dart';
import '_common.dart';

class GoogleCseSearchAdapter implements BrowserSearchPort {
  GoogleCseSearchAdapter({
    required this.apiKey,
    required this.cx,
    required this.fetcher,
  });

  final String apiKey;
  final String cx;
  final HttpFetcher fetcher;

  @override
  BrowserSearchProviderDescriptor describe() {
    return const BrowserSearchProviderDescriptor(
      id: 'google',
      name: 'Google Custom Search',
      supportedModes: <BrowserSearchMode>{BrowserSearchMode.api},
      supportedIntents: <BrowserSearchIntent>{
        BrowserSearchIntent.web,
        BrowserSearchIntent.images,
      },
      requiresKey: true,
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    final url = Uri.https('www.googleapis.com', '/customsearch/v1', <String, String>{
      'q': query,
      'cx': cx,
      'key': apiKey,
      'num': options.limit.clamp(1, 10).toString(),
      'start': (options.offset + 1).toString(),
      if (options.intent == BrowserSearchIntent.images) 'searchType': 'image',
      if (options.language != null) 'lr': 'lang_${options.language}',
      if (options.region != null) 'gl': options.region!,
    }).toString();
    final response = await fetcher.fetch(url);
    final json = await decodeJsonResponse(response, providerId: 'google');
    final items = (json['items'] as List<dynamic>?) ?? const <dynamic>[];
    return items
        .asMap()
        .entries
        .map<BrowserSearchResult>((MapEntry<int, dynamic> entry) {
      final m = Map<String, dynamic>.from(entry.value as Map);
      return BrowserSearchResult(
        title: (m['title'] as String?) ?? '',
        url: (m['link'] as String?) ?? '',
        snippet: m['snippet'] as String?,
        source: m['displayLink'] as String?,
        rank: entry.key + options.offset,
      );
    }).toList(growable: false);
  }
}
