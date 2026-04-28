/// TEST — MOD-POL-002 AuditTrail.
///
/// Mirrors `docs/04_TEST/05-audit.md` (TC-300~317, IT-030~033).
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

class _FlakySink implements BrowserAuditSink {

  _FlakySink({this.failuresBeforeSuccess = 0});
  final InMemoryAuditSink delegate = InMemoryAuditSink();
  int writeAttempts = 0;
  int failuresBeforeSuccess;
  bool throwOnFlush = false;

  @override
  Future<void> write(BrowserAuditRecord record) async {
    writeAttempts++;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('flaky write');
    }
    await delegate.write(record);
  }

  @override
  Future<void> flush() async {
    if (throwOnFlush) throw StateError('flaky flush');
    await delegate.flush();
  }

  @override
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter) =>
      delegate.query(filter);

  @override
  Future<void> close() => delegate.close();
}

class _AlwaysFailSink implements BrowserAuditSink {
  int attempts = 0;

  @override
  Future<void> write(BrowserAuditRecord record) async {
    attempts++;
    throw StateError('persistent failure');
  }

  @override
  Future<void> flush() async {}

  @override
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter) =>
      const Stream<BrowserAuditRecord>.empty();

  @override
  Future<void> close() async {}
}

AuditTrail _newTrail({BrowserAuditSink? sink, int? buffer, int? hwm}) {
  return AuditTrail(
    sink: sink ?? InMemoryAuditSink(),
    bufferSize: buffer ?? 10000,
    flushHighWaterMark: hwm,
  );
}

