/// TEST — built-in search adapters (Google/Brave/Bing/Kagi/SearXNG/DDG).
library;

import 'dart:convert';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_http_fetcher.dart';

FakeHttpResponse _json(Map<String, dynamic> body, {int status = 200}) =>
    FakeHttpResponse(
      statusCode: status,
      body: utf8.encode(jsonEncode(body)),
      headers: const <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('GoogleCseSearchAdapter', () {
    test('parses items into BrowserSearchResult list', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://www.googleapis.com/customsearch/v1?q=mcp&cx=CX&key=KEY&num=5&start=1'] =
          _json(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'MCP Explained',
            'link': 'https://x.com/mcp',
            'snippet': 'A protocol for...',
            'displayLink': 'x.com',
          },
        ],
      });
      final adapter = GoogleCseSearchAdapter(
        apiKey: 'KEY',
        cx: 'CX',
        fetcher: fetcher,
      );
      final results = await adapter.search(
        'mcp',
        const BrowserSearchOptions(limit: 5),
      );
      expect(results.single.title, 'MCP Explained');
      expect(results.single.url, 'https://x.com/mcp');
      expect(results.single.source, 'x.com');
    });

    test('429 surfaces as SearchProviderRateLimitException', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://www.googleapis.com/customsearch/v1?q=x&cx=CX&key=KEY&num=10&start=1'] =
          _json(<String, dynamic>{}, status: 429);
      final adapter = GoogleCseSearchAdapter(
        apiKey: 'KEY',
        cx: 'CX',
        fetcher: fetcher,
      );
      await expectLater(
        adapter.search('x', const BrowserSearchOptions()),
        throwsA(isA<SearchProviderRateLimitException>()),
      );
    });
  });

  group('BraveSearchAdapter', () {
    test('parses web.results', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://api.search.brave.com/res/v1/web/search?q=mcp&count=10&offset=0'] =
          _json(<String, dynamic>{
        'web': <String, dynamic>{
          'results': <Map<String, dynamic>>[
            <String, dynamic>{
              'title': 'Brave result',
              'url': 'https://a.com',
              'description': 'desc',
              'netloc': 'a.com',
            },
          ],
        },
      });
      final adapter = BraveSearchAdapter(apiKey: 'K', fetcher: fetcher);
      final results =
          await adapter.search('mcp', const BrowserSearchOptions());
      expect(results.single.title, 'Brave result');
      expect(results.single.snippet, 'desc');
      expect(results.single.source, 'a.com');
    });
  });

  group('BingSearchAdapter', () {
    test('parses webPages.value', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://api.bing.microsoft.com/v7.0/search?q=mcp&count=10&offset=0'] =
          _json(<String, dynamic>{
        'webPages': <String, dynamic>{
          'value': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'Bing result',
              'url': 'https://b.com',
              'snippet': 'bing desc',
              'displayUrl': 'b.com',
            },
          ],
        },
      });
      final adapter = BingSearchAdapter(apiKey: 'K', fetcher: fetcher);
      final results =
          await adapter.search('mcp', const BrowserSearchOptions());
      expect(results.single.title, 'Bing result');
      expect(results.single.source, 'b.com');
    });
  });

  group('KagiSearchAdapter', () {
    test('filters to t=0 results and extracts fields', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://kagi.com/api/v0/search?q=mcp&limit=10'] =
          _json(<String, dynamic>{
        'data': <Map<String, dynamic>>[
          <String, dynamic>{
            't': 0,
            'title': 'Kagi result',
            'url': 'https://c.com/path',
            'snippet': 'kagi desc',
          },
          <String, dynamic>{
            't': 1,
            'related': <String>['mcp alt'],
          },
        ],
      });
      final adapter = KagiSearchAdapter(apiKey: 'K', fetcher: fetcher);
      final results =
          await adapter.search('mcp', const BrowserSearchOptions());
      expect(results.single.title, 'Kagi result');
      expect(results.single.source, 'c.com');
    });
  });

  group('SearxngSearchAdapter', () {
    test('limits to options.limit and maps fields', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://searx.example.com/search?q=mcp&format=json&categories=general&pageno=1'] =
          _json(<String, dynamic>{
        'results': <Map<String, dynamic>>[
          <String, dynamic>{
            'title': 'S1',
            'url': 'https://s1',
            'content': 'c1',
            'engine': 'google',
          },
          <String, dynamic>{
            'title': 'S2',
            'url': 'https://s2',
            'content': 'c2',
            'engine': 'bing',
          },
          <String, dynamic>{
            'title': 'S3',
            'url': 'https://s3',
            'content': 'c3',
            'engine': 'ddg',
          },
        ],
      });
      final adapter = SearxngSearchAdapter(
        baseUrl: 'https://searx.example.com',
        fetcher: fetcher,
      );
      final results = await adapter.search(
        'mcp',
        const BrowserSearchOptions(limit: 2),
      );
      expect(results, hasLength(2));
      expect(results.first.source, 'google');
    });
  });

  group('DuckDuckGoSearchAdapter', () {
    test('parses HTML SERP rows', () async {
      const html = '''
<html><body>
  <div class="result">
    <a class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fa">Title A</a>
    <a class="result__snippet">snippet A</a>
  </div>
  <div class="result">
    <a class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fb">Title B</a>
    <a class="result__snippet">snippet B</a>
  </div>
</body></html>
''';
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://html.duckduckgo.com/html/?q=mcp'] =
          FakeHttpResponse(
        body: utf8.encode(html),
        headers: const <String, String>{'content-type': 'text/html'},
      );
      final adapter = DuckDuckGoSearchAdapter(fetcher: fetcher);
      final results =
          await adapter.search('mcp', const BrowserSearchOptions(limit: 5));
      expect(results, hasLength(2));
      expect(results.first.url, 'https://example.com/a');
      expect(results.first.title, 'Title A');
    });

    test('empty SERP surfaces as SearchSerpParseError', () async {
      final fetcher = FakeHttpFetcher();
      fetcher.responses['https://html.duckduckgo.com/html/?q=empty'] =
          FakeHttpResponse(
        body: utf8.encode('<html><body>no results</body></html>'),
        headers: const <String, String>{'content-type': 'text/html'},
      );
      final adapter = DuckDuckGoSearchAdapter(fetcher: fetcher);
      await expectLater(
        adapter.search('empty', const BrowserSearchOptions()),
        throwsA(isA<SearchSerpParseError>()),
      );
    });
  });
}
