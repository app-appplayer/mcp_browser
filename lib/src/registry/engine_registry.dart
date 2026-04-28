/// MOD-REG-002 — EngineRegistry implementation.
///
/// See `docs/03_DDD/11-engine-contract.md` for the design specification and
/// `docs/04_TEST/11-engine-contract.md` for the test plan.
library;

import '../_internal.dart';

/// Error thrown when an engine identifier cannot be resolved.
class EngineNotRegisteredError extends StateError {
  EngineNotRegisteredError(String engineId)
      : super('E1001 EngineNotRegistered: $engineId');
}

/// In-process registry of engine adapters.
class EngineRegistry {
  final Map<String, BrowserEnginePort> _engines = <String, BrowserEnginePort>{};
  final Map<String, BrowserContextPort> _contexts =
      <String, BrowserContextPort>{};

  String? _defaultEngineId;

  /// The engine that is used when a [BrowserContextSpec] omits `engineId`.
  ///
  /// Defaults to the first registered engine; can be reassigned at any time.
  String? get defaultEngineId => _defaultEngineId;
  set defaultEngineId(String? value) {
    if (value != null && !_engines.containsKey(value)) {
      throw EngineNotRegisteredError(value);
    }
    _defaultEngineId = value;
  }

  /// Whether any engine is currently registered.
  bool get isEmpty => _engines.isEmpty;

  /// Number of registered engines.
  int get length => _engines.length;

  /// Initialize all currently registered engines. Failures propagate; engines
  /// successfully initialized before the failure remain initialized and must
  /// be reaped via [shutdown].
  Future<void> initialize() async {
    for (final engine in _engines.values) {
      await engine.initialize();
    }
  }

  /// Shutdown all engines. Each engine's failure is suppressed so that other
  /// engines still get a chance to release resources.
  Future<void> shutdown() async {
    for (final engine in _engines.values) {
      try {
        await engine.shutdown();
      } on Object {
        // Suppress; cleanup must continue across all engines.
      }
    }
  }

  /// Register [engineId] with its [engine] surface and [context] lifecycle
  /// surface. The first registration is promoted to [defaultEngineId].
  void register(
    String engineId, {
    required BrowserEnginePort engine,
    required BrowserContextPort context,
  }) {
    _engines[engineId] = engine;
    _contexts[engineId] = context;
    _defaultEngineId ??= engineId;
  }

  /// Remove [engineId]. If it was [defaultEngineId], the next registered
  /// engine (insertion order) becomes default; if none remain, default is
  /// cleared.
  void unregister(String engineId) {
    _engines.remove(engineId);
    _contexts.remove(engineId);
    if (_defaultEngineId == engineId) {
      _defaultEngineId = _engines.keys.isEmpty ? null : _engines.keys.first;
    }
  }

  /// Resolve [engineId] to its [BrowserEnginePort].
  BrowserEnginePort resolve(String engineId) {
    final engine = _engines[engineId];
    if (engine == null) throw EngineNotRegisteredError(engineId);
    return engine;
  }

  /// Resolve [engineId] to its [BrowserContextPort].
  BrowserContextPort resolveContextPort(String engineId) {
    final port = _contexts[engineId];
    if (port == null) throw EngineNotRegisteredError(engineId);
    return port;
  }

  /// Snapshot of registered engine descriptors.
  List<EngineDescriptor> list() =>
      _engines.values.map((BrowserEnginePort e) => e.describe()).toList();
}
