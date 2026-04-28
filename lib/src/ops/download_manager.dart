/// MOD-OPS-002 — DownloadManager implementation.
///
/// See `docs/03_DDD/10-download.md` for the design specification and
/// `docs/04_TEST/10-download.md` for the test plan.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import '../_internal.dart';
import 'package:uuid/uuid.dart';

import '../policy/audit_trail.dart';
import '../policy/policy_engine.dart';
import 'http_fetcher.dart';

const _uuid = Uuid();

/// Error mapped to E8001 — fetch / disk failure during download.
class DownloadFailedError extends StateError {
  DownloadFailedError(String reason) : super('E8001 DownloadFailed: $reason');
}

/// Error mapped to E8002 — virus scan rejected the file (it has been
/// quarantined; the descriptor reports the quarantine path).
class DownloadQuarantinedError extends StateError {
  DownloadQuarantinedError(this.descriptor, String? threat)
      : super('E8002 DownloadQuarantined${threat != null ? ': $threat' : ''}');
  final BrowserDownloadDescriptor descriptor;
}

/// File-system + KV backed implementation of [BrowserDownloadPort].
class DownloadManager implements BrowserDownloadPort {

  DownloadManager({
    required this.policy,
    required this.audit,
    required this.fetcher,
    required this.baseDir,
    this.storage,
    this.virusScan,
    this.quarantineWhenNoScan = false,
  });
  final BrowserPolicyPort policy;
  final BrowserAuditPort audit;
  final KvStoragePort? storage;
  final BrowserVirusScanPort? virusScan;
  final HttpFetcher fetcher;

  /// Root directory for tenant-scoped download folders.
  final String baseDir;

  /// When true, downloads from hosts without a virus-scan port are placed
  /// in `.quarantine/` and reported as `quarantined`. When false (default)
  /// they are kept in the regular download path. Maps to NFR-SEC-006.
  final bool quarantineWhenNoScan;

  final StreamController<BrowserDownloadEvent> _events =
      StreamController<BrowserDownloadEvent>.broadcast();

  @override
  Stream<BrowserDownloadEvent> get downloadEvents => _events.stream;

