/// MOD-POL-001 — PolicyEngine implementation.
///
/// See `docs/03_DDD/04-policy.md` for the design specification and
/// `docs/04_TEST/04-policy.md` for the test plan.
library;

import '../_internal.dart';

// ---------------------------------------------------------------------------
// URL access rules
// ---------------------------------------------------------------------------

/// URL allow/deny rules. When the allow list is empty, the default is to
/// allow all URLs not matched by deny rules. When non-empty, the default is
/// to deny anything not matched by an allow rule.
class UrlAccessRules {
  final Set<String> _allowDomains = <String>{};
  final List<RegExp> _allowPatterns = <RegExp>[];
  final Set<String> _denyDomains = <String>{};
  final List<RegExp> _denyPatterns = <RegExp>[];

  /// Allow exact host or any subdomain of [domain].
  void allowDomain(String domain) => _allowDomains.add(domain.toLowerCase());

  /// Allow any URL matching [pattern].
  void allowPattern(String pattern) => _allowPatterns.add(RegExp(pattern));

  /// Deny exact host or any subdomain of [domain].
  void denyDomain(String domain) => _denyDomains.add(domain.toLowerCase());

  /// Deny any URL matching [pattern].
  void denyPattern(String pattern) => _denyPatterns.add(RegExp(pattern));

  /// Whether [url] is allowed under the current rule set.
  bool isAllowed(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (_matchesDomain(host, _denyDomains)) return false;
    for (final p in _denyPatterns) {
      if (p.hasMatch(url)) return false;
    }
    final hasAllowList =
        _allowDomains.isNotEmpty || _allowPatterns.isNotEmpty;
    if (!hasAllowList) return true;
    if (_matchesDomain(host, _allowDomains)) return true;
    for (final p in _allowPatterns) {
      if (p.hasMatch(url)) return true;
    }
    return false;
  }

