/// TEST — Phase 4 skill additions (submit_form, page_compare_actors).
///
/// Mirrors `docs/04_TEST/12-skill-definitions.md` TC-1014·1015 (submit_form)
/// and TC-1008 (page_compare_actors).
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

({
  BrowserRuntime runtime,
  BrowserOperations operations,
  FakeEngine engine,
}) _build({
  List<BrowserActionKind> executeFailuresOn = const <BrowserActionKind>[],
}) {
  final engine = FakeEngine(
    capabilities: const <EngineCapability>{
      EngineCapability.headless,
      EngineCapability.executeNavigate,
      EngineCapability.executeClick,
      EngineCapability.executeType,
      EngineCapability.executeFill,
      EngineCapability.readDom,
    },
  );
  engine.readImpl = (BrowserContextHandle h, BrowserReadSpec s) =>
      BrowserPayloadEnvelope(
        contextId: h.contextId,
        mime: 'text/plain',
        body: 'view:${s.kind.name}:${h.spec.actorId ?? 'anon'}',
      );
  engine.executeImpl = (BrowserContextHandle h, BrowserAction action) {
    if (executeFailuresOn.contains(action.kind)) {
      return const BrowserActionResult(
        success: false,
        errorCode: 'E3001',
        errorMessage: 'selector missing',
      );
    }
    return const BrowserActionResult(success: true);
  };
  final engines = EngineRegistry()
    ..register('fake', engine: engine, context: FakeContextPort());
  final policy = PolicyEngine.defaults();
  final contexts = ContextRegistry(engines: engines, policy: policy);
  final audit = AuditTrail(sink: InMemoryAuditSink());
  final kv = InMemoryKvStoragePort();
  final authStore =
      AuthProfileStore(kv: kv, crypto: SecretBox.fromPassphrase('k'));
  final runtime = BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: policy,
    audit: audit,
    authStore: authStore,
  );
  return (
    runtime: runtime,
    operations: BrowserOperations(runtime: runtime, contexts: contexts),
    engine: engine,
  );
}

void main() {
  group('Op submit_form (TC-1014/1015)', () {
    test('TC-1014 all steps succeed, returns success=true', () async {
      final b = _build();
      await b.runtime.initialize();
      final out = await b.operations.get('submit_form')!.handler(
        <String, dynamic>{
          'url': 'https://portal.example/report/new',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'action': 'fill',
              'selector': '#title',
              'value': 'Weekly Report',
            },
            <String, dynamic>{'action': 'click', 'selector': '#submit'},
            <String, dynamic>{'action': 'wait', 'ms': 1},
          ],
        },
      );
      expect(out['success'], isTrue);
      expect(out.containsKey('errors'), isFalse);
      await b.runtime.shutdown();
    });

    test('TC-1015 failing step records error and success=false',
        () async {
      final b = _build(
        executeFailuresOn: <BrowserActionKind>[BrowserActionKind.click],
      );
      await b.runtime.initialize();
      final out = await b.operations.get('submit_form')!.handler(
        <String, dynamic>{
          'url': 'https://portal.example/new',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{'action': 'click', 'selector': '#submit'},
          ],
        },
      );
      expect(out['success'], isFalse);
      expect((out['errors'] as List<dynamic>).single,
          contains('step `click` failed'));
      await b.runtime.shutdown();
    });

    test('capture_receipt returns the final page text', () async {
      final b = _build();
      await b.runtime.initialize();
      final out = await b.operations.get('submit_form')!.handler(
        <String, dynamic>{
          'url': 'https://portal.example/',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{'action': 'click', 'selector': '#go'},
          ],
          'capture_receipt': true,
        },
      );
      expect(out['receipt'], isA<Map<String, dynamic>>());
      expect((out['receipt'] as Map<String, dynamic>)['mime'], 'text/plain');
      await b.runtime.shutdown();
    });
  });

  group('Op page_compare_actors (TC-1008)', () {
    test('returns one envelope-set per actor', () async {
      final b = _build();
      await b.runtime.initialize();
      // Pre-register stub profiles so setAuth doesn't throw.
      final authStore = b.runtime.authStore!;
      await authStore.put(BrowserAuthProfile(id: 'a@x', tenantId: '_default'));
      await authStore.put(BrowserAuthProfile(id: 'b@x', tenantId: '_default'));

      final out = await b.operations.get('page_compare_actors')!.handler(
        <String, dynamic>{
          'actors': <String>['a@x', 'b@x'],
          'route': 'https://makemind.dev/admin',
        },
      );
      final byActor = out['byActor'] as Map<String, dynamic>;
      expect(byActor.keys, <String>{'a@x', 'b@x'});
      expect(byActor['a@x']['text'], contains('a@x'));
      expect(byActor['b@x']['text'], contains('b@x'));
      await b.runtime.shutdown();
    });
  });

  group('McpIntegration registers 9 Phase 4 operations', () {
    test('full skill catalogue includes submit_form + page_compare_actors',
        () {
      final b = _build();
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
      expect(tools.toSet(), <String>{
        'page_view',
        'page_audit_role',
        'web_search',
        'extract',
        'crawl',
        'monitor',
        'download',
        'submit_form',
        'page_compare_actors',
      });
    });
  });
}
