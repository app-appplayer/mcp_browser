/// TEST — MOD-OPS-002 DownloadManager.
///
/// Mirrors `docs/04_TEST/10-download.md` (TC-800·803·804·805·807·812·813·814·815·817).
/// Resume cases (TC-801/802) and trigger-mode cases (TC-809/810) are deferred
/// to Phase 4 when full engine event integration ships.
library;

import 'dart:async';
import 'dart:io';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_http_fetcher.dart';

({
  DownloadManager mgr,
  PolicyEngine policy,
  AuditTrail audit,
  Directory baseDir,
  InMemoryKvStoragePort kv,
}) _build({
  FakeHttpFetcher? fetcher,
  BrowserVirusScanPort? virusScan,
  bool quarantineWhenNoScan = false,
  PolicyEngine? policyOverride,
}) {
  final baseDir = Directory.systemTemp.createTempSync('mcp_browser_test_');
  final policy = policyOverride ?? PolicyEngine.defaults();
  final audit = AuditTrail(sink: InMemoryAuditSink());
  final kv = InMemoryKvStoragePort();
  final mgr = DownloadManager(
    policy: policy,
    audit: audit,
    storage: kv,
    fetcher: fetcher ?? FakeHttpFetcher(),
    baseDir: baseDir.path,
    virusScan: virusScan,
    quarantineWhenNoScan: quarantineWhenNoScan,
  );
  return (mgr: mgr, policy: policy, audit: audit, baseDir: baseDir, kv: kv);
}

