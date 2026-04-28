/// TEST — Matrix runner (Phase 5 Tooling).
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

({BrowserRuntime runtime, ContextRegistry contexts, MatrixRunner runner})
    _build() {
  final engine = FakeEngine();
  engine.readImpl = (BrowserContextHandle h, BrowserReadSpec s) =>
      BrowserPayloadEnvelope(
        contextId: h.contextId,
        mime: 'text/plain',
        body: '${h.spec.actorId ?? 'anon'}@${s.kind.name}',
      );
  final engines = EngineRegistry()
    ..register('fake', engine: engine, context: FakeContextPort());
  final policy = PolicyEngine.defaults();
  final contexts = ContextRegistry(engines: engines, policy: policy);
  final authStore = AuthProfileStore(
    kv: InMemoryKvStoragePort(),
    crypto: SecretBox.fromPassphrase('k'),
  );
  final runtime = BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: policy,
    audit: AuditTrail(sink: InMemoryAuditSink()),
    authStore: authStore,
  );
  return (
    runtime: runtime,
    contexts: contexts,
    runner: MatrixRunner(runtime: runtime, contexts: contexts),
  );
}

void main() {
  group('MatrixRunner', () {
    test('produces one cell per (actor, route, viewport)', () async {
      final b = _build();
      await b.runtime.initialize();
      // Seed stub auth profiles for the actors.
      final store = b.runtime.authStore!;
      for (final actor in <String>['a@x', 'b@x']) {
        await store.put(BrowserAuthProfile(id: actor, tenantId: 't'));
      }

      final cells = await b.runner.run(const MatrixSpec(
        tenantId: 't',
        actors: <String>['a@x', 'b@x'],
        routes: <String>['https://x.com/a', 'https://x.com/b'],
        viewports: <Viewport>[
          Viewport(width: 1280, height: 800, label: 'desktop'),
          Viewport(width: 390, height: 844, label: 'mobile'),
        ],
        captures: <String>['text'],
      ));

      expect(cells, hasLength(2 * 2 * 2));
      for (final cell in cells) {
        expect(cell.captures['text'], contains(cell.actor));
      }
      await b.runtime.shutdown();
    });

    test('actor setup failure propagates to cell.error', () async {
      final b = _build();
      await b.runtime.initialize();
      // Do NOT seed the profile — setAuth will throw on the actor acquire.
      final cells = await b.runner.run(const MatrixSpec(
        tenantId: 't',
        actors: <String>['missing@x'],
        routes: <String>['https://x.com/a'],
      ));
      expect(cells, hasLength(1));
      expect(cells.single.error, startsWith('actor_setup_failed'));
      await b.runtime.shutdown();
    });

    test('cell JSON includes all required fields', () {
      const cell = MatrixCell(
        actor: 'a@x',
        route: 'https://x.com/',
        viewport: Viewport(width: 1280, height: 800, label: 'desktop'),
        captures: <String, dynamic>{'text': 'Hello'},
        consoleErrors: <String>['boom'],
        requestFailed: <String>['https://x.com/missing'],
        duration: Duration(milliseconds: 120),
      );
      final json = cell.toJson();
      expect(json['actor'], 'a@x');
      expect(json['viewport'], 'desktop(1280x800)');
      expect(json['durationMs'], 120);
      expect(json['consoleErrors'], isA<List<dynamic>>());
    });
  });
}
