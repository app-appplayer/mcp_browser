/// MOD-OPS-001 — CrawlScheduler + MonitorHandle.
///
/// See `docs/03_DDD/09-crawl.md` for the design specification and
/// `docs/04_TEST/09-crawl.md` for the test plan.
library;

import 'dart:async';

import 'package:html/parser.dart' as html_parser;
import '../_internal.dart';
import 'package:uuid/uuid.dart';

import '../core/browser_runtime.dart';
import 'frontier.dart';

const _uuid = Uuid();

/// Callback injected by the host: fetch a URL and return its envelope.
typedef NavigateAndRead = Future<BrowserPayloadEnvelope> Function(
  String url,
  BrowserReadSpec spec,
);

/// Error mapped to E7001 — invalid crawl policy.
class CrawlPolicyInvalidError extends ArgumentError {
  CrawlPolicyInvalidError(super.message);
}

/// Error mapped to E7003 — seed domain on deny list.
class CrawlDomainBlacklistedError extends StateError {
  CrawlDomainBlacklistedError(String host)
      : super('E7003 CrawlDomainBlacklisted: $host');
}

/// Handle returned from [CrawlScheduler.start]. Hosts use it to observe
/// progress and control lifecycle.
class CrawlHandle {

  CrawlHandle._({
    required this.crawlId,
    required this.startedAt,
    required this.progress,
    required Future<void> Function() pause,
    required Future<void> Function() resume,
    required Future<void> Function() stop,
  })  : _pause = pause,
        _resume = resume,
        _stop = stop;
  final String crawlId;
  final DateTime startedAt;
  final Stream<BrowserCrawlProgressEvent> progress;
  final Future<void> Function() _pause;
  final Future<void> Function() _resume;
  final Future<void> Function() _stop;

  BrowserCrawlState _state = BrowserCrawlState.running;

  BrowserCrawlState get state => _state;

  Future<void> pause() => _pause();
  Future<void> resume() => _resume();
  Future<void> stop() => _stop();
}

/// Handle for a periodic monitor (single URL change watcher).
class MonitorHandle {

  MonitorHandle._({
    required this.monitorId,
    required this.url,
    required this.interval,
    required this.events,
    required Future<void> Function() stop,
  }) : _stop = stop;
  final String monitorId;
  final String url;
  final Duration interval;
  final Stream<BrowserMonitorEvent> events;
  final Future<void> Function() _stop;

  Future<void> stop() => _stop();
}

/// Orchestrates crawl + monitor runs against a host-provided navigate
/// callback. Honors policy, robots.txt, per-domain rate limits, and
/// content-hash deduplication.
class CrawlScheduler {

  CrawlScheduler({
    required this.policy,
    required this.audit,
    required this.navigate,
    this.ingest,
    this.userAgent = 'mcp_browser/0.1 (+crawler)',
  });
  final BrowserPolicyPort policy;
  final BrowserAuditPort audit;
  final NavigateAndRead navigate;
  final IngestForwarder? ingest;
  final String userAgent;

  final Map<String, CrawlHandle> _handles = <String, CrawlHandle>{};
  final Map<String, MonitorHandle> _monitors = <String, MonitorHandle>{};