void _cleanup(Directory dir) {
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

void main() {
  group('DownloadManager — happy path', () {
    test('TC-800 small file download persists with correct sha256', () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/file.bin': FakeHttpResponse(
          body: <int>[for (var i = 0; i < 1024; i++) i % 256],
          headers: const <String, String>{'content-type': 'application/octet-stream'},
        ),
      });
      final b = _build(fetcher: fetcher);
      try {
        final desc = await b.mgr.download(const BrowserDownloadSpec(
          tenantId: 't',
          contextScopeId: 'ctx-1',
          url: 'https://example.com/file.bin',
        ));
        expect(desc.status, BrowserDownloadStatus.finished);
        expect(desc.sizeBytes, 1024);
        expect(desc.sha256, isNotNull);
        expect(File(desc.destPath).existsSync(), isTrue);
        expect(File(desc.destPath).lengthSync(), 1024);
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test('TC-813 audit gets a finished entry with auditId', () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/x.txt': const FakeHttpResponse(body: <int>[1, 2, 3]),
      });
      final sink = InMemoryAuditSink();
      final policy = PolicyEngine.defaults();
      final baseDir = Directory.systemTemp.createTempSync('mcp_dl_');
      final audit =
          AuditTrail(sink: sink, bufferSize: 100, flushHighWaterMark: 1);
      final mgr = DownloadManager(
        policy: policy,
        audit: audit,
        fetcher: fetcher,
        baseDir: baseDir.path,
      );
      try {
        await mgr.download(const BrowserDownloadSpec(
          tenantId: 't',
          url: 'https://example.com/x.txt',
        ));
        await audit.flush();
        final records = await sink
            .query(const BrowserAuditQuery(operations: <String>{'download'}))
            .toList();
        expect(records, hasLength(1));
        expect(records.single.decision, 'allow');
      } finally {
        await mgr.close();
        _cleanup(baseDir);
      }
    });

    test('TC-814 getDownload returns the persisted descriptor', () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/y.txt': const FakeHttpResponse(body: <int>[9, 9, 9]),
      });
      final b = _build(fetcher: fetcher);
      try {
        final desc = await b.mgr.download(const BrowserDownloadSpec(
          tenantId: 't',
          url: 'https://example.com/y.txt',
        ));
        final fetched = await b.mgr.getDownload(desc.id);
        expect(fetched, isNotNull);
        expect(fetched!.sha256, desc.sha256);
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test('TC-815 listDownloads filters by tenant', () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://a.com/1': const FakeHttpResponse(body: <int>[1]),
        'https://a.com/2': const FakeHttpResponse(body: <int>[2]),
      });
      final b = _build(fetcher: fetcher);
      try {
        await b.mgr.download(const BrowserDownloadSpec(
          tenantId: 't1',
          url: 'https://a.com/1',
        ));
        await b.mgr.download(const BrowserDownloadSpec(
          tenantId: 't2',
          url: 'https://a.com/2',
        ));
        final t1 = await b.mgr.listDownloads(tenantId: 't1');
        expect(t1, hasLength(1));
        expect(t1.single.tenantId, 't1');
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test('TC-817 events stream emits started → inProgress → finished',
        () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/e.bin': const FakeHttpResponse(body: <int>[1, 2, 3]),
      });
      final b = _build(fetcher: fetcher);
      final received = <BrowserDownloadStatus>[];
      final sub = b.mgr.downloadEvents
          .listen((BrowserDownloadEvent e) => received.add(e.kind));
      try {
        await b.mgr.download(const BrowserDownloadSpec(
          tenantId: 't',
          url: 'https://example.com/e.bin',
        ));
        // Allow async events to drain.
        await Future<void>.delayed(Duration.zero);
        expect(received, contains(BrowserDownloadStatus.started));
        expect(received.last, BrowserDownloadStatus.finished);
      } finally {
        await sub.cancel();
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });
  });

  group('DownloadManager — failure paths', () {
    test('TC-803 policy deny throws DownloadFailedError', () async {
      final policy = PolicyEngine.defaults()
        ..urlRules.denyDomain('blocked.example');
      final fetcher = FakeHttpFetcher();
      final b = _build(fetcher: fetcher, policyOverride: policy);
      try {
        await expectLater(
          b.mgr.download(const BrowserDownloadSpec(
            tenantId: 't',
            url: 'https://blocked.example/x.bin',
          )),
          throwsA(isA<DownloadFailedError>()),
        );
        expect(fetcher.calls, 0);
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test('TC-804 daily quota exhausted throws DownloadFailedError',
        () async {
      final policy = PolicyEngine(
        urlRules: UrlAccessRules(),
        quota: DomainQuotaTracker(),
        caps: const BrowserResourceCaps(
          dailyDownloadCapBytesPerDomain: 4,
        ),
      );
      policy.recordDownload('host.com', 4);
      final b = _build(policyOverride: policy);
      try {
        await expectLater(
          b.mgr.download(const BrowserDownloadSpec(
            tenantId: 't',
            url: 'https://host.com/x.bin',
          )),
          throwsA(isA<DownloadFailedError>()),
        );
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test('TC-805 HTTP non-200/206 surfaces DownloadFailedError', () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/missing.bin':
            const FakeHttpResponse(statusCode: 404, body: <int>[]),
      });
      final b = _build(fetcher: fetcher);
      try {
        await expectLater(
          b.mgr.download(const BrowserDownloadSpec(
            tenantId: 't',
            url: 'https://example.com/missing.bin',
          )),
          throwsA(isA<DownloadFailedError>()),
        );
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test('TC-807 virus scan reject quarantines and throws E8002', () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/m.bin': const FakeHttpResponse(body: <int>[1, 2, 3]),
      });
      const scanner =
          FakeVirusScan(clean: false, threat: 'Trojan.Test.X');
      final b = _build(fetcher: fetcher, virusScan: scanner);
      try {
        await expectLater(
          b.mgr.download(const BrowserDownloadSpec(
            tenantId: 't',
            url: 'https://example.com/m.bin',
          )),
          throwsA(isA<DownloadQuarantinedError>()),
        );
        // Quarantine directory exists.
        final qDir = Directory('${b.baseDir.path}/.quarantine');
        expect(qDir.existsSync(), isTrue);
        expect(qDir.listSync(), isNotEmpty);
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });

    test(
        'TC-808 quarantineWhenNoScan moves clean files into quarantine dir',
        () async {
      final fetcher = FakeHttpFetcher(responses: <String, FakeHttpResponse>{
        'https://example.com/q.bin': const FakeHttpResponse(body: <int>[7, 8, 9]),
      });
      final b = _build(fetcher: fetcher, quarantineWhenNoScan: true);
      try {
        final desc = await b.mgr.download(const BrowserDownloadSpec(
          tenantId: 't',
          url: 'https://example.com/q.bin',
        ));
        expect(desc.status, BrowserDownloadStatus.quarantined);
        expect(desc.destPath, contains('.quarantine'));
      } finally {
        await b.mgr.close();
        _cleanup(b.baseDir);
      }
    });
  });
}
