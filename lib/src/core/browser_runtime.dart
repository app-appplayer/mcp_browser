/// MOD-CORE-001 — BrowserRuntime implementation.
///
/// See `docs/03_DDD/02-runtime.md` for the design specification and
/// `docs/04_TEST/02-runtime.md` for the test plan.
library;

import 'dart:async';

import '../_internal.dart';

import '../ops/crawl_scheduler.dart';
import '../ops/download_manager.dart';
import '../registry/auth_profile_store.dart';
import '../registry/context_registry.dart';
import '../registry/engine_registry.dart';
import '../registry/extraction_registry.dart';
import '../registry/search_router.dart';

/// Forward callback for `mcp_ingest` hand-off. Hosts wire it to feed
/// `read()` envelopes into the ingest pipeline. Failures inside this
/// callback are logged but never block the read result.
typedef IngestForwarder = Future<void> Function(BrowserPayloadEnvelope envelope);

/// Aggregator over the four primitives. Wires policy/audit and dispatches
/// read/execute/subscribe to engine adapters via the registry.
class BrowserRuntime {

  BrowserRuntime({
    required this.engines,
    required this.contexts,
    required this.policy,
    required this.audit,
    this.authStore,
    this.extractions,
    this.downloads,
    this.search,
    this.crawler,
    this.ingest,
  });
  final EngineRegistry engines;
  final ContextRegistry contexts;
  final BrowserPolicyPort policy;
  final BrowserAuditPort audit;
  final AuthProfileStore? authStore;
  final ExtractionRegistry? extractions;
  final BrowserDownloadPort? downloads;
  final SearchRouter? search;
  final CrawlScheduler? crawler;
  final IngestForwarder? ingest;

  bool _initialized = false;

  /// Boot all sub-systems. Idempotent.
  Future<void> initialize() async {
    if (_initialized) return;
    await engines.initialize();
    await contexts.initialize();
    _initialized = true;
  }

  /// Graceful shutdown. Best-effort: each step is awaited but failures are
  /// suppressed so subsequent cleanup still runs.
  Future<void> shutdown() async {
    try {
      await contexts.shutdown();
    } on Object {/* continue */}
    try {
      await engines.shutdown();
    } on Object {/* continue */}
    try {
      await audit.flush();
    } on Object {/* continue */}
    _initialized = false;
  }

  /// Build a top-level catalogue. Phase 1 keeps search/extraction lists empty;
  /// Phases 2–3 wire those registries.
  Future<BrowserDescriptor> describe() async {
    return BrowserDescriptor(
      engines: engines.list(),
      activeContexts: contexts.activeCount(),
      resourceCaps: policy.resourceCaps,
    );
  }

  /// Non-mutating read against [contextId].
  Future<BrowserPayloadEnvelope> read(
    String contextId,
    BrowserReadSpec spec,
  ) async {
    final handle = contexts.lookup(contextId);
    if (handle == null) throw ContextNotFoundError(contextId);
    final engine = engines.resolve(handle.engineId);

    BrowserPayloadEnvelope envelope;
    if (spec.kind == BrowserReadKind.extract) {
      envelope = await _runExtraction(engine, handle, spec);
    } else {
      envelope = await engine.read(handle, spec);
    }

    handle.lastUsedAt = DateTime.now();
    await audit.recordRead(contextId, spec, envelope.meta);
    if (ingest != null) {
      try {
        await ingest!(envelope);
      } on Object {
        // Hand-off failure is observability-only — caller still gets envelope.
      }
    }
    return envelope;
  }

  Future<BrowserPayloadEnvelope> _runExtraction(
    BrowserEnginePort engine,
    BrowserContextHandle handle,
    BrowserReadSpec spec,
  ) async {
    if (extractions == null) {
      throw StateError(
        'E3002 extract requested but ExtractionRegistry not wired',
      );
    }
    final templateId = spec.templateId;
    if (templateId == null || templateId.isEmpty) {
      throw ArgumentError('extract ReadSpec requires templateId');
    }
    final template =
        await extractions!.get(templateId, version: spec.templateVersion);
    if (template == null) {
      throw StateError(
        'E3002 extraction template not found: $templateId@${spec.templateVersion ?? 'latest'}',
      );
    }
    final htmlEnvelope = await engine.read(
      handle,
      BrowserReadSpec(kind: BrowserReadKind.html, selector: spec.selector),
    );
    final html = htmlEnvelope.body is String
        ? htmlEnvelope.body as String
        : htmlEnvelope.body.toString();
    final pageUrl = htmlEnvelope.meta['pageUrl'] as String? ??
        spec.options['pageUrl'] as String?;
    final data = await extractions!.evaluate(
      template,
      html: html,
      pageUrl: pageUrl,
    );
    return BrowserPayloadEnvelope(
      contextId: handle.contextId,
      mime: 'application/json',
      body: data,
      meta: <String, dynamic>{
        'templateId': template.id,
        'templateVersion': template.version,
        if (pageUrl != null) 'pageUrl': pageUrl,
      },
    );
  }