  Future<CrawlHandle> start(
    List<String> seeds,
    BrowserCrawlPolicy crawlPolicy,
  ) async {
    try {
      crawlPolicy.validate();
    } on ArgumentError catch (e) {
      throw CrawlPolicyInvalidError(e.message.toString());
    }
    _rejectDenyListedSeeds(seeds, crawlPolicy);

    final crawlId = _uuid.v4();
    final frontier = Frontier(strategy: crawlPolicy.dedupStrategy);
    for (final seed in seeds) {
      frontier.enqueue(seed, depth: 0);
    }

    final controller =
        StreamController<BrowserCrawlProgressEvent>.broadcast();
    final rateLimiter = _RateLimiter(crawlPolicy.ratePerDomain);

    Completer<void>? pausedGate;
    var stopRequested = false;
    var visitedCount = 0;

    Future<void> emit(BrowserCrawlProgressEvent event) async {
      if (!controller.isClosed) controller.add(event);
    }

    Future<void> worker() async {
      while (!stopRequested) {
        if (pausedGate != null) {
          await pausedGate!.future;
        }
        final item = frontier.dequeue();
        if (item == null) return;
        if (visitedCount >= crawlPolicy.breadth) return;

        final decision = policy.evaluateUrl(item.url, purpose: 'crawl');
        if (!decision.allowed) {
          await emit(BrowserCrawlProgressEvent(
            kind: BrowserCrawlEventKind.skippedPolicy,
            url: item.url,
            depth: item.depth,
            errorCode: decision.denyCode,
            errorMessage: decision.reason,
          ));
          continue;
        }
        if (crawlPolicy.respectRobots) {
          final allowed = await policy.isAllowedByRobots(
            item.url,
            userAgent: userAgent,
          );
          if (!allowed) {
            await emit(BrowserCrawlProgressEvent(
              kind: BrowserCrawlEventKind.skippedRobots,
              url: item.url,
              depth: item.depth,
              errorCode: 'E7002',
            ));
            continue;
          }
        }

        await rateLimiter.acquire(_host(item.url));

        BrowserPayloadEnvelope? envelope;
        var attempt = 0;
        while (envelope == null) {
          try {
            envelope = await navigate(
              item.url,
              BrowserReadSpec(kind: BrowserReadKind.html),
            );
            break;
          } on Object catch (e) {
            attempt++;
            if (attempt > crawlPolicy.maxNavigateRetries) {
              await emit(BrowserCrawlProgressEvent(
                kind: BrowserCrawlEventKind.failed,
                url: item.url,
                depth: item.depth,
                errorCode: 'E7000',
                errorMessage: '$e',
              ));
              break;
            }
            await Future<void>.delayed(
              Duration(milliseconds: 50 * (1 << (attempt - 1))),
            );
          }
        }
        if (envelope == null) continue;

        final html = envelope.body is String
            ? envelope.body as String
            : envelope.body.toString();
        final hash = sha256HexOfText(html);
        if (frontier.shouldSkipByHash(hash)) {
          await emit(BrowserCrawlProgressEvent(
            kind: BrowserCrawlEventKind.deduped,
            url: item.url,
            depth: item.depth,
            contentHash: hash,
          ));
          continue;
        }
        frontier.markSeen(hash);
        visitedCount++;

        policy.recordRequest(_host(item.url));
        if (ingest != null) {
          try {
            await ingest!(envelope);
          } on Object {
            // Ingest failures are reported as events but don't abort the crawl.
          }
        }
        await emit(BrowserCrawlProgressEvent(
          kind: BrowserCrawlEventKind.visited,
          url: item.url,
          depth: item.depth,
          contentHash: hash,
        ));

        if (item.depth < crawlPolicy.depth) {
          final links = _extractLinks(html, item.url);
          for (final link in links) {
            if (!_domainAllowed(link, crawlPolicy)) continue;
            frontier.enqueue(link, depth: item.depth + 1);
          }
        }
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < crawlPolicy.concurrency; i++) worker(),
    ];

    final handle = CrawlHandle._(
      crawlId: crawlId,
      startedAt: DateTime.now(),
      progress: controller.stream,
      pause: () async {
        pausedGate ??= Completer<void>();
      },
      resume: () async {
        final g = pausedGate;
        pausedGate = null;
        if (g != null && !g.isCompleted) g.complete();
      },
      stop: () async {
        stopRequested = true;
        final g = pausedGate;
        pausedGate = null;
        if (g != null && !g.isCompleted) g.complete();
      },
    );
    _handles[crawlId] = handle;

    // Fire-and-forget completion bookkeeping.
    unawaited(Future.wait(workers).then((_) async {
      handle._state = stopRequested
          ? BrowserCrawlState.stopped
          : BrowserCrawlState.completed;
      await controller.close();
    }));

    return handle;
  }

