/// TEST — MOD-DEF-001 BrowserOperations.
///
/// Mirrors `docs/04_TEST/12-skill-definitions.md` TC-1002, TC-1005.
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

({BrowserRuntime runtime, BrowserOperations operations, FakeEngine engine})
    _build({AuthProfileStore? authStore}) {
  final engine = FakeEngine()
    ..readImpl = (BrowserContextHandle h, BrowserReadSpec s) =>
        BrowserPayloadEnvelope(
          contextId: h.contextId,
          mime: 'text/plain',
          body: 'rendered:${s.kind.name}',
        );
  final engines = EngineRegistry()
    ..register('fake', engine: engine, context: FakeContextPort());
  final policy = PolicyEngine.defaults();
  final contexts = ContextRegistry(engines: engines, policy: policy);
  final runtime = BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: policy,
    audit: AuditTrail(sink: InMemoryAuditSink()),
    authStore: authStore,
  );
  final operations = BrowserOperations(runtime: runtime, contexts: contexts);
  return (runtime: runtime, operations: operations, engine: engine);
}

void main() {
  group('BrowserOperations — page_view (TC-1002)', () {
    test('returns one envelope per requested capture', () async {
      final b = _build();
      await b.runtime.initialize();
      final result = await b.operations.get('page_view')!.handler(
        <String, dynamic>{
          'tenantId': 't',
          'path': 'https://makemind.dev/',
          'capture': <String>['text', 'html'],
        },
      );
      final envs = result['envelopes'] as List<dynamic>;
      expect(envs, hasLength(2));
      expect((envs.first as Map<String, dynamic>)['kind'], 'text');
      await b.runtime.shutdown();
    });
  });

  group('BrowserOperations — page_audit_role (TC-1005)', () {
    test('produces actor × route matrix cells', () async {
      final kv = InMemoryKvStoragePort();
      final store = AuthProfileStore(
        kv: kv,
        crypto: SecretBox.fromPassphrase('k'),
      );
      await store.put(BrowserAuthProfile(id: 'a@x', tenantId: 't'));
      await store.put(BrowserAuthProfile(id: 'b@x', tenantId: 't'));
      final b = _build(authStore: store);
      await b.runtime.initialize();
      final result = await b.operations.get('page_audit_role')!.handler(
        <String, dynamic>{
          'tenantId': 't',
          'actors': <String>['a@x', 'b@x'],
          'routes': <String>['https://x.com/a', 'https://x.com/b'],
        },
      );
      final matrix = result['matrix'] as List<dynamic>;
      expect(matrix, hasLength(4));
      await b.runtime.shutdown();
    });
  });
}
