/// TEST — Phase 3 skill additions (web_search / extract / crawl / monitor / download).
///
/// Mirrors `docs/04_TEST/12-skill-definitions.md` TC-1000·1001·1009·1010·1011·1012·1013·1016.
library;

import 'dart:io';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';
import '../_fakes/fake_http_fetcher.dart';

class _FakeSearchAdapter implements BrowserSearchPort {
  _FakeSearchAdapter({required this.id, required this.results});
  final String id;
  final List<BrowserSearchResult> results;

  @override
  BrowserSearchProviderDescriptor describe() =>
      BrowserSearchProviderDescriptor(
        id: id,
        name: id,
        supportedModes: const <BrowserSearchMode>{BrowserSearchMode.api},
      );

  @override
  Future<List<BrowserSearchResult>> search(
    String query,
    BrowserSearchOptions options,
  ) async =>
      results;
}

({BrowserRuntime runtime, BrowserOperations operations, Directory? baseDir})
    _build({
  FakeEngine? engine,
  FakeHttpFetcher? fetcher,
  bool enableSearch = false,
  bool enableCrawl = false,
  bool enableDownload = false,
  bool enableExtract = false,
}) {
  final engines = EngineRegistry()
    ..register(
      'fake',
      engine: engine ?? FakeEngine(),
      context: FakeContextPort(),
    );
  final policy = PolicyEngine.defaults();
  final contexts = ContextRegistry(engines: engines, policy: policy);
  final audit = AuditTrail(sink: InMemoryAuditSink());

  SearchRouter? search;
  if (enableSearch) {
    search = SearchRouter()
      ..register(
        'brave',
        _FakeSearchAdapter(
          id: 'brave',
          results: const <BrowserSearchResult>[
            BrowserSearchResult(title: 'r1', url: 'https://x.com/'),
          ],
        ),
      );
  }

  CrawlScheduler? crawler;
  if (enableCrawl) {
    crawler = CrawlScheduler(
      policy: policy,
      audit: audit,
      navigate: (String url, BrowserReadSpec spec) async =>
          BrowserPayloadEnvelope(mime: 'text/html', body: '<p>x</p>'),
    );
  }

  DownloadManager? downloads;
  Directory? baseDir;
  if (enableDownload) {
    baseDir = Directory.systemTemp.createTempSync('mcp_skill_dl_');
    downloads = DownloadManager(
      policy: policy,
      audit: audit,
      fetcher: fetcher ??
          FakeHttpFetcher(responses: <String, FakeHttpResponse>{
            'https://example.com/file.bin':
                const FakeHttpResponse(body: <int>[1, 2, 3]),
          }),
      baseDir: baseDir.path,
    );
  }

  ExtractionRegistry? extractions;
  if (enableExtract) {
    final regEngine = engine ??
        (FakeEngine()
          ..readImpl = (BrowserContextHandle h, BrowserReadSpec s) =>
              BrowserPayloadEnvelope(
                contextId: h.contextId,
                mime: 'text/html',
                body: '<h1>Hi</h1>',
              ));
    engines.unregister('fake');
    engines.register('fake',
        engine: regEngine, context: FakeContextPort());
    extractions = ExtractionRegistry();
  }

  final runtime = BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: policy,
    audit: audit,
    extractions: extractions,
    downloads: downloads,
    search: search,
    crawler: crawler,
  );
  return (
    runtime: runtime,
    operations: BrowserOperations(runtime: runtime, contexts: contexts),
    baseDir: baseDir,
  );
}