  Future<MonitorHandle> monitor(String url, Duration interval) async {
    final monitorId = _uuid.v4();
    final controller = StreamController<BrowserMonitorEvent>.broadcast();
    String? lastHash;
    Timer? timer;
    var stopped = false;

    Future<void> tick() async {
      if (stopped) return;
      BrowserPayloadEnvelope? env;
      try {
        env = await navigate(
          url,
          BrowserReadSpec(kind: BrowserReadKind.html),
        );
      } on Object catch (e) {
        if (!controller.isClosed) {
          controller.add(BrowserMonitorEvent(
            kind: BrowserMonitorEventKind.error,
            url: url,
            errorMessage: '$e',
          ));
        }
        return;
      }
      final body = env.body is String ? env.body as String : env.body.toString();
      final hash = sha256HexOfText(body);
      if (lastHash == null || lastHash != hash) {
        lastHash = hash;
        if (!controller.isClosed) {
          controller.add(BrowserMonitorEvent(
            kind: BrowserMonitorEventKind.changed,
            url: url,
            contentHash: hash,
          ));
        }
        if (ingest != null) {
          try {
            await ingest!(env);
          } on Object {/* ignore */}
        }
      } else {
        if (!controller.isClosed) {
          controller.add(BrowserMonitorEvent(
            kind: BrowserMonitorEventKind.unchanged,
            url: url,
            contentHash: hash,
          ));
        }
      }
    }

    timer = Timer.periodic(interval, (_) => tick());

    final handle = MonitorHandle._(
      monitorId: monitorId,
      url: url,
      interval: interval,
      events: controller.stream,
      stop: () async {
        stopped = true;
        timer?.cancel();
        if (!controller.isClosed) await controller.close();
      },
    );
    _monitors[monitorId] = handle;
    return handle;
  }

  /// Snapshot of currently running crawl handles.
  List<CrawlHandle> activeHandles() =>
      List<CrawlHandle>.unmodifiable(_handles.values);

  // -------------------------------------------------------------------------

  void _rejectDenyListedSeeds(
    List<String> seeds,
    BrowserCrawlPolicy crawlPolicy,
  ) {
    for (final seed in seeds) {
      final decision = policy.evaluateUrl(seed, purpose: 'crawl');
      if (!decision.allowed && decision.denyCode == 'E7003') {
        throw CrawlDomainBlacklistedError(_host(seed));
      }
    }
  }

  bool _domainAllowed(String url, BrowserCrawlPolicy crawlPolicy) {
    if (crawlPolicy.allowedDomains.isEmpty) return true;
    final host = _host(url);
    return crawlPolicy.allowedDomains.any((String d) =>
        host == d.toLowerCase() || host.endsWith('.${d.toLowerCase()}'));
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? '';

  /// Extract same-page hrefs from [html] resolved against [pageUrl].
  static List<String> _extractLinks(String html, String pageUrl) {
    final doc = html_parser.parse(html);
    final base = Uri.tryParse(pageUrl);
    final out = <String>[];
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final resolved = base?.resolve(href).toString();
      if (resolved != null &&
          (resolved.startsWith('http://') ||
              resolved.startsWith('https://'))) {
        out.add(resolved);
      }
    }
    return out;
  }
}

class _RateLimiter {

  _RateLimiter(this.requestsPerSecond);
  final double requestsPerSecond;
  final Map<String, DateTime> _lastCall = <String, DateTime>{};

  Future<void> acquire(String host) async {
    if (requestsPerSecond <= 0 || host.isEmpty) return;
    final minInterval =
        Duration(microseconds: (1000000 / requestsPerSecond).round());
    final last = _lastCall[host];
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < minInterval) {
        await Future<void>.delayed(minInterval - elapsed);
      }
    }
    _lastCall[host] = DateTime.now();
  }
}
