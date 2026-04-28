/// Built-in Kagi Search adapter.
library;

import '../../_internal.dart';

import '../../ops/http_fetcher.dart';
import '_common.dart';

class KagiSearchAdapter implements BrowserSearchPort {
  KagiSearchAdapter({required this.apiKey, required this.fetcher});

  final String apiKey;
  final HttpFetcher fetcher;

  @override
  BrowserSearchProviderDescriptor describe() {
    return const BrowserSearchProviderDescriptor(
      id: 'kagi',
      name: 'Kagi Search',
      supportedModes: <BrowserSearchMode>{BrowserSearchMode.api},
      supportedIntents: <BrowserSearchIntent>{BrowserSearchIntent.web},
      requiresKey: true,
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    final url = Uri.https('kagi.com', '/api/v0/search', <String, String>{
      'q': query,
      'limit': options.limit.clamp(1, 100).toString(),
    }).toString();
    final response = await fetcher.fetch(url, headers: <String, String>{
      'Authorization': 'Bot $apiKey',
    });
    final json = await decodeJsonResponse(response, providerId: 'kagi');
    final data = (json['data'] as List<dynamic>?) ?? const <dynamic>[];
    // Kagi returns mixed result types (`t=0` = search result, `t=1` = related).
    final hits = data
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> m) => m['t'] == 0)
        .toList();
    return hits.asMap().entries.map<BrowserSearchResult>(
        (MapEntry<int, dynamic> entry) {
      final m = Map<String, dynamic>.from(entry.value as Map);
      final published = m['published'] as String?;
      return BrowserSearchResult(
        title: (m['title'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
        snippet: m['snippet'] as String?,
        source: Uri.tryParse((m['url'] as String?) ?? '')?.host,
        published:
            published != null ? DateTime.tryParse(published) : null,
        rank: entry.key + options.offset,
      );
    }).toList(growable: false);
  }
}