  @override
  Future<BrowserDownloadDescriptor> download(BrowserDownloadSpec spec) async {
    if (spec.url == null) {
      throw UnimplementedError(
        'BrowserDownloadSpec.contextId-based trigger downloads are reserved '
        'for Phase 4',
      );
    }
    final url = spec.url!;
    final action = BrowserAction.download(url, headers: spec.headers);

    final decision = policy.evaluate(action);
    if (!decision.allowed) {
      final desc = _failedDescriptor(spec, url, decision.denyCode ?? 'E2001');
      await audit.recordExecute(
        spec.contextScopeId,
        action,
        BrowserActionResult(
          success: false,
          errorCode: decision.denyCode,
          errorMessage: decision.reason,
        ),
        decision,
      );
      _emit(BrowserDownloadEvent(
          kind: BrowserDownloadStatus.failed, descriptor: desc));
      throw DownloadFailedError(decision.reason ?? 'policy denied');
    }

    final dest = await _ensureDestination(spec, url);
    final id = _uuid.v4();
    final start = DateTime.now();
    var descriptor = BrowserDownloadDescriptor(
      id: id,
      tenantId: spec.tenantId,
      contextScopeId: spec.contextScopeId,
      url: url,
      destPath: dest.path,
      status: BrowserDownloadStatus.started,
      startedAt: start,
    );
    _emit(BrowserDownloadEvent(
        kind: BrowserDownloadStatus.started, descriptor: descriptor));

    HttpFetchResponse response;
    try {
      response = await fetcher.fetch(url, headers: spec.headers);
    } on Object catch (e) {
      throw DownloadFailedError('fetch failed: $e');
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw DownloadFailedError(
          'unexpected HTTP status ${response.statusCode}');
    }

    final hashBuffer = <int>[];
    var written = 0;
    IOSink? sink;
    try {
      sink = dest.openWrite();
      await for (final chunk in response.body) {
        if (spec.maxBytes != null && (written + chunk.length) > spec.maxBytes!) {
          throw DownloadFailedError('exceeded maxBytes');
        }
        sink.add(chunk);
        hashBuffer.addAll(chunk);
        written += chunk.length;
        _emit(BrowserDownloadEvent(
          kind: BrowserDownloadStatus.inProgress,
          descriptor: descriptor.copyWith(sizeBytes: written),
          bytesWritten: written,
          totalBytes: response.contentLength,
        ));
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } on Object {
      await sink?.close();
      try {
        await dest.delete();
      } on Object {/* swallow */}
      rethrow;
    }

    final digestHex = sha256.convert(hashBuffer).toString();
    descriptor = descriptor.copyWith(
      status: BrowserDownloadStatus.finished,
      sha256: digestHex,
      sizeBytes: written,
      mime: response.headers['content-type'],
      finishedAt: DateTime.now(),
    );

    if (virusScan != null) {
      final result = await virusScan!.scan(dest.path);
      if (!result.clean) {
        final quarantined = await _quarantine(dest, descriptor);
        await audit.recordExecute(
          spec.contextScopeId,
          action,
          BrowserActionResult(
            success: false,
            errorCode: 'E8002',
            errorMessage: result.threat ?? 'virus scan rejected',
            duration: DateTime.now().difference(start),
          ),
          decision,
        );
        _emit(BrowserDownloadEvent(
          kind: BrowserDownloadStatus.quarantined,
          descriptor: quarantined,
        ));
        throw DownloadQuarantinedError(quarantined, result.threat);
      }
    } else if (quarantineWhenNoScan) {
      descriptor = await _quarantine(dest, descriptor);
    }

    final domain = Uri.parse(url).host;
    policy.recordRequest(domain);
    policy.recordDownload(domain, written);

    if (storage != null) {
      await storage!.set(_metaKey(id), jsonEncode(descriptor.toJson()));
    }

    await audit.recordExecute(
      spec.contextScopeId,
      action,
      BrowserActionResult(
        success: true,
        output: <String, dynamic>{'downloadId': id, 'sha256': digestHex},
        auditId: id,
        duration: DateTime.now().difference(start),
      ),
      decision,
    );
    _emit(BrowserDownloadEvent(
      kind: BrowserDownloadStatus.finished,
      descriptor: descriptor,
    ));
    return descriptor;
  }

  @override
  Future<BrowserDownloadDescriptor?> getDownload(String id) async {
    if (storage == null) return null;
    final raw = await storage!.get(_metaKey(id));
    if (raw is! String) return null;
    return BrowserDownloadDescriptor.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map));
  }

  @override
  Future<List<BrowserDownloadDescriptor>> listDownloads({
    String? tenantId,
    String? contextScopeId,
  }) async {
    if (storage == null) return const <BrowserDownloadDescriptor>[];
    final keys = await storage!.keys(prefix: _metaPrefix);
    final out = <BrowserDownloadDescriptor>[];
    for (final key in keys) {
      final raw = await storage!.get(key);
      if (raw is! String) continue;
      final descriptor = BrowserDownloadDescriptor.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
      if (tenantId != null && descriptor.tenantId != tenantId) continue;
      if (contextScopeId != null &&
          descriptor.contextScopeId != contextScopeId) {
        continue;
      }
      out.add(descriptor);
    }
    return out;
  }

  @override
  Future<void> deleteDownload(String id) async {
    final descriptor = await getDownload(id);
    if (storage != null) await storage!.remove(_metaKey(id));
    if (descriptor != null) {
      final file = File(descriptor.destPath);
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  /// Test/diagnostic helper: stop the broadcast controller. Hosts may call
  /// this on shutdown.
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
    if (fetcher is IoHttpFetcher) {
      (fetcher as IoHttpFetcher).close();
    }
  }

  // -------------------------------------------------------------------------

  void _emit(BrowserDownloadEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  BrowserDownloadDescriptor _failedDescriptor(
    BrowserDownloadSpec spec,
    String url,
    String code,
  ) {
    return BrowserDownloadDescriptor(
      id: _uuid.v4(),
      tenantId: spec.tenantId,
      contextScopeId: spec.contextScopeId,
      url: url,
      destPath: '',
      status: BrowserDownloadStatus.failed,
      startedAt: DateTime.now(),
      errorCode: code,
    );
  }

  Future<File> _ensureDestination(
    BrowserDownloadSpec spec,
    String url,
  ) async {
    final filename = spec.destFilename ?? _filenameFromUrl(url);
    final dir = Directory(_pathJoin(<String>[
      baseDir,
      _safeSegment(spec.tenantId),
      if (spec.contextScopeId != null) _safeSegment(spec.contextScopeId!),
    ]));
    await dir.create(recursive: true);
    return File(_pathJoin(<String>[dir.path, _safeSegment(filename)]));
  }

  Future<BrowserDownloadDescriptor> _quarantine(
    File source,
    BrowserDownloadDescriptor descriptor,
  ) async {
    final qDir = Directory(_pathJoin(<String>[baseDir, '.quarantine']));
    await qDir.create(recursive: true);
    final qFile = File(_pathJoin(<String>[
      qDir.path,
      '${descriptor.id}_${_basename(source.path)}',
    ]));
    if (source.existsSync()) {
      await source.rename(qFile.path);
    }
    return descriptor.copyWith(
      status: BrowserDownloadStatus.quarantined,
      destPath: qFile.path,
      errorCode: 'E8002',
      finishedAt: DateTime.now(),
    );
  }

  static String _filenameFromUrl(String url) {
    final uri = Uri.parse(url);
    if (uri.pathSegments.isEmpty) return 'download.bin';
    final last = uri.pathSegments.last;
    return last.isEmpty ? 'download.bin' : last;
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  static String _pathJoin(List<String> parts) {
    return parts.join(Platform.pathSeparator);
  }

  /// Strip path traversal characters so a hostile filename can't escape the
  /// tenant/context isolation directory.
  static String _safeSegment(String name) {
    return name.replaceAll(RegExp(r'[\\/\u0000-\u001f]'), '_').replaceAll('..', '_');
  }

  static const _metaPrefix = 'mcp_browser/downloads/meta/';
  static String _metaKey(String id) => '$_metaPrefix$id';
}

/// Compatibility re-exports kept light so test files can stay in package scope.
typedef DownloadAuditTrail = AuditTrail;
typedef DownloadPolicyEngine = PolicyEngine;
