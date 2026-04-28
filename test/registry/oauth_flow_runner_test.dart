/// TEST — OAuthFlowRunner (deferred from Step 3).
///
/// Mirrors `docs/04_TEST/06-auth.md` TC-417, TC-418, TC-419.
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

class _RedirectingEngine extends FakeEngine {

  _RedirectingEngine(this.redirectUrl);
  final StreamController<BrowserEvent> events =
      StreamController<BrowserEvent>.broadcast();

  /// URL to emit in the request stream after `navigate`.
  final String redirectUrl;

  @override
  Stream<BrowserEvent> subscribe(
    BrowserContextHandle handle,
    BrowserTopic topic,
  ) {
    return events.stream;
  }

  @override
  Future<BrowserActionResult> execute(
    BrowserContextHandle handle,
    BrowserAction action,
  ) async {
    if (action.kind == BrowserActionKind.navigate) {
      // Schedule the redirect event after the navigate returns.
      scheduleMicrotask(() {
        events.add(BrowserEvent(
          topic: BrowserTopicKind.request,
          payload: <String, dynamic>{'url': redirectUrl},
        ));
      });
    }
    return const BrowserActionResult(success: true);
  }
}

({BrowserRuntime runtime, OAuthFlowRunner oauth, _RedirectingEngine engine})
    _build({String redirectUrl = 'https://callback.example.com/?code=abc123'}) {
  final engine = _RedirectingEngine(redirectUrl);
  final engines = EngineRegistry()
    ..register('fake', engine: engine, context: FakeContextPort());
  final policy = PolicyEngine.defaults();
  final contexts = ContextRegistry(engines: engines, policy: policy);
  final runtime = BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: policy,
    audit: AuditTrail(sink: InMemoryAuditSink()),
  );
  final oauth = OAuthFlowRunner(runtime: runtime, contexts: contexts);
  return (runtime: runtime, oauth: oauth, engine: engine);
}

void main() {
  group('OAuthFlowRunner', () {
    test('TC-417 successful flow returns the exchanged profile', () async {
      final b = _build();
      await b.runtime.initialize();
      final profile = await b.oauth.run(
        tenantId: 't',
        profileId: 'a@x',
        authorizationUrl: 'https://idp.example.com/authorize',
        redirectMatcher: RegExp(r'^https://callback\.example\.com/'),
        exchange: (String code) async => BrowserAuthProfile(
          id: 'a@x',
          tenantId: 't',
          headers: <String, String>{'Authorization': 'Bearer $code'},
        ),
        timeout: const Duration(seconds: 2),
      );
      expect(profile.headers['Authorization'], 'Bearer abc123');
      await b.engine.events.close();
      await b.runtime.shutdown();
    });

    test('TC-418 timeout surfaces as OAuthFlowError', () async {
      final engine = FakeEngine();
      final engines = EngineRegistry()
        ..register('fake', engine: engine, context: FakeContextPort());
      final policy = PolicyEngine.defaults();
      final contexts = ContextRegistry(engines: engines, policy: policy);
      final runtime = BrowserRuntime(
        engines: engines,
        contexts: contexts,
        policy: policy,
        audit: AuditTrail(sink: InMemoryAuditSink()),
      );
      final oauth = OAuthFlowRunner(runtime: runtime, contexts: contexts);
      await runtime.initialize();
      await expectLater(
        oauth.run(
          tenantId: 't',
          profileId: 'a@x',
          authorizationUrl: 'https://idp.example.com/authorize',
          redirectMatcher: RegExp(r'^https://callback\.example\.com/'),
          exchange: (String code) async => BrowserAuthProfile(
            id: 'a@x',
            tenantId: 't',
          ),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<OAuthFlowError>()),
      );
      await runtime.shutdown();
    });

    test('TC-419 exchange failure surfaces as OAuthFlowError', () async {
      final b = _build();
      await b.runtime.initialize();
      await expectLater(
        b.oauth.run(
          tenantId: 't',
          profileId: 'a@x',
          authorizationUrl: 'https://idp.example.com/authorize',
          redirectMatcher: RegExp(r'^https://callback\.example\.com/'),
          exchange: (String code) async => throw StateError('IdP down'),
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<OAuthFlowError>()),
      );
      await b.engine.events.close();
      await b.runtime.shutdown();
    });
  });
}