  /// State-changing action against [contextId]. Special action kinds
  /// (`setAuth`, `search`, `crawl`, `download`) are routed to dedicated
  /// modules; everything else flows to the engine.
  Future<BrowserActionResult> execute(
    String contextId,
    BrowserAction action,
  ) async {
    final decision = policy.evaluate(action);
    if (!decision.allowed) {
      final result = BrowserActionResult(
        success: false,
        errorCode: decision.denyCode,
        errorMessage: decision.reason,
      );
      await audit.recordExecute(contextId, action, result, decision);
      throw _denyToError(decision);
    }

    // Context-free actions (search, crawl) do not require a live handle.
    // `download` also works page-less when `tenantId` is supplied in params.
    final requiresHandle = _requiresHandle(action);
    final handle = requiresHandle ? contexts.lookup(contextId) : null;
    if (requiresHandle && handle == null) {
      throw ContextNotFoundError(contextId);
    }

    BrowserActionResult result;
    final start = DateTime.now();

    switch (action.kind) {
      case BrowserActionKind.setAuth:
        result = await _applyAuth(handle!, action);
        break;
      case BrowserActionKind.download:
        if (downloads == null) {
          result = const BrowserActionResult(
            success: false,
            errorCode: 'E8001',
            errorMessage: 'download requested but DownloadManager not wired',
          );
        } else {
          result = await _runDownload(handle, action);
        }
        break;
      case BrowserActionKind.search:
        if (search == null) {
          result = const BrowserActionResult(
            success: false,
            errorCode: 'E6001',
            errorMessage: 'search requested but SearchRouter not wired',
          );
        } else {
          result = await _runSearch(action);
        }
        break;
      case BrowserActionKind.crawl:
        if (crawler == null) {
          result = const BrowserActionResult(
            success: false,
            errorCode: 'E7001',
            errorMessage: 'crawl requested but CrawlScheduler not wired',
          );
        } else {
          result = await _runCrawl(action);
        }
        break;
      default:
        final engine = engines.resolve(handle!.engineId);
        result = await engine.execute(handle, action);
    }

    handle?.lastUsedAt = DateTime.now();
    await audit.recordExecute(contextId, action, result, decision);
    if (!result.success) {
      // Surface as a thrown error for callers that want exception flow.
      // Auditing has already happened above.
      throw StateError(
        '${result.errorCode ?? 'E1000'} ${result.errorMessage ?? 'execute failed'}',
      );
    }
    final _ = start;
    return result;
  }

  /// Stream events for [topic] within [contextId].
  Stream<BrowserEvent> subscribe(String contextId, BrowserTopic topic) {
    final handle = contexts.lookup(contextId);
    if (handle == null) throw ContextNotFoundError(contextId);
    final engine = engines.resolve(handle.engineId);
    return engine.subscribe(handle, topic);
  }

  // -------------------------------------------------------------------------

