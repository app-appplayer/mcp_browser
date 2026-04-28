/// OAuth flow runner — drives a headful navigation loop through an IdP and
/// hands the resulting code off to a host-provided exchanger that mints a
/// concrete [BrowserAuthProfile].
///
/// See `docs/03_DDD/06-auth.md` §3.3 and `docs/04_TEST/06-auth.md` TC-417/418/419.
library;

import 'dart:async';

import '../_internal.dart';

import '../core/browser_runtime.dart';
import 'context_registry.dart';

/// Error thrown for any OAuth failure (timeout, exchange exception,
/// missing context). Maps to SDD §6.2 E4003.
class OAuthFlowError extends StateError {
  OAuthFlowError(String reason) : super('E4003 OAuthFlowFailed: $reason');
}

/// Drives a single OAuth authorization flow inside a transient browser
/// context.
class OAuthFlowRunner {

  const OAuthFlowRunner({required this.runtime, required this.contexts});
  final BrowserRuntime runtime;
  final ContextRegistry contexts;

  /// Open [authorizationUrl] in a fresh context and resolve to a
  /// [BrowserAuthProfile] minted by [exchange] when the redirect URL
  /// matches [redirectMatcher].
  Future<BrowserAuthProfile> run({
    required String tenantId,
    required String profileId,
    required String authorizationUrl,
    required RegExp redirectMatcher,
    required Future<BrowserAuthProfile> Function(String code) exchange,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final handle = await contexts.acquire(
      BrowserContextSpec(tenantId: tenantId, actorId: profileId),
    );
    final completer = Completer<BrowserAuthProfile>();
    StreamSubscription<BrowserEvent>? sub;
    try {
      sub = runtime
          .subscribe(handle.contextId, const BrowserTopic(kind: BrowserTopicKind.request))
          .listen((BrowserEvent event) {
        if (completer.isCompleted) return;
        final url = event.payload['url'] as String?;
        if (url == null) return;
        final match = redirectMatcher.firstMatch(url);
        if (match == null) return;
        final code = Uri.tryParse(url)?.queryParameters['code'];
        if (code == null) return;
        Future<void>(() async {
          try {
            final profile = await exchange(code);
            if (!completer.isCompleted) completer.complete(profile);
          } on Object catch (e) {
            if (!completer.isCompleted) {
              completer.completeError(OAuthFlowError('exchange failed: $e'));
            }
          }
        });
      });

      await runtime.execute(
        handle.contextId,
        BrowserAction.navigate(authorizationUrl),
      );

      try {
        return await completer.future.timeout(timeout);
      } on TimeoutException {
        throw OAuthFlowError('flow did not complete within $timeout');
      }
    } finally {
      await sub?.cancel();
      await contexts.close(handle.contextId);
    }
  }
}
