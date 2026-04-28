/// TEST — MOD-REG-001 ContextRegistry.
///
/// Mirrors `docs/04_TEST/03-context.md` (TC-100~119).
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

EngineRegistry _newEngineRegistry({
  FakeEngine? engine,
  FakeContextPort? context,
}) {
  return EngineRegistry()
    ..register(
      'fake',
      engine: engine ?? FakeEngine(),
      context: context ?? FakeContextPort(),
    );
}

ContextRegistry _newContextRegistry({
  EngineRegistry? engines,
  BrowserPolicyPort? policy,
  KvStoragePort? storage,
  int warmPoolSize = 0,
  Duration idleTtl = const Duration(minutes: 30),
  Duration? acquireWaitTimeout,
  DateTime Function()? now,
}) {
  return ContextRegistry(
    engines: engines ?? _newEngineRegistry(),
    policy: policy ?? PolicyEngine.defaults(),
    storage: storage,
    warmPoolSize: warmPoolSize,
    idleTtl: idleTtl,
    acquireWaitTimeout: acquireWaitTimeout,
    now: now,
  );
}

void main() {
  group('ContextRegistry — acquire/release/close', () {
    test('TC-100 acquire returns an active handle (cold)', () async {
      final reg = _newContextRegistry();
      await reg.initialize();
      final h = await reg.acquire(
        const BrowserContextSpec(tenantId: 't1', actorId: 'a'),
      );
      expect(h.state, ContextLifecycleState.active);
      expect(h.engineId, 'fake');
      expect(reg.activeCount(), 1);
      await reg.shutdown();
    });

    test('TC-101 acquire reuses a compatible idle handle (no openContext)',
        () async {
      final ctx = FakeContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
      );
      await reg.initialize();
      const spec = BrowserContextSpec(tenantId: 't1', actorId: 'a');
      final first = await reg.acquire(spec);
      await reg.release(first.contextId);
      final reused = await reg.acquire(spec);
      expect(reused.contextId, first.contextId);
      expect(ctx.openCalls, 1, reason: 'second acquire must reuse');
      await reg.shutdown();
    });

    test('TC-102 distinct actors get isolated payloads', () async {
      final ctx = FakeContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
      );
      await reg.initialize();
      final a = await reg.acquire(
        const BrowserContextSpec(tenantId: 't', actorId: 'a'),
      );
      final b = await reg.acquire(
        const BrowserContextSpec(tenantId: 't', actorId: 'b'),
      );
      expect(a.enginePayload, isNot(same(b.enginePayload)));
      await reg.shutdown();
    });

    test(
        'TC-103 acquire over the cap waits up to acquireWaitTimeout then throws E1003',
        () async {
      final policy = PolicyEngine(
        urlRules: UrlAccessRules(),
        quota: DomainQuotaTracker(),
        caps: const BrowserResourceCaps(maxConcurrentContexts: 1),
      );
      final reg = _newContextRegistry(
        policy: policy,
        acquireWaitTimeout: const Duration(milliseconds: 50),
      );
      await reg.initialize();
      await reg.acquire(const BrowserContextSpec(tenantId: 't'));
      expect(
        () => reg.acquire(const BrowserContextSpec(tenantId: 't')),
        throwsA(isA<ContextLimitExceededError>()),
      );
      await reg.shutdown();
    });

    test(
        'TC-103b acquire blocks until release frees a slot (within timeout)',
        () async {
      final policy = PolicyEngine(
        urlRules: UrlAccessRules(),
        quota: DomainQuotaTracker(),
        caps: const BrowserResourceCaps(maxConcurrentContexts: 1),
      );
      final reg = _newContextRegistry(
        policy: policy,
        acquireWaitTimeout: const Duration(seconds: 1),
      );
      await reg.initialize();
      final first = await reg.acquire(
        const BrowserContextSpec(tenantId: 't'),
      );

      final pending = reg.acquire(const BrowserContextSpec(tenantId: 't'));
      // Schedule release on a microtask so the waiter is queued first.
      scheduleMicrotask(() => reg.release(first.contextId));
      final reused = await pending;
      expect(reused.contextId, isNotNull);
      await reg.shutdown();
    });

    test('TC-104 persistent acquire restores prior storage state', () async {
      final ctx = FakeContextPort();
      final storage = InMemoryKvStoragePort();
      const spec = BrowserContextSpec(
        tenantId: 't',
        actorId: 'a',
        persistent: true,
      );
      await storage.set(
        'mcp_browser/storage_state/${spec.specHash}',
        <String, dynamic>{'cookies': <Map<String, String>>[]},
      );

      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
        storage: storage,
      );
      await reg.initialize();
      await reg.acquire(spec);
      expect(ctx.restoreStateCalls, 1);
      expect(ctx.lastRestoredState, isNotNull);
      await reg.shutdown();
    });

    test('TC-105 release moves handle to idle', () async {
      final reg = _newContextRegistry();
      await reg.initialize();
      final h = await reg.acquire(const BrowserContextSpec(tenantId: 't'));
      await reg.release(h.contextId);
      expect(h.state, ContextLifecycleState.idle);
      await reg.shutdown();
    });

    test(
        'TC-106 release on persistent context saves storage state to KV',
        () async {
      final ctx = FakeContextPort();
      final storage = InMemoryKvStoragePort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
        storage: storage,
      );
      await reg.initialize();
      final h = await reg.acquire(const BrowserContextSpec(
        tenantId: 't',
        persistent: true,
      ));
      await reg.release(h.contextId);
      expect(ctx.saveStateCalls, 1);
      expect(await storage.exists(
        'mcp_browser/storage_state/${h.spec.specHash}',
      ), isTrue);
      await reg.shutdown();
    });

    test('TC-107 close removes the handle and calls engine.closeContext',
        () async {
      final ctx = FakeContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
      );
      await reg.initialize();
      final h = await reg.acquire(const BrowserContextSpec(tenantId: 't'));
      await reg.close(h.contextId);
      expect(reg.lookup(h.contextId), isNull);
      expect(ctx.closeCalls, 1);
      await reg.shutdown();
    });

    test('TC-108 close on unknown id is a no-op', () async {
      final reg = _newContextRegistry();
      await reg.initialize();
      await reg.close('nope');
      // No throw == pass.
      await reg.shutdown();
    });

    test('TC-109/110 lookup returns handle or null', () async {
      final reg = _newContextRegistry();
      await reg.initialize();
      final h = await reg.acquire(const BrowserContextSpec(tenantId: 't'));
      expect(reg.lookup(h.contextId), same(h));
      expect(reg.lookup('missing'), isNull);
      await reg.shutdown();
    });

    test('TC-111 snapshot lists every known handle', () async {
      final reg = _newContextRegistry();
      await reg.initialize();
      await reg.acquire(const BrowserContextSpec(tenantId: 'a'));
      await reg.acquire(const BrowserContextSpec(tenantId: 'b'));
      expect(reg.snapshot(), hasLength(2));
      await reg.shutdown();
    });

    test('TC-112 activeCount reflects only active handles', () async {
      final reg = _newContextRegistry();
      await reg.initialize();
      final a = await reg.acquire(const BrowserContextSpec(tenantId: 'a'));
      await reg.acquire(const BrowserContextSpec(tenantId: 'b'));
      await reg.release(a.contextId);
      expect(reg.activeCount(), 1);
      await reg.shutdown();
    });

    test('TC-113 initialize prewarms warm pool when configured', () async {
      final ctx = FakeContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
        warmPoolSize: 2,
      );
      await reg.initialize();
      expect(reg.snapshot(), hasLength(2));
      expect(ctx.openCalls, 2);
      await reg.shutdown();
    });

    test('TC-114 shutdown closes every active handle', () async {
      final ctx = FakeContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
      );
      await reg.initialize();
      await reg.acquire(const BrowserContextSpec(tenantId: 'a'));
      await reg.acquire(const BrowserContextSpec(tenantId: 'b'));
      await reg.shutdown();
      expect(ctx.closeCalls, 2);
    });

    test(
        'TC-116 acquire without a default engine throws E1001',
        () async {
      final reg = ContextRegistry(
        engines: EngineRegistry(),
        policy: PolicyEngine.defaults(),
      );
      await reg.initialize();
      expect(
        () => reg.acquire(const BrowserContextSpec(tenantId: 't')),
        throwsA(isA<EngineNotRegisteredError>()),
      );
      await reg.shutdown();
    });

    test(
        'TC-117 openContext throwing propagates and is not registered',
        () async {
      final ctx = _ThrowOpenContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
      );
      await reg.initialize();
      expect(
        () => reg.acquire(const BrowserContextSpec(tenantId: 't')),
        throwsA(isA<StateError>()),
      );
      expect(reg.snapshot(), isEmpty);
      await reg.shutdown();
    });

    test(
        'TC-118 saveStorageState failure is suppressed during release',
        () async {
      final ctx = _ThrowSaveStateContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
        storage: InMemoryKvStoragePort(),
      );
      await reg.initialize();
      final h = await reg.acquire(
        const BrowserContextSpec(tenantId: 't', persistent: true),
      );
      // Should not throw even though saveStorageState raises.
      await reg.release(h.contextId);
      expect(h.state, ContextLifecycleState.idle);
      await reg.shutdown();
    });

    test('TC-119 release on non-persistent does not call saveStorageState',
        () async {
      final ctx = FakeContextPort();
      final reg = _newContextRegistry(
        engines: _newEngineRegistry(context: ctx),
        storage: InMemoryKvStoragePort(),
      );
      await reg.initialize();
      final h = await reg.acquire(const BrowserContextSpec(tenantId: 't'));
      await reg.release(h.contextId);
      expect(ctx.saveStateCalls, 0);
      await reg.shutdown();
    });
  });
}

class _ThrowOpenContextPort extends FakeContextPort {
  @override
  Future<Object> openContext(BrowserContextSpec spec) async {
    throw StateError('openContext failure');
  }
}

class _ThrowSaveStateContextPort extends FakeContextPort {
  @override
  Future<Map<String, dynamic>> saveStorageState(Object enginePayload) async {
    throw StateError('saveStorageState failure');
  }
}