void main() {
  group('Op web_search (TC-1000/1001)', () {
    test('TC-1000 returns provider results', () async {
      final b = _build(enableSearch: true);
      await b.runtime.initialize();
      final out = await b.operations.get('web_search')!.handler(
        <String, dynamic>{'query': 'mcp', 'provider': 'brave'},
      );
      expect((out['results'] as List<dynamic>).single,
          containsPair('title', 'r1'));
      await b.runtime.shutdown();
    });

    test('TC-1001 missing provider falls through to policy error', () async {
      final b = _build(enableSearch: false);
      await b.runtime.initialize();
      expect(
        () => b.operations.get('web_search')!.handler(
            <String, dynamic>{'query': 'mcp', 'provider': 'brave'}),
        throwsA(isA<StateError>()),
      );
      await b.runtime.shutdown();
    });
  });

  group('Op extract (TC-1009/1010)', () {
    test('TC-1009 returns structured data from a registered template',
        () async {
      final b = _build(enableExtract: true);
      await b.runtime.initialize();
      await b.runtime.extractions!.register(const BrowserExtractionTemplate(
        id: 't1',
        version: '1.0.0',
        selectors: <String, BrowserSelectorRule>{
          'title': BrowserSelectorRule(selector: 'h1'),
        },
      ));
      final out = await b.operations.get('extract')!.handler(
        <String, dynamic>{
          'url': 'https://example.com/',
          'templateId': 't1',
        },
      );
      expect((out['data'] as Map<String, dynamic>)['title'], 'Hi');
      await b.runtime.shutdown();
    });

    test('TC-1010 unknown template id surfaces as StateError',
        () async {
      final b = _build(enableExtract: true);
      await b.runtime.initialize();
      expect(
        () => b.operations.get('extract')!.handler(<String, dynamic>{
          'url': 'https://example.com/',
          'templateId': 'missing',
        }),
        throwsA(isA<StateError>()),
      );
      await b.runtime.shutdown();
    });
  });

  group('Op crawl (TC-1011/1012)', () {
    test('TC-1011 returns a crawl id', () async {
      final b = _build(enableCrawl: true);
      await b.runtime.initialize();
      final out = await b.operations.get('crawl')!.handler(<String, dynamic>{
        'seeds': <String>['https://x.com/'],
        'policy': <String, dynamic>{
          'depth': 0,
          'respectRobots': false,
          'ratePerDomain': 0,
        },
      });
      expect(out['crawlId'], isA<String>());
      await b.runtime.shutdown();
    });

    test('TC-1012 invalid policy triggers StateError path', () async {
      final b = _build(enableCrawl: true);
      await b.runtime.initialize();
      expect(
        () => b.operations.get('crawl')!.handler(<String, dynamic>{
          'seeds': <String>['https://x.com/'],
          'policy': <String, dynamic>{'depth': -1, 'respectRobots': false},
        }),
        throwsA(isA<StateError>()),
      );
      await b.runtime.shutdown();
    });
  });

  group('Op monitor (TC-1013)', () {
    test('returns a monitor id', () async {
      final b = _build(enableCrawl: true);
      await b.runtime.initialize();
      final out = await b.operations.get('monitor')!.handler(<String, dynamic>{
        'url': 'https://x.com/',
        'interval_seconds': 1,
      });
      expect(out['monitorId'], isA<String>());
      await b.runtime.shutdown();
    });
  });

  group('Op download (TC-1016)', () {
    test('returns a download descriptor', () async {
      final b = _build(enableDownload: true);
      await b.runtime.initialize();
      try {
        final out = await b.operations.get('download')!.handler(<String, dynamic>{
          'url': 'https://example.com/file.bin',
          'tenantId': 't',
        });
        expect(out['downloadId'], isA<String>());
      } finally {
        if (b.baseDir?.existsSync() ?? false) {
          b.baseDir!.deleteSync(recursive: true);
        }
        await b.runtime.shutdown();
      }
    });
  });

  group('McpIntegration registers all 7 Phase 3 operations (TC-1017)', () {
    test('Phase 3 skill set is expanded', () async {
      final b = _build(
        enableSearch: true,
        enableCrawl: true,
      );
      final tools = <String>[];
      McpIntegration(runtime: b.runtime, operations: b.operations).registerWith(
        tool: (
          String name, {
          required String description,
          required bool readOnly,
          required bool destructive,
          required Future<Map<String, dynamic>> Function(Map<String, dynamic>)
              handler,
        }) =>
            tools.add(name),
        resource: (String uri, Future<dynamic> Function() reader) {},
      );
      expect(
        tools.toSet(),
        <String>{
          'page_view',
          'page_audit_role',
          'web_search',
          'extract',
          'crawl',
          'monitor',
          'download',
          'submit_form',
          'page_compare_actors',
        },
      );
    });
  });
}
