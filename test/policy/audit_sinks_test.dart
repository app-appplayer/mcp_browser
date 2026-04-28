/// TEST — MOD-POL-002 AuditSink 구현체.
///
/// Covers IT-030 (KvAuditSink round-trip) and IT-031 (FileAuditSink rotation).
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

BrowserAuditRecord _record({
  required String id,
  required DateTime at,
  String operation = 'navigate',
  String decision = 'allow',
  BrowserAuditEntryType type = BrowserAuditEntryType.execute,
  String? actor,
}) {
  return BrowserAuditRecord(
    id: id,
    type: type,
    contextId: 'ctx-$id',
    actor: actor,
    operation: operation,
    params: <String, dynamic>{'u': 'https://x.com/'},
    decision: decision,
    startedAt: at,
    endedAt: at.add(const Duration(milliseconds: 10)),
  );
}

void main() {
  group('KvAuditSink — IT-030 round-trip', () {
    test('write → query returns the same record', () async {
      final kv = InMemoryKvStoragePort();
      final sink = KvAuditSink(kv: kv, prefix: 'test/audit/');
      final rec = _record(id: 'r1', at: DateTime.utc(2026, 4, 17, 10));

      await sink.write(rec);
      final out = await sink.query(const BrowserAuditQuery()).toList();

      expect(out, hasLength(1));
      expect(out.single.id, 'r1');
      expect(out.single.operation, 'navigate');
    });

    test('records are returned in chronological order', () async {
      final kv = InMemoryKvStoragePort();
      final sink = KvAuditSink(kv: kv, prefix: 'test/audit/');
      await sink.write(_record(id: 'c', at: DateTime.utc(2026, 4, 17, 12)));
      await sink.write(_record(id: 'a', at: DateTime.utc(2026, 4, 17, 10)));
      await sink.write(_record(id: 'b', at: DateTime.utc(2026, 4, 17, 11)));

      final ids = <String>[];
      await for (final r in sink.query(const BrowserAuditQuery())) {
        ids.add(r.id);
      }
      expect(ids, <String>['a', 'b', 'c']);
    });

    test('query honors since/until/actor filters', () async {
      final kv = InMemoryKvStoragePort();
      final sink = KvAuditSink(kv: kv, prefix: 'test/audit/');
      await sink.write(_record(
          id: 'old', at: DateTime.utc(2026, 4, 17, 9), actor: 'a'));
      await sink.write(_record(
          id: 'new', at: DateTime.utc(2026, 4, 17, 12), actor: 'b'));

      final sinceFiltered = await sink
          .query(BrowserAuditQuery(since: DateTime.utc(2026, 4, 17, 11)))
          .toList();
      expect(sinceFiltered.map((BrowserAuditRecord r) => r.id), <String>['new']);

      final actorFiltered =
          await sink.query(const BrowserAuditQuery(actor: 'a')).toList();
      expect(actorFiltered.map((BrowserAuditRecord r) => r.id), <String>['old']);
    });

    test('query limit caps emission', () async {
      final kv = InMemoryKvStoragePort();
      final sink = KvAuditSink(kv: kv, prefix: 'test/audit/');
      for (var i = 0; i < 5; i++) {
        await sink.write(_record(
          id: 'r$i',
          at: DateTime.utc(2026, 4, 17, 10, i),
        ));
      }
      final out =
          await sink.query(const BrowserAuditQuery(limit: 2)).toList();
      expect(out, hasLength(2));
    });

    test('KvAuditSink round-trips through AuditTrail', () async {
      final kv = InMemoryKvStoragePort();
      final audit =
          AuditTrail(sink: KvAuditSink(kv: kv, prefix: 'test/audit/'));
      await audit.recordExecute(
        'ctx-1',
        BrowserAction.navigate('https://makemind.dev/'),
        const BrowserActionResult(success: true),
        BrowserPolicyDecision.allow,
      );
      await audit.flush();

      final out = await audit.query(const BrowserAuditQuery()).toList();
      expect(out, hasLength(1));
      expect(out.single.operation, 'navigate');
    });
  });

  group('FileAuditSink — IT-031 rotation', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mcp_browser_file_audit_');
    });

    tearDown(() async {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    });

    test('writes append JSONL', () async {
      final path = '${tmp.path}/audit.log';
      final sink = FileAuditSink(basePath: path);
      await sink.write(_record(id: 'r1', at: DateTime.utc(2026, 4, 17, 10)));
      await sink.write(_record(id: 'r2', at: DateTime.utc(2026, 4, 17, 11)));
      await sink.flush();
      await sink.close();

      final lines = File(path).readAsLinesSync();
      expect(lines, hasLength(2));
      expect(
        (jsonDecode(lines.first) as Map<String, dynamic>)['id'],
        'r1',
      );
    });

    test('rotates when maxBytesPerFile threshold exceeded', () async {
      final path = '${tmp.path}/audit.log';
      final sink = FileAuditSink(basePath: path, maxBytesPerFile: 300);
      // Each record's JSON is ~220-260 bytes, so the second write rotates.
      await sink.write(_record(id: 'r1', at: DateTime.utc(2026, 4, 17, 10)));
      await sink.write(_record(id: 'r2', at: DateTime.utc(2026, 4, 17, 11)));
      await sink.flush();
      await sink.close();

      expect(File('$path.0').existsSync(), isTrue,
          reason: 'first file should have been rotated out');
      expect(File(path).existsSync(), isTrue,
          reason: 'active file exists for the rotated record');
    });

    test('query walks rotated files + active file in order', () async {
      final path = '${tmp.path}/audit.log';
      final sink = FileAuditSink(basePath: path, maxBytesPerFile: 300);
      await sink.write(_record(id: 'r1', at: DateTime.utc(2026, 4, 17, 10)));
      await sink.write(_record(id: 'r2', at: DateTime.utc(2026, 4, 17, 11)));
      await sink.write(_record(id: 'r3', at: DateTime.utc(2026, 4, 17, 12)));

      final ids = <String>[];
      await for (final r in sink.query(const BrowserAuditQuery())) {
        ids.add(r.id);
      }
      expect(ids.toSet(), <String>{'r1', 'r2', 'r3'});

      await sink.close();
    });

    test('query honors filters across rotated files', () async {
      final path = '${tmp.path}/audit.log';
      final sink = FileAuditSink(basePath: path, maxBytesPerFile: 300);
      await sink.write(
          _record(id: 'r1', at: DateTime.utc(2026, 4, 17, 10), actor: 'a'));
      await sink.write(
          _record(id: 'r2', at: DateTime.utc(2026, 4, 17, 11), actor: 'b'));
      await sink.write(
          _record(id: 'r3', at: DateTime.utc(2026, 4, 17, 12), actor: 'a'));

      final ids = <String>[];
      await for (final r in sink.query(const BrowserAuditQuery(actor: 'a'))) {
        ids.add(r.id);
      }
      expect(ids.toSet(), <String>{'r1', 'r3'});

      await sink.close();
    });
  });
}
