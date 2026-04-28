/// TEST — MOD-REG-004 ExtractionRegistry.
///
/// Mirrors `docs/04_TEST/07-extraction.md` (TC-500~524).
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

BrowserExtractionTemplate _tpl({
  String id = 'news_card_v1',
  String version = '1.0.0',
  Map<String, BrowserSelectorRule>? selectors,
  List<BrowserTransformStep>? transforms,
  BrowserOutputSchema schema = const BrowserOutputSchema(),
}) {
  return BrowserExtractionTemplate(
    id: id,
    version: version,
    selectors: selectors ??
        const <String, BrowserSelectorRule>{
          'title': BrowserSelectorRule(selector: 'h1'),
          'url':
              BrowserSelectorRule(selector: 'a.headline', extract: 'attr:href'),
        },
    transforms: transforms ?? const <BrowserTransformStep>[],
    outputSchema: schema,
  );
}

void main() {
  group('ExtractionRegistry — CRUD', () {
    test('TC-500 register persists and is listable', () async {
      final kv = InMemoryKvStoragePort();
      final reg = ExtractionRegistry(storage: kv);
      await reg.register(_tpl());
      expect(await kv.exists('mcp_browser/extraction/news_card_v1/1.0.0'),
          isTrue);
      final metas = await reg.list();
      expect(metas, hasLength(1));
      expect(metas.single.id, 'news_card_v1');
    });

    test('TC-501 register with empty id throws', () async {
      final reg = ExtractionRegistry();
      expect(
        () => reg.register(_tpl(id: '')),
        throwsA(isA<ExtractionTemplateInvalidError>()),
      );
    });

    test('TC-502 register with empty version throws', () async {
      final reg = ExtractionRegistry();
      expect(
        () => reg.register(_tpl(version: '')),
        throwsA(isA<ExtractionTemplateInvalidError>()),
      );
    });

    test('TC-503 get latest returns highest semver', () async {
      final reg = ExtractionRegistry();
      await reg.register(_tpl(version: '1.0.0'));
      await reg.register(_tpl(version: '1.1.0'));
      await reg.register(_tpl(version: '1.0.9'));
      final latest = await reg.get('news_card_v1');
      expect(latest!.version, '1.1.0');
    });

    test('TC-504 get specific version returns that version', () async {
      final reg = ExtractionRegistry();
      await reg.register(_tpl(version: '1.0.0'));
      await reg.register(_tpl(version: '1.1.0'));
      final pinned = await reg.get('news_card_v1', version: '1.0.0');
      expect(pinned!.version, '1.0.0');
    });

    test('TC-505 get unknown id returns null', () async {
      final reg = ExtractionRegistry();
      expect(await reg.get('missing'), isNull);
    });

    test('TC-507 remove drops the entry', () async {
      final kv = InMemoryKvStoragePort();
      final reg = ExtractionRegistry(storage: kv);
      await reg.register(_tpl());
      await reg.remove('news_card_v1', '1.0.0');
      expect(await reg.get('news_card_v1'), isNull);
      expect(
        await kv.exists('mcp_browser/extraction/news_card_v1/1.0.0'),
        isFalse,
      );
    });
  });

  group('ExtractionRegistry — evaluate', () {
    test('TC-508 evaluate text selector', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(selectors: const <String, BrowserSelectorRule>{
          'title': BrowserSelectorRule(selector: 'h1'),
        }),
        html: '<html><body><h1>Hello</h1></body></html>',
      );
      expect(out['title'], 'Hello');
    });

    test('TC-509 evaluate attr selector', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(selectors: const <String, BrowserSelectorRule>{
          'url':
              BrowserSelectorRule(selector: 'a', extract: 'attr:href'),
        }),
        html: '<html><body><a href="/path">Link</a></body></html>',
      );
      expect(out['url'], '/path');
    });

    test('TC-510 evaluate many=true returns a list', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(selectors: const <String, BrowserSelectorRule>{
          'items': BrowserSelectorRule(selector: 'li', many: true),
        }),
        html: '<ul><li>a</li><li>b</li><li>c</li></ul>',
      );
      expect(out['items'], <String>['a', 'b', 'c']);
    });

    test('TC-511 xpath mode throws UnsupportedError (documented)', () async {
      final reg = ExtractionRegistry();
      expect(
        () => reg.evaluate(
          _tpl(selectors: const <String, BrowserSelectorRule>{
            'node': BrowserSelectorRule(
              selector: '//div',
              mode: BrowserSelectorMode.xpath,
            ),
          }),
          html: '<div>x</div>',
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('TC-513 per-rule transform chain applies in order (trim)', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(selectors: const <String, BrowserSelectorRule>{
          'title': BrowserSelectorRule(
            selector: 'h1',
            transforms: <String>['trim'],
          ),
        }),
        html: '<h1>  Hello  </h1>',
      );
      expect(out['title'], 'Hello');
    });

    test('TC-514 post-transform toInt', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(
          selectors: const <String, BrowserSelectorRule>{
            'views': BrowserSelectorRule(selector: 'span.views'),
          },
          transforms: const <BrowserTransformStep>[
            BrowserTransformStep(field: 'views', op: 'toInt'),
          ],
        ),
        html: '<span class="views">42</span>',
      );
      expect(out['views'], 42);
    });

    test('TC-515 urlAbsolutize uses pageUrl', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(
          selectors: const <String, BrowserSelectorRule>{
            'url': BrowserSelectorRule(
              selector: 'a',
              extract: 'attr:href',
              transforms: <String>['urlAbsolutize'],
            ),
          },
        ),
        html: '<a href="/path">Link</a>',
        pageUrl: 'https://example.com/base/',
      );
      expect(out['url'], 'https://example.com/path');
    });

    test('TC-517 selector miss yields null', () async {
      final reg = ExtractionRegistry();
      final out = await reg.evaluate(
        _tpl(selectors: const <String, BrowserSelectorRule>{
          'title': BrowserSelectorRule(selector: 'h1'),
        }),
        html: '<body><p>no title</p></body>',
      );
      expect(out['title'], isNull);
    });

    test('TC-519/520 outputSchema enforces required fields', () async {
      final reg = ExtractionRegistry();
      final template = _tpl(
        selectors: const <String, BrowserSelectorRule>{
          'title': BrowserSelectorRule(selector: 'h1'),
          'url':
              BrowserSelectorRule(selector: 'a', extract: 'attr:href'),
        },
        schema: const BrowserOutputSchema(required: <String>['title', 'url']),
      );
      final okOut = await reg.evaluate(template,
          html: '<h1>t</h1><a href="/">x</a>');
      expect(okOut['title'], 't');

      try {
        await reg.evaluate(template, html: '<a href="/">x</a>');
        fail('expected BrowserExtractionSchemaError');
      } on BrowserExtractionSchemaError catch (e) {
        expect(e.missingFields, contains('title'));
        expect(e.partial['url'], '/');
      }
    });
  });

  group('BrowserRuntime — read(extract) routing', () {
    test('forwards extracted html to ExtractionRegistry', () async {
      final engine = FakeEngine()
        ..readImpl = (BrowserContextHandle h, BrowserReadSpec spec) =>
            BrowserPayloadEnvelope(
              contextId: h.contextId,
              mime: 'text/html',
              body: '<h1>Hi</h1>',
              meta: <String, dynamic>{'pageUrl': 'https://x.com/page'},
            );
      final engines = EngineRegistry()
        ..register('fake', engine: engine, context: FakeContextPort());
      final policy = PolicyEngine.defaults();
      final contexts = ContextRegistry(engines: engines, policy: policy);
      final reg = ExtractionRegistry();
      await reg.register(_tpl(selectors: const <String, BrowserSelectorRule>{
        'title': BrowserSelectorRule(selector: 'h1'),
      }));
      final rt = BrowserRuntime(
        engines: engines,
        contexts: contexts,
        policy: policy,
        audit: AuditTrail(sink: InMemoryAuditSink()),
        extractions: reg,
      );
      await rt.initialize();
      final handle = await contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      final env = await rt.read(
        handle.contextId,
        BrowserReadSpec.extract(templateId: 'news_card_v1'),
      );
      expect(env.mime, 'application/json');
      expect((env.body as Map<String, dynamic>)['title'], 'Hi');
      await rt.shutdown();
    });
  });
}
