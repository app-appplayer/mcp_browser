/// TEST — MOD-REG-005 SearchRouter + SearchCache.
///
/// Mirrors `docs/04_TEST/08-search.md` (TC-600~617).
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

class _FakeSearchAdapter implements BrowserSearchPort {

  _FakeSearchAdapter({
    required this.id,
    this.modes = const <BrowserSearchMode>{BrowserSearchMode.api},
    required this.impl,
  });
  final String id;
  final Set<BrowserSearchMode> modes;
  final List<BrowserSearchResult> Function(
      String query, BrowserSearchOptions opts) impl;
  int calls = 0;

  @override
  BrowserSearchProviderDescriptor describe() {
    return BrowserSearchProviderDescriptor(
      id: id,
      name: id.toUpperCase(),
      supportedModes: modes,
      requiresKey: modes.contains(BrowserSearchMode.api),
    );
  }

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async {
    calls++;
    return impl(query, options);
  }
}

class _RateLimitedAdapter extends _FakeSearchAdapter {
  _RateLimitedAdapter({super.id = 'rl'})
      : super(
          impl: (String query, BrowserSearchOptions opts) =>
              throw SearchProviderRateLimitException('429'),
        );
}

class _SerpFailAdapter extends _FakeSearchAdapter {
  _SerpFailAdapter({super.id = 'serp'})
      : super(
          modes: const <BrowserSearchMode>{BrowserSearchMode.browser},
          impl: (String query, BrowserSearchOptions opts) =>
              throw SearchSerpParseError(id, 'DOM changed'),
        );
}

