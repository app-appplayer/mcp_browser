/// MOD-POL-002 — `KvAuditSink`.
///
/// See `docs/03_DDD/05-audit.md` §3.2 for the design specification and
/// `docs/04_TEST/05-audit.md` IT-030 for the round-trip integration scenario.
library;

import 'dart:convert';

import '../_internal.dart';

/// [BrowserAuditSink] implementation that persists records through a
/// [KvStoragePort]. Keys are composed as `<prefix><iso8601>/<id>` so that a
/// prefix scan yields chronological order.
class KvAuditSink implements BrowserAuditSink {
  KvAuditSink({
    required this.kv,
    this.prefix = 'mcp_browser/audit/',
  });

  final KvStoragePort kv;
  final String prefix;

  @override
  Future<void> write(BrowserAuditRecord record) async {
    await kv.set(_keyFor(record), jsonEncode(record.toJson()));
  }

  @override
  Future<void> flush() async {}

  @override
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter) async* {
    final keys = await kv.keys(prefix: prefix);
    keys.sort();
    var emitted = 0;
    for (final key in keys) {
      final raw = await kv.get(key);
      if (raw is! String) continue;
      final BrowserAuditRecord record;
      try {
        record = BrowserAuditRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } on Object {
        continue;
      }
      if (!filter.matches(record)) continue;
      yield record;
      emitted++;
      if (filter.limit != null && emitted >= filter.limit!) return;
    }
  }

  @override
  Future<void> close() async {}

  String _keyFor(BrowserAuditRecord record) =>
      '$prefix${record.startedAt.toUtc().toIso8601String()}/${record.id}';
}
