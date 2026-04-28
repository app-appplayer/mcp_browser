/// TEST — MOD-REG-002 EngineRegistry.
///
/// Mirrors `docs/04_TEST/11-engine-contract.md` (TC-900~910).
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

void main() {
  group('EngineRegistry', () {
    test('TC-900 register sets default on first registration', () {
      final reg = EngineRegistry();
      reg.register('cdp', engine: FakeEngine(), context: FakeContextPort());
      expect(reg.length, 1);
      expect(reg.defaultEngineId, 'cdp');
    });

    test('TC-901 second register does NOT change default', () {
      final reg = EngineRegistry()
        ..register('cdp', engine: FakeEngine(), context: FakeContextPort())
        ..register('playwright',
            engine: FakeEngine(engineId: 'playwright'),
            context: FakeContextPort());
      expect(reg.defaultEngineId, 'cdp');
    });

    test('TC-902 unregister default falls through to next', () {
      final reg = EngineRegistry()
        ..register('cdp', engine: FakeEngine(), context: FakeContextPort())
        ..register('webkit',
            engine: FakeEngine(engineId: 'webkit'),
            context: FakeContextPort())
        ..unregister('cdp');
      expect(reg.defaultEngineId, 'webkit');
    });

    test('TC-902b unregister last engine clears default', () {
      final reg = EngineRegistry()
        ..register('cdp', engine: FakeEngine(), context: FakeContextPort())
        ..unregister('cdp');
      expect(reg.defaultEngineId, isNull);
      expect(reg.isEmpty, isTrue);
    });

    test('TC-903 resolve returns the registered engine', () {
      final engine = FakeEngine();
      final reg = EngineRegistry()
        ..register('cdp', engine: engine, context: FakeContextPort());
      expect(reg.resolve('cdp'), same(engine));
    });

    test('TC-904 resolve unknown engineId throws E1001', () {
      final reg = EngineRegistry();
      expect(
        () => reg.resolve('missing'),
        throwsA(isA<EngineNotRegisteredError>()),
      );
    });

    test('TC-905 resolveContextPort returns the context surface', () {
      final ctx = FakeContextPort();
      final reg = EngineRegistry()
        ..register('cdp', engine: FakeEngine(), context: ctx);
      expect(reg.resolveContextPort('cdp'), same(ctx));
    });

    test('TC-906 list collects descriptors', () {
      final reg = EngineRegistry()
        ..register('cdp',
            engine: FakeEngine(engineId: 'cdp'),
            context: FakeContextPort())
        ..register('webkit',
            engine: FakeEngine(engineId: 'webkit'),
            context: FakeContextPort());
      final ids = reg.list().map((EngineDescriptor d) => d.id).toSet();
      expect(ids, <String>{'cdp', 'webkit'});
    });

    test('TC-907 initialize calls each engine.initialize', () async {
      final e1 = FakeEngine();
      final e2 = FakeEngine(engineId: 'b');
      final reg = EngineRegistry()
        ..register('a', engine: e1, context: FakeContextPort())
        ..register('b', engine: e2, context: FakeContextPort());
      await reg.initialize();
      expect(e1.initialized, isTrue);
      expect(e2.initialized, isTrue);
    });

    test('TC-908 shutdown invokes each engine.shutdown', () async {
      final e1 = FakeEngine();
      final e2 = FakeEngine(engineId: 'b');
      final reg = EngineRegistry()
        ..register('a', engine: e1, context: FakeContextPort())
        ..register('b', engine: e2, context: FakeContextPort());
      await reg.shutdown();
      expect(e1.wasShutdown, isTrue);
      expect(e2.wasShutdown, isTrue);
    });

    test(
        'TC-909 shutdown suppresses individual engine errors',
        () async {
      final e1 = _BoomShutdownEngine();
      final e2 = FakeEngine(engineId: 'b');
      final reg = EngineRegistry()
        ..register('a', engine: e1, context: FakeContextPort())
        ..register('b', engine: e2, context: FakeContextPort());
      await reg.shutdown();
      expect(e2.wasShutdown, isTrue);
    });

    test('TC-910 setting unknown defaultEngineId throws E1001', () {
      final reg = EngineRegistry();
      expect(
        () => reg.defaultEngineId = 'missing',
        throwsA(isA<EngineNotRegisteredError>()),
      );
    });
  });
}

class _BoomShutdownEngine extends FakeEngine {
  _BoomShutdownEngine() : super(engineId: 'boom');
  @override
  Future<void> shutdown() async {
    throw StateError('boom on shutdown');
  }
}
