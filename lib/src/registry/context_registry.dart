/// MOD-REG-001 — ContextRegistry implementation.
///
/// See `docs/03_DDD/03-context.md` for the design specification and
/// `docs/04_TEST/03-context.md` for the test plan.
library;

import 'dart:async';
import 'dart:collection';

import '../_internal.dart';
import 'package:uuid/uuid.dart';

import 'engine_registry.dart';

const _uuid = Uuid();

/// Error thrown when a [BrowserContextHandle] cannot be located.
class ContextNotFoundError extends StateError {
  ContextNotFoundError(String contextId)
      : super('E1002 ContextNotFound: $contextId');
}

/// Error thrown when [ContextRegistry.acquire] cannot satisfy the
/// concurrency cap within the configured timeout.
class ContextLimitExceededError extends StateError {
  ContextLimitExceededError()
      : super('E1003 ContextLimitExceeded');
}

/// Lifecycle manager for [BrowserContextHandle] instances.
class ContextRegistry {

  ContextRegistry({
    required this.engines,
    required this.policy,
    this.storage,
    this.warmPoolSize = 0,
    this.idleTtl = const Duration(minutes: 30),
    this.acquireWaitTimeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final EngineRegistry engines;
  final BrowserPolicyPort policy;
  final KvStoragePort? storage;

  /// Number of warm-pool contexts to keep ready for fast acquire.
  final int warmPoolSize;

  /// How long an idle context may live before being closed by the sweeper.
  final Duration idleTtl;

  /// How long [acquire] will wait for an active slot before throwing
  /// [ContextLimitExceededError]. `null` disables waiting.
  final Duration? acquireWaitTimeout;

  /// Test/diagnostic clock override.
  final DateTime Function() _now;

  final Map<String, BrowserContextHandle> _byId =
      <String, BrowserContextHandle>{};

  final Queue<_AcquireWaiter> _waiters = Queue<_AcquireWaiter>();

  bool _initialized = false;
  bool _shuttingDown = false;
  Timer? _sweeper;

  /// Number of contexts currently in `active` state.
  int activeCount() => _byId.values
      .where((BrowserContextHandle h) =>
          h.state == ContextLifecycleState.active)
      .length;

  /// Snapshot of all known handles (warm/active/idle/closed).
  List<BrowserContextHandle> snapshot() =>
      List<BrowserContextHandle>.unmodifiable(_byId.values);

  /// Lookup by id; returns `null` if not present (or already closed and reaped).
  BrowserContextHandle? lookup(String contextId) => _byId[contextId];

  /// Initialize the registry. When [warmPoolSize] > 0 and a default engine
  /// is configured, pre-creates handles in the `warm` state.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (warmPoolSize > 0 && engines.defaultEngineId != null) {
      for (var i = 0; i < warmPoolSize; i++) {
        const spec = BrowserContextSpec(tenantId: '_warm');
        final port = engines.resolveContextPort(engines.defaultEngineId!);
        final payload = await port.openContext(spec);
        final handle = BrowserContextHandle(
          contextId: _uuid.v4(),
          engineId: engines.defaultEngineId!,
          spec: spec,
          enginePayload: payload,
          createdAt: _now(),
          lastUsedAt: _now(),
        );
        _byId[handle.contextId] = handle;
      }
    }
    _sweeper = Timer.periodic(_sweepInterval, (_) => _sweepIdle());
  }

