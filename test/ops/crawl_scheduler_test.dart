/// TEST — MOD-OPS-001 CrawlScheduler + Frontier + Monitor.
///
/// Mirrors `docs/04_TEST/09-crawl.md` (TC-700~725).
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

/// Build a navigate callback that serves deterministic HTML per URL.
NavigateAndRead _fixedNavigator(
  Map<String, String> pages, {
  Map<String, int>? failuresBeforeSuccess,
  Set<String>? alwaysFail,
}) {
  final failures = failuresBeforeSuccess ?? <String, int>{};
  return (String url, BrowserReadSpec spec) async {
    if (alwaysFail != null && alwaysFail.contains(url)) {
      throw StateError('nav $url');
    }
    final remaining = failures[url];
    if (remaining != null && remaining > 0) {
      failures[url] = remaining - 1;
      throw StateError('transient nav $url');
    }
    final body = pages[url];
    if (body == null) throw StateError('404 $url');
    return BrowserPayloadEnvelope(
      contextId: 'nav',
      mime: 'text/html',
      body: body,
    );
  };
}

CrawlScheduler _scheduler({
  required NavigateAndRead navigate,
  BrowserPolicyPort? policy,
  void Function(BrowserPayloadEnvelope)? onIngest,
}) {
  return CrawlScheduler(
    policy: policy ?? PolicyEngine.defaults(),
    audit: AuditTrail(sink: InMemoryAuditSink()),
    navigate: navigate,
    ingest: onIngest == null
        ? null
        : (BrowserPayloadEnvelope env) async => onIngest(env),
  );
}

Future<List<BrowserCrawlProgressEvent>> _collect(
  CrawlHandle handle, {
  Duration timeout = const Duration(seconds: 2),
}) {
  return handle.progress.toList().timeout(timeout);
}

