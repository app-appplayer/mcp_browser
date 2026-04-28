/// BrowserPolicyPort - URL/quota/robots policy contract for mcp_browser.
///
/// Implementations evaluate every state-changing browser action and expose
/// resource caps to the runtime. The default implementation lives in the
/// mcp_browser package (`PolicyEngine`); hosts may swap in alternatives.
library;

import '../types/browser_types.dart';

/// Contract for evaluating browser actions against URL/quota/robots policy.
abstract class BrowserPolicyPort {
  /// Evaluate a state-changing browser action.
  BrowserPolicyDecision evaluate(BrowserAction action);

  /// Evaluate a single URL for a stated purpose (`navigate`/`download`/`crawl`).
  BrowserPolicyDecision evaluateUrl(String url, {required String purpose});

  /// Whether [url] is allowed by the host site's robots.txt for [userAgent].
  ///
  /// Implementations may fetch and cache robots.txt on demand. When the
  /// fetch fails the default policy is to allow (per RFC 9309 §2.3).
  Future<bool> isAllowedByRobots(String url, {required String userAgent});

  /// Active resource caps. Used by the runtime to enforce concurrency limits
  /// and other budgets without re-reading config.
  BrowserResourceCaps get resourceCaps;

  /// Convenience getter for the most frequently consulted cap.
  int get maxConcurrentContexts;

  /// Record that a request was made against [domain]. Increments per-domain
  /// counters used by quota evaluation.
  void recordRequest(String domain);

  /// Record [bytes] of downloaded content for [domain].
  void recordDownload(String domain, int bytes);
}