  /// Acquire a handle satisfying [spec], reusing a warm/idle handle when one
  /// matches the spec hash.
  Future<BrowserContextHandle> acquire(BrowserContextSpec spec) async {
    if (_shuttingDown) {
      throw StateError('ContextRegistry is shutting down');
    }
    if (activeCount() >= policy.maxConcurrentContexts) {
      await _waitForSlot();
    }

    final reuse = _findReusable(spec);
    if (reuse != null) {
      reuse
        ..state = ContextLifecycleState.active
        ..lastUsedAt = _now();
      return reuse;
    }

    final engineId = spec.engineId ?? engines.defaultEngineId;
    if (engineId == null) {
      throw EngineNotRegisteredError('<default>');
    }
    final port = engines.resolveContextPort(engineId);
    final payload = await port.openContext(spec);

    final handle = BrowserContextHandle(
      contextId: _uuid.v4(),
      engineId: engineId,
      spec: spec,
      enginePayload: payload,
      createdAt: _now(),
      lastUsedAt: _now(),
      state: ContextLifecycleState.active,
    );
    _byId[handle.contextId] = handle;

    if (spec.persistent && storage != null) {
      try {
        final stored =
            await storage!.get('mcp_browser/storage_state/${spec.specHash}');
        if (stored is Map) {
          await port.restoreStorageState(
            payload,
            Map<String, dynamic>.from(stored),
          );
        }
      } on Object {
        // Restoration failure must not poison the acquire — start cold.
      }
    }

    return handle;
  }

  /// Move [contextId] to `idle` and persist storage state when applicable.
  /// Notifies the next acquire waiter.
  Future<void> release(String contextId) async {
    final handle = _byId[contextId];
    if (handle == null || handle.state == ContextLifecycleState.closed) return;
    handle
      ..state = ContextLifecycleState.idle
      ..lastUsedAt = _now();

    if (handle.spec.persistent && storage != null) {
      try {
        final port = engines.resolveContextPort(handle.engineId);
        final state = await port.saveStorageState(handle.enginePayload);
        await storage!.set(
          'mcp_browser/storage_state/${handle.spec.specHash}',
          state,
        );
      } on Object {
        // Best-effort persistence; release proceeds.
      }
    }
    _wakeNextWaiter();
  }

  /// Close [contextId] immediately. Idempotent.
  Future<void> close(String contextId) async {
    final handle = _byId.remove(contextId);
    if (handle == null) return;
    if (handle.state != ContextLifecycleState.closed) {
      try {
        final port = engines.resolveContextPort(handle.engineId);
        await port.closeContext(handle.enginePayload);
      } on Object {
        // Engine close failure is suppressed; the handle is already removed.
      }
    }
    handle.state = ContextLifecycleState.closed;
    _wakeNextWaiter();
  }

  /// Close every known handle. Stops the sweeper. Subsequent calls are no-ops.
  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _sweeper?.cancel();
    _sweeper = null;
    for (final waiter in _waiters) {
      waiter.completer.completeError(ContextLimitExceededError());
    }
    _waiters.clear();
    final ids = _byId.keys.toList(growable: false);
    for (final id in ids) {
      await close(id);
    }
  }

  // -------------------------------------------------------------------------

  static const _sweepInterval = Duration(minutes: 1);

  BrowserContextHandle? _findReusable(BrowserContextSpec spec) {
    for (final handle in _byId.values) {
      if (handle.state != ContextLifecycleState.warm &&
          handle.state != ContextLifecycleState.idle) {
        continue;
      }
      if (handle.engineId !=
          (spec.engineId ?? engines.defaultEngineId)) {
        continue;
      }
      if (handle.isCompatibleWith(spec)) return handle;
    }
    return null;
  }

  void _sweepIdle() {
    final now = _now();
    final stale = <String>[];
    for (final handle in _byId.values) {
      if (handle.state != ContextLifecycleState.idle) continue;
      if (now.difference(handle.lastUsedAt) > idleTtl) {
        stale.add(handle.contextId);
      }
    }
    for (final id in stale) {
      // Fire-and-forget; close failures are already suppressed inside [close].
      unawaited(close(id));
    }
  }

  Future<void> _waitForSlot() async {
    if (acquireWaitTimeout == null) {
      throw ContextLimitExceededError();
    }
    final waiter = _AcquireWaiter();
    _waiters.add(waiter);
    try {
      await waiter.completer.future
          .timeout(acquireWaitTimeout!, onTimeout: () {
        _waiters.remove(waiter);
        throw ContextLimitExceededError();
      });
    } on Object {
      rethrow;
    }
  }

  void _wakeNextWaiter() {
    if (_waiters.isEmpty) return;
    final waiter = _waiters.removeFirst();
    waiter.completer.complete();
  }
}

class _AcquireWaiter {
  final Completer<void> completer = Completer<void>();
}