void main() {
  group('SearchRouter — registration', () {
    test('TC-600 register makes provider resolvable', () {
      final router = SearchRouter()
        ..register(
          'brave',
          _FakeSearchAdapter(
            id: 'brave',
            impl: (String _, BrowserSearchOptions __) =>
                <BrowserSearchResult>[],
          ),
        );
      expect(router.providers().single.id, 'brave');
    });

    test('TC-601 unregister removes the provider', () {
      final router = SearchRouter()
        ..register(
          'brave',
          _FakeSearchAdapter(
            id: 'brave',
            impl: (String _, BrowserSearchOptions __) =>
                <BrowserSearchResult>[],
          ),
        )
        ..unregister('brave');
      expect(router.providers(), isEmpty);
    });

    test('TC-602 providers lists all descriptors', () {
      final router = SearchRouter()
        ..register('brave',
            _FakeSearchAdapter(id: 'brave', impl: _emptyImpl))
        ..register('ddg',
            _FakeSearchAdapter(id: 'ddg', modes: const <BrowserSearchMode>{
              BrowserSearchMode.browser,
            }, impl: _emptyImpl));
      expect(router.providers().map((BrowserSearchProviderDescriptor d) => d.id)
          .toSet(), <String>{'brave', 'ddg'});
    });
  });

  group('SearchRouter — search', () {
    test('TC-603 search api mode returns results', () async {
      final adapter = _FakeSearchAdapter(
        id: 'brave',
        impl: (String q, BrowserSearchOptions o) => <BrowserSearchResult>[
          const BrowserSearchResult(title: 't', url: 'https://x.com'),
        ],
      );
      final router = SearchRouter()..register('brave', adapter);
      final results = await router.search('mcp', providerId: 'brave');
      expect(results.single.title, 't');
    });

    test('TC-604 search browser mode delegates without forcing api',
        () async {
      final adapter = _FakeSearchAdapter(
        id: 'ddg',
        modes: const <BrowserSearchMode>{BrowserSearchMode.browser},
        impl: (String q, BrowserSearchOptions o) => <BrowserSearchResult>[
          const BrowserSearchResult(title: 'serp', url: 'https://y.com'),
        ],
      );
      final router = SearchRouter()..register('ddg', adapter);
      final results = await router.search(
        'mcp',
        providerId: 'ddg',
        options: const BrowserSearchOptions(mode: BrowserSearchMode.browser),
      );
      expect(results.single.title, 'serp');
    });

    test('TC-605 unknown provider throws E6001', () async {
      final router = SearchRouter();
      await expectLater(
        router.search('q', providerId: 'missing'),
        throwsA(isA<SearchProviderNotRegisteredError>()),
      );
    });

    test('TC-606 unsupported mode throws E6001', () async {
      final adapter = _FakeSearchAdapter(
        id: 'brave',
        impl: _emptyImpl,
      );
      final router = SearchRouter()..register('brave', adapter);
      await expectLater(
        router.search(
          'q',
          providerId: 'brave',
          options:
              const BrowserSearchOptions(mode: BrowserSearchMode.browser),
        ),
        throwsA(isA<SearchProviderNotRegisteredError>()),
      );
    });

    test('TC-607 second identical query hits the cache', () async {
      final adapter = _FakeSearchAdapter(
        id: 'brave',
        impl: (String q, BrowserSearchOptions o) => <BrowserSearchResult>[
          const BrowserSearchResult(title: 't', url: 'u'),
        ],
      );
      final router = SearchRouter()..register('brave', adapter);
      await router.search('q', providerId: 'brave');
      await router.search('q', providerId: 'brave');
      expect(adapter.calls, 1);
    });

    test('TC-608 cacheTtl=0 disables caching', () async {
      final adapter = _FakeSearchAdapter(
        id: 'brave',
        impl: (String q, BrowserSearchOptions o) => <BrowserSearchResult>[
          const BrowserSearchResult(title: 't', url: 'u'),
        ],
      );
      final router = SearchRouter()..register('brave', adapter);
      const opts = BrowserSearchOptions(cacheTtl: Duration.zero);
      await router.search('q', providerId: 'brave', options: opts);
      await router.search('q', providerId: 'brave', options: opts);
      expect(adapter.calls, 2);
    });

    test('TC-609 rate-limit adapter exception maps to E6002', () async {
      final adapter = _RateLimitedAdapter();
      final router = SearchRouter()..register('rl', adapter);
      await expectLater(
        router.search('q', providerId: 'rl'),
        throwsA(isA<SearchRateLimitedError>()),
      );
    });

    test('TC-610 SERP parse failure maps to E6003', () async {
      final adapter = _SerpFailAdapter();
      final router = SearchRouter()..register('serp', adapter);
      await expectLater(
        router.search(
          'q',
          providerId: 'serp',
          options: const BrowserSearchOptions(mode: BrowserSearchMode.browser),
        ),
        throwsA(isA<SearchSerpParseError>()),
      );
    });

    test('TC-611/612/613 options propagate to the adapter', () async {
      late BrowserSearchOptions captured;
      final adapter = _FakeSearchAdapter(
        id: 'brave',
        impl: (String q, BrowserSearchOptions o) {
          captured = o;
          return <BrowserSearchResult>[];
        },
      );
      final router = SearchRouter()..register('brave', adapter);
      await router.search(
        'q',
        providerId: 'brave',
        options: const BrowserSearchOptions(
          limit: 30,
          offset: 10,
          intent: BrowserSearchIntent.news,
          language: 'ko',
          region: 'KR',
        ),
      );
      expect(captured.limit, 30);
      expect(captured.offset, 10);
      expect(captured.intent, BrowserSearchIntent.news);
      expect(captured.language, 'ko');
      expect(captured.region, 'KR');
    });
  });

  group('SearchCache', () {
    test('TC-614 keyOf is stable for identical inputs', () {
      final cache = SearchCache();
      const opts = BrowserSearchOptions();
      expect(
        cache.keyOf('brave', 'mcp', opts),
        cache.keyOf('brave', 'mcp', opts),
      );
    });

    test('TC-615 keyOf differs when limit changes', () {
      final cache = SearchCache();
      expect(
        cache.keyOf('brave', 'mcp', const BrowserSearchOptions(limit: 10)),
        isNot(cache.keyOf(
            'brave', 'mcp', const BrowserSearchOptions(limit: 25))),
      );
    });

    test('TC-616/617 TTL eviction', () async {
      var fakeNow = DateTime.utc(2026, 1, 1);
      final cache = SearchCache(now: () => fakeNow);
      const key = 'k';
      await cache.put(key, const <BrowserSearchResult>[
        BrowserSearchResult(title: 'x', url: 'y'),
      ]);
      expect(await cache.get(key, const Duration(hours: 1)), isNotNull);
      fakeNow = fakeNow.add(const Duration(hours: 2));
      expect(await cache.get(key, const Duration(hours: 1)), isNull);
    });
  });
}

List<BrowserSearchResult> _emptyImpl(
        String query, BrowserSearchOptions options) =>
    const <BrowserSearchResult>[];