void main() {
  group('AuditTrail — record', () {
    test('TC-300 recordRead enqueues a single record', () async {
      final sink = InMemoryAuditSink();
      final trail = _newTrail(sink: sink, hwm: 10);
      await trail.recordRead(
        'ctx-1',
        BrowserReadSpec.text(selector: 'main'),
        <String, dynamic>{'mime': 'text/plain'},
      );
      expect(trail.buffered, hasLength(1));
      expect(trail.buffered.first.type, BrowserAuditEntryType.read);
      expect(trail.buffered.first.operation, 'text');
    });

    test('TC-301 recordExecute on allow', () async {
      final trail = _newTrail(hwm: 10);
      final action = BrowserAction.navigate('https://x.com');
      await trail.recordExecute(
        'ctx-1',
        action,
        const BrowserActionResult(success: true),
        BrowserPolicyDecision.allow,
      );
      expect(trail.buffered.single.decision, 'allow');
    });

    test('TC-302 recordExecute on deny carries deny code', () async {
      final trail = _newTrail(hwm: 10);
      final action = BrowserAction.navigate('https://blocked.example/');
      await trail.recordExecute(
        'ctx-1',
        action,
        const BrowserActionResult(
          success: false,
          errorCode: 'E2001',
          errorMessage: 'URL deny',
        ),
        BrowserPolicyDecision.deny('E2001', 'URL deny'),
      );
      expect(trail.buffered.single.decision, 'E2001');
      expect(trail.buffered.single.errorCode, 'E2001');
    });

    test('TC-303 recordExecute redacts sensitive param keys', () async {
      final trail = _newTrail(hwm: 10);
      final action = BrowserAction(
        kind: BrowserActionKind.setAuth,
        params: <String, dynamic>{
          'cookies': <Map<String, String>>[
            <String, String>{'name': 'sid', 'value': 'topsecret'}
          ],
          'note': 'context-only',
        },
      );
      await trail.recordExecute(
        'ctx-1',
        action,
        const BrowserActionResult(success: true),
        BrowserPolicyDecision.allow,
      );
      final params = trail.buffered.single.params;
      expect(params['cookies'], '<redacted:cookies>');
      expect(params['note'], 'context-only');
      expect(trail.buffered.single.redactedFields, contains('cookies'));
    });

    test('TC-304 recordExecute redacts Authorization header', () async {
      final trail = _newTrail(hwm: 10);
      final action = BrowserAction(
        kind: BrowserActionKind.intercept,
        params: <String, dynamic>{
          'url': 'https://api.example.com',
          'headers': <String, String>{
            'Authorization': 'Bearer eyJabcdefghijklmnop123456',
            'X-Trace': 'trace-1',
          },
        },
      );
      await trail.recordExecute(
        'ctx-1',
        action,
        const BrowserActionResult(success: true),
        BrowserPolicyDecision.allow,
      );
      final headers =
          trail.buffered.single.params['headers'] as Map<String, dynamic>;
      expect(headers['Authorization'], '<redacted:header>');
      expect(headers['X-Trace'], 'trace-1');
    });

    test('TC-305 bearer regex match in body string is redacted', () async {
      final trail = _newTrail(hwm: 10);
      final action = BrowserAction(
        kind: BrowserActionKind.evalJs,
        params: <String, dynamic>{
          'expression': 'Bearer eyJxyzxyzxyzxyzxyz1234567',
        },
      );
      await trail.recordExecute(
        'ctx-1',
        action,
        const BrowserActionResult(success: true),
        BrowserPolicyDecision.allow,
      );
      expect(trail.buffered.single.params['expression'], '<redacted:match>');
    });
  });

  group('AuditTrail — flush', () {
    test('TC-306 flush writes buffered records to sink', () async {
      final sink = InMemoryAuditSink();
      final trail = _newTrail(sink: sink, hwm: 10000);
      for (var i = 0; i < 5; i++) {
        await trail.recordRead(
          'ctx-$i',
          BrowserReadSpec.text(),
          const <String, dynamic>{},
        );
      }
      await trail.flush();
      expect(sink.records, hasLength(5));
      expect(trail.buffered, isEmpty);
    });

    test('TC-307 sink failure retries up to maxSinkRetries then drops',
        () async {
      final sink = _AlwaysFailSink();
      final trail = AuditTrail(
        sink: sink,
        bufferSize: 100,
        flushHighWaterMark: 100,
        maxSinkRetries: 3,
      );
      await trail.recordRead(
        'ctx-1',
        BrowserReadSpec.text(),
        const <String, dynamic>{},
      );
      await trail.flush();
      expect(sink.attempts, 3);
      expect(trail.dropped, 1);
      expect(trail.buffered, isEmpty);
    });

    test('TC-308 partial sink failure keeps successful records flushed',
        () async {
      final sink = _FlakySink(failuresBeforeSuccess: 2);
      final trail = AuditTrail(
        sink: sink,
        flushHighWaterMark: 100,
        maxSinkRetries: 5,
      );
      for (var i = 0; i < 3; i++) {
        await trail.recordRead(
          'ctx-$i',
          BrowserReadSpec.text(),
          const <String, dynamic>{},
        );
      }
      await trail.flush();
      expect(sink.delegate.records, hasLength(3));
    });
  });

  group('AuditTrail — buffer', () {
    test('TC-309 buffer overflow drops oldest record', () async {
      final trail = _newTrail(buffer: 3, hwm: 100);
      for (var i = 0; i < 5; i++) {
        await trail.recordRead(
          'ctx-$i',
          BrowserReadSpec.text(),
          const <String, dynamic>{},
        );
      }
      expect(trail.buffered, hasLength(3));
      expect(trail.dropped, 2);
    });

    test('TC-315 high water mark triggers flush', () async {
      final sink = InMemoryAuditSink();
      final trail = _newTrail(sink: sink, buffer: 100, hwm: 3);
      for (var i = 0; i < 3; i++) {
        await trail.recordRead(
          'ctx-$i',
          BrowserReadSpec.text(),
          const <String, dynamic>{},
        );
      }
      // Allow microtask scheduled by unawaited(flush()) to run.
      await Future<void>.delayed(Duration.zero);
      expect(sink.records, hasLength(3));
    });
  });

  group('AuditTrail — query', () {
    test('TC-311 query filters by since', () async {
      final sink = InMemoryAuditSink();
      final trail = _newTrail(sink: sink, hwm: 100);
      final cutoff = DateTime.now().add(const Duration(milliseconds: 50));
      await trail.recordRead(
        'ctx-A',
        BrowserReadSpec.text(),
        const <String, dynamic>{},
      );
      await trail.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await trail.recordRead(
        'ctx-B',
        BrowserReadSpec.text(),
        const <String, dynamic>{},
      );
      await trail.flush();

      final hits = await trail
          .query(BrowserAuditQuery(since: cutoff))
          .toList();
      expect(hits.map((BrowserAuditRecord r) => r.contextId), <String>['ctx-B']);
    });

    test('TC-312 query filters by actor (via context-derived field)',
        () async {
      final sink = InMemoryAuditSink();
      final trail = _newTrail(sink: sink, hwm: 100);
      // Inject pre-populated records to exercise the filter logic; trail's
      // internal recordRead/Execute do not currently denormalize actor.
      await sink.write(BrowserAuditRecord(
        id: '1',
        type: BrowserAuditEntryType.read,
        contextId: 'ctx-A',
        actor: 'a@x',
        operation: 'text',
        params: const <String, dynamic>{},
        decision: 'allow',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      ));
      await sink.write(BrowserAuditRecord(
        id: '2',
        type: BrowserAuditEntryType.read,
        contextId: 'ctx-B',
        actor: 'b@x',
        operation: 'text',
        params: const <String, dynamic>{},
        decision: 'allow',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      ));

      final hits = await trail
          .query(const BrowserAuditQuery(actor: 'a@x'))
          .toList();
      expect(hits, hasLength(1));
      expect(hits.single.actor, 'a@x');
    });

    test('TC-313 query filters by operation', () async {
      final sink = InMemoryAuditSink();
      await sink.write(BrowserAuditRecord(
        id: '1',
        type: BrowserAuditEntryType.execute,
        operation: 'navigate',
        params: const <String, dynamic>{},
        decision: 'allow',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      ));
      await sink.write(BrowserAuditRecord(
        id: '2',
        type: BrowserAuditEntryType.execute,
        operation: 'click',
        params: const <String, dynamic>{},
        decision: 'allow',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      ));
      final trail = _newTrail(sink: sink, hwm: 100);
      final hits = await trail
          .query(const BrowserAuditQuery(operations: <String>{'navigate'}))
          .toList();
      expect(hits.single.operation, 'navigate');
    });
  });

  group('AuditTrail — startedAt invariants', () {
    test('TC-316 recordExecute carries action.startedAt', () async {
      final trail = _newTrail(hwm: 100);
      final t = DateTime.utc(2026, 4, 17, 12, 0, 0);
      final action = BrowserAction(
        kind: BrowserActionKind.navigate,
        params: <String, dynamic>{'url': 'https://x.com'},
        startedAt: t,
      );
      await trail.recordExecute(
        'ctx-1',
        action,
        const BrowserActionResult(
          success: true,
          duration: Duration(milliseconds: 25),
        ),
        BrowserPolicyDecision.allow,
      );
      final r = trail.buffered.single;
      expect(r.startedAt, t);
      expect(r.endedAt, t.add(const Duration(milliseconds: 25)));
    });
  });

  group('RedactionPolicy — defaults', () {
    test('TC-317 defaults include common credential headers', () {
      final p = BrowserRedactionPolicy();
      expect(p.sensitiveHeaderNames, contains('authorization'));
      expect(p.sensitiveHeaderNames, contains('cookie'));
      expect(p.sensitiveHeaderNames, contains('set-cookie'));
    });
  });
}
