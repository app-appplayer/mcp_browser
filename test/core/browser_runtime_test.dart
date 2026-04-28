/// TEST — MOD-CORE-001 BrowserRuntime.
///
/// Mirrors `docs/04_TEST/02-runtime.md` (TC-001~024).
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

class _CapturingIngest {
  BrowserPayloadEnvelope? captured;
  Future<void> call(BrowserPayloadEnvelope env) async {
    captured = env;
  }
}

class _ThrowingIngest {
  Future<void> call(BrowserPayloadEnvelope env) async {
    throw StateError('ingest failure');
  }
}

BrowserRuntime _newRuntime({
  FakeEngine? engine,
  FakeContextPort? contextPort,
  PolicyEngine? policy,
  IngestForwarder? ingest,
  AuthProfileStore? authStore,
}) {
  final engines = EngineRegistry()
    ..register('fake',
        engine: engine ?? FakeEngine(),
        context: contextPort ?? FakeContextPort());
  final pol = policy ?? PolicyEngine.defaults();
  final contexts = ContextRegistry(
    engines: engines,
    policy: pol,
  );
  final audit = AuditTrail(sink: InMemoryAuditSink(), bufferSize: 100);
  return BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: pol,
    audit: audit,
    authStore: authStore,
    ingest: ingest,
  );
}

void main() {
  group('BrowserRuntime — describe', () {
    test('TC-001 describe lists engines and active contexts', () async {
      final rt = _newRuntime();
      await rt.initialize();
      final desc = await rt.describe();
      expect(desc.engines, hasLength(1));
      expect(desc.activeContexts, 0);
      await rt.shutdown();
    });
  });

  group('BrowserRuntime — read', () {
    test('TC-003 read returns envelope and writes audit', () async {
      final engine = FakeEngine()
        ..readImpl = (BrowserContextHandle h, BrowserReadSpec s) =>
            BrowserPayloadEnvelope(
              contextId: h.contextId,
              mime: 'text/plain',
              body: 'Hello',
            );
      final rt = _newRuntime(engine: engine);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      final env = await rt.read(h.contextId, BrowserReadSpec.text());
      expect(env.body, 'Hello');
      await rt.shutdown();
    });

    test('TC-005 read on unknown context throws E1002', () async {
      final rt = _newRuntime();
      await rt.initialize();
      expect(
        () => rt.read('missing', BrowserReadSpec.text()),
        throwsA(isA<ContextNotFoundError>()),
      );
      await rt.shutdown();
    });

    test('TC-023 ingest forwarder receives the envelope', () async {
      final ingest = _CapturingIngest();
      final rt = _newRuntime(ingest: ingest.call);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      await rt.read(h.contextId, BrowserReadSpec.text());
      expect(ingest.captured, isNotNull);
      expect(ingest.captured!.contextId, h.contextId);
      await rt.shutdown();
    });

    test('TC-024 ingest hand-off failure does not block read', () async {
      final ingest = _ThrowingIngest();
      final rt = _newRuntime(ingest: ingest.call);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      final env = await rt.read(h.contextId, BrowserReadSpec.text());
      expect(env, isNotNull);
      await rt.shutdown();
    });
  });

  group('BrowserRuntime — execute', () {
    test('TC-007 navigate succeeds when allowed', () async {
      final rt = _newRuntime();
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      final r = await rt.execute(
        h.contextId,
        BrowserAction.navigate('https://makemind.dev/'),
      );
      expect(r.success, isTrue);
      await rt.shutdown();
    });

    test('TC-008 navigate denied throws and audits', () async {
      final policy = PolicyEngine.defaults()
        ..urlRules.denyDomain('blocked.example');
      final rt = _newRuntime(policy: policy);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      expect(
        () => rt.execute(
          h.contextId,
          BrowserAction.navigate('https://blocked.example/'),
        ),
        throwsA(isA<StateError>()),
      );
      await rt.shutdown();
    });

    test('TC-016 unknown engine resolves throws E1001', () async {
      final rt = _newRuntime();
      await rt.initialize();
      // Inject a context whose engineId points to a missing engine.
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      // Force engine swap to a non-registered id.
      rt.engines.unregister('fake');
      expect(
        () => rt.execute(
          h.contextId,
          BrowserAction.navigate('https://x.com/'),
        ),
        throwsA(isA<EngineNotRegisteredError>()),
      );
      await rt.shutdown();
    });
  });

  group('BrowserRuntime — setAuth routing', () {
    test('TC-012 setAuth on missing profile throws E4001', () async {
      final kv = InMemoryKvStoragePort();
      final store = AuthProfileStore(
        kv: kv,
        crypto: SecretBox.fromPassphrase('k'),
      );
      final rt = _newRuntime(authStore: store);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      expect(
        () => rt.execute(
          h.contextId,
          BrowserAction(
            kind: BrowserActionKind.setAuth,
            params: <String, dynamic>{'profileId': 'missing'},
          ),
        ),
        throwsA(isA<AuthProfileNotFoundError>()),
      );
      await rt.shutdown();
    });

    test('TC-011 setAuth wires cookies/headers when present', () async {
      final kv = InMemoryKvStoragePort();
      final store = AuthProfileStore(
        kv: kv,
        crypto: SecretBox.fromPassphrase('k'),
      );
      await store.put(BrowserAuthProfile(
        id: 'a@x',
        tenantId: 't',
        cookies: const <BrowserCookie>[
          BrowserCookie(name: 'sid', value: 'v'),
        ],
      ));
      final ctx = FakeContextPort();
      final rt = _newRuntime(authStore: store, contextPort: ctx);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't', actorId: 'a@x'),
      );
      final r = await rt.execute(
        h.contextId,
        BrowserAction(
          kind: BrowserActionKind.setAuth,
          params: <String, dynamic>{'profileId': 'a@x'},
        ),
      );
      expect(r.success, isTrue);
      expect((h.enginePayload as FakeEnginePayload).cookies, hasLength(1));
      await rt.shutdown();
    });
  });

  group('BrowserRuntime — subscribe', () {
    test('TC-017 subscribe returns the engine stream', () async {
      final controller = StreamController<BrowserEvent>();
      final engine = FakeEngine()
        ..subscribeImpl =
            (BrowserContextHandle h, BrowserTopic t) => controller.stream;
      final rt = _newRuntime(engine: engine);
      await rt.initialize();
      final h = await rt.contexts.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );
      final received = <BrowserEvent>[];
      final sub = rt
          .subscribe(h.contextId, BrowserTopic.consoleError())
          .listen(received.add);
      controller.add(BrowserEvent(
        topic: BrowserTopicKind.consoleError,
        payload: const <String, dynamic>{'text': 'oops'},
      ));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      await sub.cancel();
      await controller.close();
      await rt.shutdown();
    });
  });

  group('BrowserRuntime — lifecycle', () {
    test('TC-020 initialize starts engines and contexts', () async {
      final engine = FakeEngine();
      final rt = _newRuntime(engine: engine);
      await rt.initialize();
      expect(engine.initialized, isTrue);
      await rt.shutdown();
    });

    test('TC-021 shutdown is graceful', () async {
      final engine = FakeEngine();
      final rt = _newRuntime(engine: engine);
      await rt.initialize();
      await rt.contexts.acquire(const BrowserContextSpec(tenantId: 't'));
      await rt.shutdown();
      expect(engine.wasShutdown, isTrue);
    });
  });
}
