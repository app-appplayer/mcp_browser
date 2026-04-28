/// Built-in DuckDuckGo adapter — browser-mode SERP scraping.
///
/// DuckDuckGo's public API only returns Instant Answers, not general web
/// results. To get web results this adapter navigates to the HTML SERP at
/// `https://html.duckduckgo.com/html/?q=...` and parses the result rows.
library;

import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import '../../_internal.dart';

import '../../ops/http_fetcher.dart';
import '../../registry/search_router.dart';
import '_common.dart';

class DuckDuckGoSearchAdapter implements BrowserSearchPort {
  DuckDuckGoSearchAdapter({required this.fetcher});

  final HttpFetcher fetcher;

  @override
  BrowserSearchProviderDescriptor describe() {
    return const BrowserSearchProviderDescriptor(
      id: 'ddg',
      name: 'DuckDuckGo HTML SERP',
      supportedModes: <BrowserSearchMode>{BrowserSearchMode.browser},
      supportedIntents: <BrowserSearchIntent>{BrowserSearchIntent.web},
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    final url = 'https://html.duckduckgo.com/html/?q='
        '${Uri.encodeQueryComponent(query)}';
    final response = await fetcher.fetch(url, headers: <String, String>{
      'User-Agent':
          'Mozilla/5.0 (compatible; mcp_browser/0.1; +https://github.com/makemind/mcp_browser)',
      'Accept': 'text/html',
      if (options.language != null) 'Accept-Language': options.language!,
    });
    if (response.statusCode == 429) {
      throw SearchProviderRateLimitException('ddg returned 429');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SearchSerpParseError('ddg',
          'HTTP ${response.statusCode} from DDG HTML endpoint');
    }
    final body = await drainResponseText(response);
    final doc = html_parser.parse(body);
    final results = <BrowserSearchResult>[];
    final rows = doc.querySelectorAll('div.result');
    for (final row in rows.take(options.limit)) {
      final anchor = row.querySelector('a.result__a');
      if (anchor == null) continue;
      final rawHref = anchor.attributes['href'];
      if (rawHref == null) continue;
      final resolved = _resolveDdgRedirect(rawHref);
      final snippet = row.querySelector('a.result__snippet')?.text ??
          row.querySelector('.result__snippet')?.text;
      results.add(BrowserSearchResult(
        title: anchor.text.trim(),
        url: resolved,
        snippet: snippet?.trim(),
        source: Uri.tryParse(resolved)?.host,
        rank: results.length + options.offset,
      ));
    }
    if (results.isEmpty) {
      throw SearchSerpParseError(
          'ddg', 'no "div.result a.result__a" rows on SERP');
    }
    return results;
  }

  /// DDG wraps result URLs in `/l/?uddg=<encoded>` redirectors. Decode to
  /// the real target when present; otherwise return the href as-is.
  String _resolveDdgRedirect(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null) return href;
    final uddg = uri.queryParameters['uddg'];
    if (uddg != null && uddg.isNotEmpty) {
      return Uri.decodeComponent(uddg);
    }
    // Relative href (`/l/?...`) needs the ddg origin.
    if (href.startsWith('/')) {
      return Uri.parse('https://html.duckduckgo.com').resolve(href).toString();
    }
    return href;
  }
}

/// Tiny helper so the file doesn't need `dart:convert` import noise for
/// single-use base64 work. Exposed for tests.
String ddgDecode(String value) => utf8.decode(base64Decode(value));