  bool _matchesDomain(String host, Set<String> set) {
    if (set.contains(host)) return true;
    // Subdomain match: longest match wins, but for boolean "matches" any wins.
    for (final d in set) {
      if (host.endsWith('.$d')) return true;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Domain quota tracker
// ---------------------------------------------------------------------------

/// Tracks per-domain request count and download volume per UTC day.
class DomainQuotaTracker {

  DomainQuotaTracker({DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final Map<String, _DailyCounters> _byDomain = <String, _DailyCounters>{};

  /// Number of requests recorded for [domain] today.
  int requestsToday(String domain) =>
      _ensureToday(domain.toLowerCase()).requests;

  /// Bytes downloaded against [domain] today.
  int downloadBytesToday(String domain) =>
      _ensureToday(domain.toLowerCase()).downloadBytes;

  /// Increment counters for [domain].
  void increment(String domain, {int requests = 0, int downloadBytes = 0}) {
    final c = _ensureToday(domain.toLowerCase());
    c.requests += requests;
    c.downloadBytes += downloadBytes;
  }

  _DailyCounters _ensureToday(String domain) {
    final today = _utcDay(_now());
    final existing = _byDomain[domain];
    if (existing != null && existing.day == today) return existing;
    final fresh = _DailyCounters(day: today);
    _byDomain[domain] = fresh;
    return fresh;
  }

  static String _utcDay(DateTime t) {
    final u = t.toUtc();
    return '${u.year.toString().padLeft(4, '0')}-'
        '${u.month.toString().padLeft(2, '0')}-'
        '${u.day.toString().padLeft(2, '0')}';
  }
}

class _DailyCounters {
  _DailyCounters({required this.day});
  final String day;
  int requests = 0;
  int downloadBytes = 0;
}

// ---------------------------------------------------------------------------
// Robots cache (port; default fetcher is HTTP-based, supplied by host)
// ---------------------------------------------------------------------------

/// Parsed view of a robots.txt for a single origin.
class RobotsTxt {

  RobotsTxt._({required Map<String, List<_RobotsRule>> byAgent, required this.fetchedAt})
      : _byAgent = byAgent;

  /// Parse a `robots.txt` body.
  factory RobotsTxt.parse(String body, {DateTime? fetchedAt}) {
    final byAgent = <String, List<_RobotsRule>>{};
    var currentAgent = '*';
    final lines = body.split(RegExp(r'\r?\n'));
    for (final raw in lines) {
      final line = _stripComment(raw).trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      if (key == 'user-agent') {
        currentAgent = value.toLowerCase();
        byAgent.putIfAbsent(currentAgent, () => <_RobotsRule>[]);
      } else if (key == 'allow' || key == 'disallow') {
        byAgent
            .putIfAbsent(currentAgent, () => <_RobotsRule>[])
            .add(_RobotsRule(allow: key == 'allow', path: value));
      }
    }
    return RobotsTxt._(byAgent: byAgent, fetchedAt: fetchedAt ?? DateTime.now());
  }
  /// Map of (lowercased) UA → ordered list of (`allow`/`disallow`, path) rules.
  final Map<String, List<_RobotsRule>> _byAgent;

  /// Time at which this representation was fetched. Used for TTL eviction.
  final DateTime fetchedAt;

  /// Whether [path] is allowed for [userAgent] (which may be an exact match
  /// or fall through to `*`). Longest matching rule wins; ties prefer allow.
  bool isAllowed(String path, String userAgent) {
    final ua = userAgent.toLowerCase();
    final rules = _byAgent[ua] ?? _byAgent['*'] ?? const <_RobotsRule>[];
    if (rules.isEmpty) return true;
    var bestLen = -1;
    var bestAllow = true;
    for (final r in rules) {
      if (r.path.isEmpty) {
        // An empty Disallow value means "allow all" per RFC.
        if (!r.allow && bestLen < 0) bestAllow = true;
        continue;
      }
      if (path.startsWith(r.path)) {
        if (r.path.length > bestLen) {
          bestLen = r.path.length;
          bestAllow = r.allow;
        } else if (r.path.length == bestLen && r.allow) {
          bestAllow = true;
        }
      }
    }
    return bestLen < 0 ? true : bestAllow;
  }

  static String _stripComment(String line) {
    final hash = line.indexOf('#');
    return hash < 0 ? line : line.substring(0, hash);
  }
}

class _RobotsRule {
  const _RobotsRule({required this.allow, required this.path});
  final bool allow;
  final String path;
}

/// Fetcher contract for robots.txt. Hosts provide an HTTP-backed
/// implementation; tests pass a fake.
abstract class RobotsFetcher {
  /// Fetch the body of `<origin>/robots.txt`, returning `null` if not found
  /// or if the network call fails.
  Future<String?> fetch(String origin);
}

/// Time-bounded cache for robots.txt per origin.
class RobotsCache {

  RobotsCache({
    required this.fetcher,
    this.ttl = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final RobotsFetcher fetcher;
  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, _RobotsCacheEntry> _entries = <String, _RobotsCacheEntry>{};

  /// Return the cached or freshly fetched robots.txt for [origin], or
  /// `null` if the host is missing/empty/unreachable.
  Future<RobotsTxt?> get(String origin) async {
    final key = origin.toLowerCase();
    final hit = _entries[key];
    final now = _now();
    if (hit != null && now.difference(hit.fetchedAt) < ttl) {
      return hit.robots;
    }
    String? body;
    try {
      body = await fetcher.fetch(origin);
    } on Object {
      body = null;
    }
    if (body == null) {
      _entries[key] = _RobotsCacheEntry(robots: null, fetchedAt: now);
      return null;
    }
    final parsed = RobotsTxt.parse(body, fetchedAt: now);
    _entries[key] = _RobotsCacheEntry(robots: parsed, fetchedAt: now);
    return parsed;
  }

  /// Whether [url] is allowed for [userAgent] under the cached robots.txt
  /// for the URL's origin. Missing/unreachable robots.txt allows by default
  /// per RFC 9309 §2.3.
  Future<bool> isAllowed(String url, String userAgent) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final origin = '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}';
    final robots = await get(origin);
    if (robots == null) return true;
    final path = uri.path.isEmpty ? '/' : uri.path;
    return robots.isAllowed(path, userAgent);
  }
}

class _RobotsCacheEntry {
  _RobotsCacheEntry({required this.robots, required this.fetchedAt});
  final RobotsTxt? robots;
  final DateTime fetchedAt;
}

// ---------------------------------------------------------------------------
// Reputation port (optional)
// ---------------------------------------------------------------------------

/// Optional reputation/safety lookup. Hosts may wire in URLhaus, VirusTotal,
/// or similar.
abstract class ReputationPort {
  Future<bool> isSafe(String url);
}

// ---------------------------------------------------------------------------
// Policy engine — implements BrowserPolicyPort
// ---------------------------------------------------------------------------

/// PolicyEngine evaluates state-changing actions against URL rules, domain
/// quotas, resource caps, optional reputation lookups, and (for crawl)
/// robots.txt.
class PolicyEngine implements BrowserPolicyPort {

  PolicyEngine({
    required this.urlRules,
    required this.quota,
    BrowserResourceCaps caps = const BrowserResourceCaps(),
    this.robots,
    this.reputation,
  }) : _caps = caps;

  /// Build a default engine with empty rules and standard caps.
  factory PolicyEngine.defaults({
    RobotsCache? robots,
    ReputationPort? reputation,
    DateTime Function()? now,
  }) {
    return PolicyEngine(
      urlRules: UrlAccessRules(),
      quota: DomainQuotaTracker(now: now),
      caps: const BrowserResourceCaps(),
      robots: robots,
      reputation: reputation,
    );
  }
  final UrlAccessRules urlRules;
  final DomainQuotaTracker quota;
  final RobotsCache? robots;
  final ReputationPort? reputation;
  BrowserResourceCaps _caps;

  @override
  BrowserResourceCaps get resourceCaps => _caps;

  /// Replace the active caps. Hosts may swap caps at runtime.
  set resourceCaps(BrowserResourceCaps value) => _caps = value;

  @override
  int get maxConcurrentContexts => _caps.maxConcurrentContexts;

  @override
  BrowserPolicyDecision evaluate(BrowserAction action) {
    switch (action.kind) {
      case BrowserActionKind.navigate:
      case BrowserActionKind.intercept:
        return _evaluateUrlOrDeny(
          _readUrl(action),
          purpose: action.kind.name,
        );
      case BrowserActionKind.download:
        return _evaluateDownload(_readUrl(action));
      case BrowserActionKind.crawl:
        // Per-page robots/url checks are deferred to the scheduler; here we
        // only validate the domain list when supplied.
        final allowed = (action.params['policy'] as Map?)?['allowedDomains'];
        if (allowed is List) {
          for (final d in allowed) {
            final host = d.toString();
            if (urlRules._denyDomains
                .contains(host.toLowerCase())) {
              return BrowserPolicyDecision.deny(
                'E7003',
                'crawl seed domain on deny list: $host',
              );
            }
          }
        }
        return BrowserPolicyDecision.allow;
      case BrowserActionKind.evalJs:
        if (!_caps.allowEval) {
          return BrowserPolicyDecision.deny(
            'E2001',
            'eval(js) is disabled by resource caps',
          );
        }
        return BrowserPolicyDecision.allow;
      default:
        return BrowserPolicyDecision.allow;
    }
  }

  @override
  BrowserPolicyDecision evaluateUrl(String url, {required String purpose}) {
    return _evaluateUrlOrDeny(url, purpose: purpose);
  }

  @override
  Future<bool> isAllowedByRobots(String url,
      {required String userAgent}) async {
    if (robots == null) return true;
    return robots!.isAllowed(url, userAgent);
  }

  @override
  void recordRequest(String domain) =>
      quota.increment(domain, requests: 1);

  @override
  void recordDownload(String domain, int bytes) =>
      quota.increment(domain, downloadBytes: bytes);

  // -------------------------------------------------------------------------

  String _readUrl(BrowserAction action) {
    final value = action.params['url'];
    if (value is! String || value.isEmpty) {
      throw ArgumentError(
        'BrowserAction(${action.kind.name}) missing required `url` param',
      );
    }
    return value;
  }

  BrowserPolicyDecision _evaluateUrlOrDeny(
    String url, {
    required String purpose,
  }) {
    if (!urlRules.isAllowed(url)) {
      return BrowserPolicyDecision.deny('E2001', 'URL deny ($purpose)');
    }
    final domain = Uri.tryParse(url)?.host;
    if (domain == null || domain.isEmpty) {
      return BrowserPolicyDecision.deny('E2001', 'invalid URL ($purpose)');
    }
    if (_exceedsRequestQuota(domain)) {
      return BrowserPolicyDecision.deny(
        'E2002',
        'domain request quota exceeded: $domain',
      );
    }
    return BrowserPolicyDecision.allow;
  }

  BrowserPolicyDecision _evaluateDownload(String url) {
    final base = _evaluateUrlOrDeny(url, purpose: 'download');
    if (!base.allowed) return base;
    final domain = Uri.parse(url).host;
    if (quota.downloadBytesToday(domain) >=
        _caps.dailyDownloadCapBytesPerDomain) {
      return BrowserPolicyDecision.deny(
        'E8003',
        'daily download quota exceeded: $domain',
      );
    }
    return BrowserPolicyDecision.allow;
  }

  bool _exceedsRequestQuota(String domain) {
    // Default: no per-domain numeric cap. Hosts may enforce by overriding
    // [resourceCaps] semantics. Reserved for future per-domain quota config.
    return false;
  }
}
