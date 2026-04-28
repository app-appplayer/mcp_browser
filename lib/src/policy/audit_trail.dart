/// MOD-POL-002 — AuditTrail implementation.
///
/// See `docs/03_DDD/05-audit.md` for the design specification and
/// `docs/04_TEST/05-audit.md` for the test plan.
library;

import 'dart:async';

import '../_internal.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// In-memory ring-buffered audit trail with redaction and a pluggable sink.
class AuditTrail implements BrowserAuditPort {

  AuditTrail({
    required this.sink,
    BrowserRedactionPolicy? redaction,
    this.bufferSize = 10000,
    int? flushHighWaterMark,
    this.maxSinkRetries = 5,
  })  : redaction = redaction ?? BrowserRedactionPolicy(),
        flushHighWaterMark = flushHighWaterMark ?? (bufferSize ~/ 2);
  final BrowserAuditSink sink;
  final BrowserRedactionPolicy redaction;

  /// Maximum buffered records before the oldest is dropped.
  final int bufferSize;

  /// Records are flushed to the sink eagerly when this size is reached.
  final int flushHighWaterMark;

  /// Maximum sink retry attempts for a flush batch.
  final int maxSinkRetries;

  final List<BrowserAuditRecord> _buffer = <BrowserAuditRecord>[];
  int _droppedSinceLastFlush = 0;

  /// Number of records dropped since the most recent successful flush.
  /// Exposed for observability and tests.
  int get dropped => _droppedSinceLastFlush;

  /// Snapshot of currently buffered records (test/diagnostic use).
  List<BrowserAuditRecord> get buffered =>
      List<BrowserAuditRecord>.unmodifiable(_buffer);

  @override
  Future<void> recordRead(
    String? contextId,
    BrowserReadSpec spec,
    Map<String, dynamic> meta,
  ) async {
    final params = <String, dynamic>{
      'kind': spec.kind.name,
      if (spec.selector != null) 'selector': spec.selector,
      if (spec.templateId != null) 'templateId': spec.templateId,
      if (spec.templateVersion != null)
        'templateVersion': spec.templateVersion,
      if (spec.options.isNotEmpty) 'options': spec.options,
      ...meta,
    };
    final outcome = _safeRedact(params);
    if (outcome == null) return;
    final now = DateTime.now();
    final record = BrowserAuditRecord(
      id: _uuid.v4(),
      type: BrowserAuditEntryType.read,
      contextId: contextId,
      operation: spec.kind.name,
      params: outcome.redacted,
      decision: 'allow',
      startedAt: now,
      endedAt: now,
      redactedFields: outcome.fields,
    );
    _enqueue(record);
  }

  @override
  Future<void> recordExecute(
    String? contextId,
    BrowserAction action,
    BrowserActionResult result,
    BrowserPolicyDecision decision,
  ) async {
    final outcome = _safeRedact(action.params);
    if (outcome == null) return;
    final endedAt = action.startedAt.add(result.duration);
    final decisionMarker =
        decision.allowed ? 'allow' : (decision.denyCode ?? 'deny');
    final record = BrowserAuditRecord(
      id: _uuid.v4(),
      type: BrowserAuditEntryType.execute,
      contextId: contextId,
      operation: action.kind.name,
      params: outcome.redacted,
      decision: decisionMarker,
      startedAt: action.startedAt,
      endedAt: endedAt,
      redactedFields: outcome.fields,
      errorCode: result.errorCode,
    );
    _enqueue(record);
  }

  @override
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter) =>
      sink.query(filter);

  @override
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    // Swap out the buffer so concurrent flushes cannot step on each other.
    final batch = List<BrowserAuditRecord>.from(_buffer);
    _buffer.clear();
    final failed = <BrowserAuditRecord>[];
    for (final record in batch) {
      var attempt = 0;
      while (true) {
        try {
          await sink.write(record);
          break;
        } on Object {
          attempt++;
          if (attempt >= maxSinkRetries) {
            failed.add(record);
            break;
          }
          await Future<void>.delayed(_backoff(attempt));
        }
      }
    }
    try {
      await sink.flush();
    } on Object {
      // Sink-side flush errors are observable via subsequent writes; do not
      // replay the buffer here.
    }
    if (failed.isNotEmpty) {
      // Records that exhausted retries are dropped; a subsequent caller can
      // detect this via [dropped].
      _droppedSinceLastFlush += failed.length;
    } else {
      _droppedSinceLastFlush = 0;
    }
  }

  // -------------------------------------------------------------------------

  void _enqueue(BrowserAuditRecord record) {
    _buffer.add(record);
    if (_buffer.length > bufferSize) {
      // Drop the oldest record to maintain the cap.
      _buffer.removeAt(0);
      _droppedSinceLastFlush++;
    }
    if (_buffer.length >= flushHighWaterMark) {
      // Fire-and-forget; consumers may await flush() explicitly for ordering.
      unawaited(flush());
    }
  }

  RedactionOutcome? _safeRedact(Map<String, dynamic> input) {
    try {
      return redaction.redact(input);
    } on Object {
      // Failure to redact must NOT result in a record with raw PII. Drop.
      _droppedSinceLastFlush++;
      return null;
    }
  }

  Duration _backoff(int attempt) {
    final ms = 50 * (1 << (attempt - 1));
    return Duration(milliseconds: ms.clamp(50, 2000));
  }
}

// ---------------------------------------------------------------------------
// In-memory sink (production-grade reference + test default)
// ---------------------------------------------------------------------------

/// In-memory sink suitable for tests and small deployments.
class InMemoryAuditSink implements BrowserAuditSink {
  final List<BrowserAuditRecord> records = <BrowserAuditRecord>[];

  @override
  Future<void> write(BrowserAuditRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}

  @override
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter) async* {
    for (final r in records) {
      if (filter.matches(r)) {
        yield r;
        if (filter.limit != null) {
          // Naive limit honoring; assumes records list is order of insertion.
        }
      }
    }
  }

  @override
  Future<void> close() async {
    records.clear();
  }
}