void main() {
  group('Frontier', () {
    test('TC-724 priority ordering (lower wins, ties = insertion order)', () {
      final f = Frontier(strategy: BrowserDedupStrategy.urlCanonical)
        ..enqueue('https://x.com/a', priority: 5)
        ..enqueue('https://x.com/b', priority: 1)
        ..enqueue('https://x.com/c', priority: 1);
      expect(f.dequeue()!.url, 'https://x.com/b');
      expect(f.dequeue()!.url, 'https://x.com/c');
      expect(f.dequeue()!.url, 'https://x.com/a');
    });

    test('TC-725 snapshot + restore round-trip', () {
      final original = Frontier(strategy: BrowserDedupStrategy.both)
        ..enqueue('https://x.com/a', priority: 1, depth: 1)
        ..enqueue('https://x.com/b', priority: 0, depth: 2);
      original.markSeen('hash1');
      final snap = original.snapshot();
      final restored = Frontier(strategy: BrowserDedupStrategy.both)
        ..restore(snap);
      expect(restored.dequeue()!.url, 'https://x.com/b');
      expect(restored.seen('hash1'), isTrue);
    });

    test('TC-710 canonicalization drops utm_* and fragments', () {
      final f = Frontier(strategy: BrowserDedupStrategy.urlCanonical);
      expect(
        f.enqueue('https://X.com/page?utm_source=news#top'),
        isTrue,
      );
      expect(f.enqueue('https://x.com/page?utm_campaign=alt'), isFalse,
          reason: 'should dedup after canonical strip');
      expect(f.enqueue('https://x.com/page'), isFalse);
    });
  });

  group('CrawlScheduler — core traversal', () {
    test('TC-700 single seed, depth 1, visits seed and then links',
        () async {
      final pages = <String, String>{
        'https://x.com/': '<a href="/a">A</a><a href="/b">B</a>',
        'https://x.com/a': '<p>alpha</p>',
        'https://x.com/b': '<p>beta</p>',
      };
      final scheduler = _scheduler(navigate: _fixedNavigator(pages));
      final handle = await scheduler.start(
        <String>['https://x.com/'],
        const BrowserCrawlPolicy(
          depth: 1,
          breadth: 10,
          concurrency: 1,
          respectRobots: false,
          allowedDomains: <String>['x.com'],
          ratePerDomain: 0,
        ),
      );
      final events = await _collect(handle);
      final visited = events
          .where((BrowserCrawlProgressEvent e) =>
              e.kind == BrowserCrawlEventKind.visited)
          .map((BrowserCrawlProgressEvent e) => e.url)
          .toSet();
      expect(visited, <String>{
        'https://x.com/',
        'https://x.com/a',
        'https://x.com/b',
      });
    });

    test('TC-702 depth 0 visits only the seed', () async {
      final pages = <String, String>{
        'https://x.com/': '<a href="/a">A</a>',
        'https://x.com/a': '<p>alpha</p>',
      };
      final scheduler = _scheduler(navigate: _fixedNavigator(pages));
      final handle = await scheduler.start(
        <String>['https://x.com/'],
        const BrowserCrawlPolicy(
          depth: 0,
          breadth: 10,
          concurrency: 1,
          respectRobots: false,
          ratePerDomain: 0,
        ),
      );
      final events = await _collect(handle);
      final visited = events
          .where((BrowserCrawlProgressEvent e) =>
              e.kind == BrowserCrawlEventKind.visited)
          .map((BrowserCrawlProgressEvent e) => e.url)
          .toList();
      expect(visited, <String>['https://x.com/']);
    });

    test('TC-705 invalid policy throws CrawlPolicyInvalidError', () async {
      final scheduler = _scheduler(navigate: _fixedNavigator(<String, String>{}));
      await expectLater(
        scheduler.start(
          <String>['https://x.com/'],
          const BrowserCrawlPolicy(depth: -1, respectRobots: false),
        ),
        throwsA(isA<CrawlPolicyInvalidError>()),
      );
    });

    test('TC-709 content-hash dedup skips duplicate pages', () async {
      final pages = <String, String>{
        'https://x.com/': '<a href="/a">A</a><a href="/b">B</a>',
        'https://x.com/a': '<p>same</p>',
        'https://x.com/b': '<p>same</p>',
      };
      final scheduler = _scheduler(navigate: _fixedNavigator(pages));
      final handle = await scheduler.start(
        <String>['https://x.com/'],
        const BrowserCrawlPolicy(
          depth: 1,
          breadth: 10,
          concurrency: 1,
          respectRobots: false,
          allowedDomains: <String>['x.com'],
          ratePerDomain: 0,
          dedupStrategy: BrowserDedupStrategy.both,
        ),
      );
      final events = await _collect(handle);
      final deduped = events
          .where((BrowserCrawlProgressEvent e) =>
              e.kind == BrowserCrawlEventKind.deduped)
          .toList();
      expect(deduped, hasLength(1));
    });

    test('TC-713 navigate retry recovers from transient failure', () async {
      final pages = <String, String>{'https://x.com/': '<p>ok</p>'};
      final navigator = _fixedNavigator(
        pages,
        failuresBeforeSuccess: <String, int>{'https://x.com/': 1},
      );
      final scheduler = _scheduler(navigate: navigator);
      final handle = await scheduler.start(
        <String>['https://x.com/'],
        const BrowserCrawlPolicy(
          depth: 0,
          breadth: 10,
          concurrency: 1,
          respectRobots: false,
          ratePerDomain: 0,
          maxNavigateRetries: 2,
        ),
      );
      final events = await _collect(handle);
      expect(
        events.any((BrowserCrawlProgressEvent e) =>
            e.kind == BrowserCrawlEventKind.visited),
        isTrue,
      );
    });

    test('TC-714 permanent navigate failure emits failed event', () async {
      final scheduler = _scheduler(navigate: _fixedNavigator(
        const <String, String>{},
        alwaysFail: <String>{'https://x.com/'},
      ));
      final handle = await scheduler.start(
        <String>['https://x.com/'],
        const BrowserCrawlPolicy(
          depth: 0,
          concurrency: 1,
          respectRobots: false,
          ratePerDomain: 0,
          maxNavigateRetries: 0,
        ),
      );
      final events = await _collect(handle);
      expect(
        events.single.kind,
        BrowserCrawlEventKind.failed,
      );
    });

    test('TC-715 ingest forwarder is invoked per visited page', () async {
      final pages = <String, String>{'https://x.com/': '<p>hi</p>'};
      final ingested = <String>[];
      final scheduler = _scheduler(
        navigate: _fixedNavigator(pages),
        onIngest: (BrowserPayloadEnvelope env) => ingested.add(env.mime),
      );
      final handle = await scheduler.start(
        <String>['https://x.com/'],
        const BrowserCrawlPolicy(
          depth: 0,
          respectRobots: false,
          ratePerDomain: 0,
        ),
      );
      await _collect(handle);
      expect(ingested, hasLength(1));
    });

    test('TC-718 stop terminates workers', () async {
      final pages = <String, String>{
        for (var i = 0; i < 10; i++)
          'https://x.com/$i': '<p>page $i</p>',
      };
      final scheduler = _scheduler(navigate: _fixedNavigator(pages));
      final handle = await scheduler.start(
        pages.keys.toList(),
        const BrowserCrawlPolicy(
          depth: 0,
          concurrency: 1,
          respectRobots: false,
          ratePerDomain: 0,
        ),
      );
      scheduleMicrotask(handle.stop);
      await _collect(handle);
      expect(handle.state, anyOf(BrowserCrawlState.stopped, BrowserCrawlState.completed));
    });
  });

  group('CrawlScheduler — monitor', () {
    test('TC-720/721 monitor emits changed on hash change', () async {
      final content = <String>['<p>a</p>', '<p>a</p>', '<p>b</p>'];
      var idx = 0;
      final scheduler = _scheduler(
        navigate: (String url, BrowserReadSpec spec) async {
          final body = content[idx.clamp(0, content.length - 1)];
          idx++;
          return BrowserPayloadEnvelope(mime: 'text/html', body: body);
        },
      );
      final handle =
          await scheduler.monitor('https://x.com/', const Duration(milliseconds: 50));
      final events = <BrowserMonitorEvent>[];
      final sub = handle.events.listen(events.add);
      // Wait for 3 ticks.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await handle.stop();
      await sub.cancel();
      final kinds =
          events.map((BrowserMonitorEvent e) => e.kind).toList();
      expect(kinds.first, BrowserMonitorEventKind.changed);
      expect(kinds, contains(BrowserMonitorEventKind.unchanged));
      expect(kinds, contains(BrowserMonitorEventKind.changed));
    });

    test('TC-723 monitor stop cancels the timer', () async {
      final scheduler = _scheduler(
        navigate: (String url, BrowserReadSpec spec) async =>
            BrowserPayloadEnvelope(mime: 'text/html', body: '<p>x</p>'),
      );
      final handle = await scheduler.monitor(
        'https://x.com/',
        const Duration(milliseconds: 20),
      );
      await handle.stop();
      // After stop, no new events should arrive.
      var after = 0;
      final sub = handle.events.listen((BrowserMonitorEvent _) => after++);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await sub.cancel();
      expect(after, 0);
    });
  });
}