  Future<BrowserActionResult> _applyAuth(
    BrowserContextHandle handle,
    BrowserAction action,
  ) async {
    if (authStore == null) {
      return const BrowserActionResult(
        success: false,
        errorCode: 'E4001',
        errorMessage: 'AuthProfileStore not configured',
      );
    }
    final profileId = action.params['profileId'] as String?;
    if (profileId == null || profileId.isEmpty) {
      return const BrowserActionResult(
        success: false,
        errorCode: 'E4001',
        errorMessage: 'setAuth requires `profileId`',
      );
    }
    final tenantId =
        (action.params['tenantId'] as String?) ?? handle.spec.tenantId;
    final profile = await authStore!.get(tenantId, profileId);
    if (profile == null) {
      throw AuthProfileNotFoundError(tenantId, profileId);
    }
    final engine = engines.resolve(handle.engineId);
    final contextPort = engines.resolveContextPort(handle.engineId);
    try {
      await applyProfileTo(
        handle: handle,
        profile: profile,
        engine: engine,
        contextPort: contextPort,
      );
    } on AuthInjectionFailedError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E4002',
        errorMessage: e.message,
      );
    }
    return const BrowserActionResult(success: true);
  }

  Future<BrowserActionResult> _runCrawl(BrowserAction action) async {
    final seedsRaw = action.params['seeds'];
    if (seedsRaw is! List) {
      return const BrowserActionResult(
        success: false,
        errorCode: 'E7001',
        errorMessage: 'crawl requires `seeds` (list)',
      );
    }
    final seeds =
        seedsRaw.map((dynamic e) => e.toString()).toList(growable: false);
    final policyJson =
        (action.params['policy'] as Map?)?.cast<String, dynamic>();
    final crawlPolicy = BrowserCrawlPolicy(
      depth: (policyJson?['depth'] as num?)?.toInt() ?? 1,
      breadth: (policyJson?['breadth'] as num?)?.toInt() ?? 50,
      ratePerDomain:
          (policyJson?['ratePerDomain'] as num?)?.toDouble() ?? 1.0,
      concurrency: (policyJson?['concurrency'] as num?)?.toInt() ?? 1,
      respectRobots: (policyJson?['respectRobots'] as bool?) ?? true,
      allowedDomains: (policyJson?['allowedDomains'] as List<dynamic>?)
              ?.map((dynamic e) => e as String)
              .toList(growable: false) ??
          const <String>[],
      maxNavigateRetries:
          (policyJson?['maxNavigateRetries'] as num?)?.toInt() ?? 3,
    );
    try {
      final handle = await crawler!.start(seeds, crawlPolicy);
      return BrowserActionResult(
        success: true,
        output: <String, dynamic>{
          'crawlId': handle.crawlId,
          'startedAt': handle.startedAt.toIso8601String(),
        },
      );
    } on CrawlPolicyInvalidError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E7001',
        errorMessage: e.message.toString(),
      );
    } on CrawlDomainBlacklistedError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E7003',
        errorMessage: e.message,
      );
    }
  }

  Future<BrowserActionResult> _runSearch(BrowserAction action) async {
    final query = action.params['query'] as String?;
    final providerId = action.params['provider'] as String?;
    if (query == null || providerId == null) {
      return const BrowserActionResult(
        success: false,
        errorCode: 'E6001',
        errorMessage: 'search requires `query` and `provider`',
      );
    }
    final modeName = action.params['mode'] as String?;
    final intentName = action.params['intent'] as String?;
    final options = BrowserSearchOptions(
      mode: modeName != null
          ? BrowserSearchMode.values.firstWhere(
              (BrowserSearchMode m) => m.name == modeName,
              orElse: () => throw ArgumentError('unknown search mode: $modeName'),
            )
          : null,
      intent: intentName != null
          ? BrowserSearchIntent.values.firstWhere(
              (BrowserSearchIntent i) => i.name == intentName,
              orElse: () => BrowserSearchIntent.web,
            )
          : BrowserSearchIntent.web,
      limit: (action.params['limit'] as int?) ?? 10,
      offset: (action.params['offset'] as int?) ?? 0,
      language: action.params['language'] as String?,
      region: action.params['region'] as String?,
      cacheTtl: action.params['cacheTtl'] is int
          ? Duration(seconds: action.params['cacheTtl'] as int)
          : const Duration(hours: 1),
    );
    try {
      final results = await search!
          .search(query, providerId: providerId, options: options);
      return BrowserActionResult(
        success: true,
        output: <String, dynamic>{
          'results': results
              .map((BrowserSearchResult r) => r.toJson())
              .toList(growable: false),
        },
      );
    } on SearchProviderNotRegisteredError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E6001',
        errorMessage: e.message,
      );
    } on SearchRateLimitedError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E6002',
        errorMessage: e.message,
      );
    } on SearchSerpParseError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E6003',
        errorMessage: e.message,
      );
    }
  }

  Future<BrowserActionResult> _runDownload(
    BrowserContextHandle? handle,
    BrowserAction action,
  ) async {
    final spec = BrowserDownloadSpec(
      tenantId: (action.params['tenantId'] as String?) ??
          handle?.spec.tenantId ??
          '_default',
      contextScopeId:
          (action.params['contextScopeId'] as String?) ?? handle?.contextId,
      url: action.params['url'] as String?,
      destFilename: action.params['destFilename'] as String?,
      headers: (action.params['headers'] as Map?)?.cast<String, String>(),
      maxBytes: action.params['maxBytes'] as int?,
    );
    try {
      final descriptor = await downloads!.download(spec);
      return BrowserActionResult(
        success: true,
        output: <String, dynamic>{
          'downloadId': descriptor.id,
          'destPath': descriptor.destPath,
          'sizeBytes': descriptor.sizeBytes,
          if (descriptor.sha256 != null) 'sha256': descriptor.sha256,
        },
        auditId: descriptor.id,
      );
    } on DownloadQuarantinedError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E8002',
        errorMessage: e.message,
        output: <String, dynamic>{
          'downloadId': e.descriptor.id,
          'destPath': e.descriptor.destPath,
        },
      );
    } on DownloadFailedError catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E8001',
        errorMessage: e.message,
      );
    } on Object catch (e) {
      return BrowserActionResult(
        success: false,
        errorCode: 'E8001',
        errorMessage: '$e',
      );
    }
  }

  static bool _requiresHandle(BrowserAction action) {
    switch (action.kind) {
      case BrowserActionKind.search:
      case BrowserActionKind.crawl:
        return false;
      case BrowserActionKind.download:
        // `tenantId` in params satisfies isolation without a page context.
        return action.params['tenantId'] == null;
      default:
        return true;
    }
  }

  static StateError _denyToError(BrowserPolicyDecision decision) {
    return StateError(
      '${decision.denyCode ?? 'E2001'} ${decision.reason ?? 'policy deny'}',
    );
  }
}
