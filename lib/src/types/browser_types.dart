/// Shared types for the mcp_browser capability surface.
///
/// All public symbols are prefixed with `Browser*` to avoid naming
/// collisions with sibling capabilities (audit_port, io_*).
library;

// ---------------------------------------------------------------------------
// Action — state-changing commands sent to a browser context
// ---------------------------------------------------------------------------

/// Kind of state-changing browser action.
enum BrowserActionKind {
  navigate,
  reload,
  back,
  forward,
  click,
  dblclick,
  hover,
  drag,
  type,
  fill,
  press,
  select,
  check,
  upload,
  evalJs,
  setAuth,
  setViewport,
  setLocale,
  setTimezone,
  emulateDevice,
  intercept,
  download,
  search,
  crawl,
  openContext,
  closeContext;

  static BrowserActionKind fromString(String value) {
    return BrowserActionKind.values.firstWhere(
      (BrowserActionKind e) => e.name == value,
      orElse: () => throw ArgumentError('Unknown BrowserActionKind: $value'),
    );
  }
}

/// A state-changing command targeting a browser context.
class BrowserAction {
  /// Discriminator for the action variant.
  final BrowserActionKind kind;

  /// Free-form parameters keyed by the action variant.
  final Map<String, dynamic> params;

  /// Wall-clock when the action was constructed (used by audit `started_at`).
  final DateTime startedAt;

  BrowserAction({
    required this.kind,
    Map<String, dynamic>? params,
    DateTime? startedAt,
  })  : params = params ?? const <String, dynamic>{},
        startedAt = startedAt ?? DateTime.now();

  /// Convenience: navigate.
  factory BrowserAction.navigate(String url, {String? waitUntil}) =>
      BrowserAction(kind: BrowserActionKind.navigate, params: <String, dynamic>{
        'url': url,
        if (waitUntil != null) 'waitUntil': waitUntil,
      });

  /// Convenience: download.
  factory BrowserAction.download(String url, {Map<String, String>? headers}) =>
      BrowserAction(kind: BrowserActionKind.download, params: <String, dynamic>{
        'url': url,
        if (headers != null) 'headers': headers,
      });

  /// Convenience: evaluate JavaScript.
  factory BrowserAction.evalJs(String expression) => BrowserAction(
        kind: BrowserActionKind.evalJs,
        params: <String, dynamic>{'expression': expression},
      );

  /// Convenience: crawl seed.
  factory BrowserAction.crawl({
    required List<String> seeds,
    required Map<String, dynamic> policy,
  }) =>
      BrowserAction(
        kind: BrowserActionKind.crawl,
        params: <String, dynamic>{'seeds': seeds, 'policy': policy},
      );
}

/// Outcome of `execute(BrowserAction)`.
class BrowserActionResult {
  /// Whether the action succeeded.
  final bool success;

  /// Optional structured output from the action.
  final Map<String, dynamic>? output;

  /// Optional error code on failure (one of the `E*xxx` SDD §6.2 codes).
  final String? errorCode;

  /// Optional human-readable error message (no PII).
  final String? errorMessage;

  /// Identifier of the audit record created for this action, if any.
  final String? auditId;

  /// Wall-clock duration of the action.
  final Duration duration;

  const BrowserActionResult({
    required this.success,
    this.output,
    this.errorCode,
    this.errorMessage,
    this.auditId,
    this.duration = Duration.zero,
  });
}

// ---------------------------------------------------------------------------
// Read — non-mutating extraction requests
// ---------------------------------------------------------------------------

/// Kind of read extraction.
enum BrowserReadKind {
  dom,
  html,
  text,
  markdown,
  ariaTree,
  screenshot,
  pdf,
  har,
  cookies,
  storage,
  extract;

  static BrowserReadKind fromString(String value) {
    return BrowserReadKind.values.firstWhere(
      (BrowserReadKind e) => e.name == value,
      orElse: () => throw ArgumentError('Unknown BrowserReadKind: $value'),
    );
  }
}

/// Specification of a non-mutating read against a page.
class BrowserReadSpec {
  /// Variant discriminator.
  final BrowserReadKind kind;

  /// Optional CSS / XPath / role selector for `dom`/`html`/`text`.
  final String? selector;

  /// Optional ExtractionTemplate identifier for `extract`.
  final String? templateId;

  /// Optional template version (semver). When null, latest is used.
  final String? templateVersion;

  /// Free-form per-kind options.
  final Map<String, dynamic> options;

  BrowserReadSpec({
    required this.kind,
    this.selector,
    this.templateId,
    this.templateVersion,
    Map<String, dynamic>? options,
  }) : options = options ?? const <String, dynamic>{};

  factory BrowserReadSpec.text({String? selector}) =>
      BrowserReadSpec(kind: BrowserReadKind.text, selector: selector);

  factory BrowserReadSpec.html({String? selector}) =>
      BrowserReadSpec(kind: BrowserReadKind.html, selector: selector);

  factory BrowserReadSpec.screenshot({bool fullPage = false}) =>
      BrowserReadSpec(
        kind: BrowserReadKind.screenshot,
        options: <String, dynamic>{'fullPage': fullPage},
      );

  factory BrowserReadSpec.extract({
    required String templateId,
    String? templateVersion,
  }) =>
      BrowserReadSpec(
        kind: BrowserReadKind.extract,
        templateId: templateId,
        templateVersion: templateVersion,
      );
}

// ---------------------------------------------------------------------------
// Context — actor/tenant scoped browser context spec
// ---------------------------------------------------------------------------

/// Request to acquire a browser context.
class BrowserContextSpec {
  /// Tenant identifier (host concern).
  final String tenantId;

  /// Optional actor identifier (e.g., user email or uid).
  final String? actorId;

  /// Optional engine identifier; null means use the registry default.
  final String? engineId;

  /// Whether the context's storage should be persisted across acquisitions.
  final bool persistent;

  /// Optional viewport hint `{width, height}`.
  final Map<String, int>? viewport;

  /// Optional BCP-47 locale (e.g. `'ko-KR'`).
  final String? locale;

  /// Optional IANA timezone (e.g. `'Asia/Seoul'`).
  final String? timezone;

  /// Optional geolocation `{latitude, longitude, accuracy}`.
  final Map<String, double>? geolocation;

  /// Optional UA override.
  final String? userAgent;

  const BrowserContextSpec({
    required this.tenantId,
    this.actorId,
    this.engineId,
    this.persistent = false,
    this.viewport,
    this.locale,
    this.timezone,
    this.geolocation,
    this.userAgent,
  });

  /// Stable hash usable as a key for warm-pool reuse and storage state lookup.
  String get specHash {
    final buffer = StringBuffer()
      ..write(tenantId)
      ..write('|')
      ..write(actorId ?? '')
      ..write('|')
      ..write(engineId ?? '')
      ..write('|')
      ..write(persistent ? '1' : '0')
      ..write('|')
      ..write(locale ?? '')
      ..write('|')
      ..write(timezone ?? '')
      ..write('|')
      ..write(userAgent ?? '');
    if (viewport != null) {
      buffer
        ..write('|')
        ..write(viewport!['width'] ?? 0)
        ..write('x')
        ..write(viewport!['height'] ?? 0);
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// Policy — decision objects + caps + URL access rules
// ---------------------------------------------------------------------------

/// Policy decision returned by `BrowserPolicyPort.evaluate`.
class BrowserPolicyDecision {
  /// Whether the action is allowed.
  final bool allowed;

  /// Human-readable reason on deny (no PII).
  final String? reason;

  /// Error code on deny (subset of SDD §6.2 codes — E2001/E2002/E7002/E7003/E8003).
  final String? denyCode;

  /// Free-form context for downstream audit.
  final Map<String, dynamic> context;

  const BrowserPolicyDecision({
    required this.allowed,
    this.reason,
    this.denyCode,
    this.context = const <String, dynamic>{},
  });

  /// Static helper: allow.
  static const BrowserPolicyDecision allow =
      BrowserPolicyDecision(allowed: true);

  /// Convenience: build a deny decision with code + reason.
  factory BrowserPolicyDecision.deny(String code, String reason) =>
      BrowserPolicyDecision(
        allowed: false,
        denyCode: code,
        reason: reason,
      );
}

/// Default per-context resource caps. Hosts may override.
class BrowserResourceCaps {
  /// Max simultaneous contexts.
  final int maxConcurrentContexts;

  /// Max pages (tabs) per context.
  final int maxPagesPerContext;

  /// Max memory bytes per context (engine-enforced when supported).
  final int maxMemoryBytesPerContext;

  /// Max wall-clock session duration per context.
  final Duration maxSessionDuration;

  /// Daily download quota per domain (bytes).
  final int dailyDownloadCapBytesPerDomain;

  /// Whether `evalJs` actions are permitted at all.
  final bool allowEval;

  const BrowserResourceCaps({
    this.maxConcurrentContexts = 50,
    this.maxPagesPerContext = 20,
    this.maxMemoryBytesPerContext = 2 * 1024 * 1024 * 1024,
    this.maxSessionDuration = const Duration(minutes: 30),
    this.dailyDownloadCapBytesPerDomain = 1 * 1024 * 1024 * 1024,
    this.allowEval = true,
  });

  BrowserResourceCaps copyWith({
    int? maxConcurrentContexts,
    int? maxPagesPerContext,
    int? maxMemoryBytesPerContext,
    Duration? maxSessionDuration,
    int? dailyDownloadCapBytesPerDomain,
    bool? allowEval,
  }) {
    return BrowserResourceCaps(
      maxConcurrentContexts:
          maxConcurrentContexts ?? this.maxConcurrentContexts,
      maxPagesPerContext: maxPagesPerContext ?? this.maxPagesPerContext,
      maxMemoryBytesPerContext:
          maxMemoryBytesPerContext ?? this.maxMemoryBytesPerContext,
      maxSessionDuration: maxSessionDuration ?? this.maxSessionDuration,
      dailyDownloadCapBytesPerDomain: dailyDownloadCapBytesPerDomain ??
          this.dailyDownloadCapBytesPerDomain,
      allowEval: allowEval ?? this.allowEval,
    );
  }
}

// ---------------------------------------------------------------------------
// Audit — record + query + redaction policy
// ---------------------------------------------------------------------------

/// Discriminator for the audit entry kind.
enum BrowserAuditEntryType { read, execute }

/// Immutable record of an auditable browser operation.
class BrowserAuditRecord {
  /// Unique identifier (uuid v4 recommended).
  final String id;

  /// Type of audited operation.
  final BrowserAuditEntryType type;

  /// Identifier of the originating browser context (may be null for global ops).
  final String? contextId;

  /// Optional actor scoped to the context (denormalized for query).
  final String? actor;

  /// Action / read kind name.
  final String operation;

  /// Redacted parameters of the operation.
  final Map<String, dynamic> params;

  /// Decision marker — `'allow'` or `<errorCode>` for deny.
  final String decision;

  /// Wall-clock when the operation began.
  final DateTime startedAt;

  /// Wall-clock when the operation ended (or was rejected).
  final DateTime endedAt;

  /// Names of fields that were redacted by the redaction policy.
  final List<String> redactedFields;

  /// Optional error code.
  final String? errorCode;

  const BrowserAuditRecord({
    required this.id,
    required this.type,
    required this.operation,
    required this.params,
    required this.decision,
    required this.startedAt,
    required this.endedAt,
    this.contextId,
    this.actor,
    this.redactedFields = const <String>[],
    this.errorCode,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.name,
        if (contextId != null) 'contextId': contextId,
        if (actor != null) 'actor': actor,
        'operation': operation,
        'params': params,
        'decision': decision,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'redactedFields': redactedFields,
        if (errorCode != null) 'errorCode': errorCode,
      };

  factory BrowserAuditRecord.fromJson(Map<String, dynamic> json) {
    return BrowserAuditRecord(
      id: json['id'] as String,
      type: BrowserAuditEntryType.values
          .firstWhere((BrowserAuditEntryType e) => e.name == json['type']),
      contextId: json['contextId'] as String?,
      actor: json['actor'] as String?,
      operation: json['operation'] as String,
      params: Map<String, dynamic>.from(json['params'] as Map),
      decision: json['decision'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      redactedFields: (json['redactedFields'] as List<dynamic>?)
              ?.map((dynamic e) => e as String)
              .toList(growable: false) ??
          const <String>[],
      errorCode: json['errorCode'] as String?,
    );
  }
}

/// Query filter for audit retrieval.
class BrowserAuditQuery {
  /// Lower bound on `startedAt` (inclusive).
  final DateTime? since;

  /// Upper bound on `startedAt` (exclusive).
  final DateTime? until;

  /// Restrict to a single context.
  final String? contextId;

  /// Restrict to a single actor.
  final String? actor;

  /// Restrict to specific operation names.
  final Set<String>? operations;

  /// Restrict to a specific entry type.
  final BrowserAuditEntryType? entryType;

  /// Restrict to allow / deny.
  final String? decision;

  /// Pagination cap.
  final int? limit;

  const BrowserAuditQuery({
    this.since,
    this.until,
    this.contextId,
    this.actor,
    this.operations,
    this.entryType,
    this.decision,
    this.limit,
  });

  /// Returns true if [record] satisfies all set filters.
  bool matches(BrowserAuditRecord record) {
    if (since != null && record.startedAt.isBefore(since!)) return false;
    if (until != null && !record.startedAt.isBefore(until!)) return false;
    if (contextId != null && record.contextId != contextId) return false;
    if (actor != null && record.actor != actor) return false;
    if (operations != null && !operations!.contains(record.operation)) {
      return false;
    }
    if (entryType != null && record.type != entryType) return false;
    if (decision != null && record.decision != decision) return false;
    return true;
  }
}

/// Policy for masking sensitive fields before persisting an audit record.
///
/// The default policy redacts well-known credential carriers
/// (cookies, set-cookie, authorization headers, bearer tokens).
class BrowserRedactionPolicy {
  /// Header names whose values should be replaced with a redaction token.
  /// All names are matched case-insensitively.
  final Set<String> sensitiveHeaderNames;

  /// Regular expressions whose match in any *string* value triggers redaction
  /// of the whole value.
  final List<RegExp> sensitiveValuePatterns;

  /// Param keys whose values should be replaced wholesale.
  final Set<String> sensitiveParamKeys;

  BrowserRedactionPolicy({
    Set<String>? sensitiveHeaderNames,
    List<RegExp>? sensitiveValuePatterns,
    Set<String>? sensitiveParamKeys,
  })  : sensitiveHeaderNames = sensitiveHeaderNames ??
            <String>{
              'authorization',
              'cookie',
              'set-cookie',
              'x-api-key',
              'x-firebase-id-token',
              'proxy-authorization',
            },
        sensitiveValuePatterns = sensitiveValuePatterns ??
            <RegExp>[
              RegExp(r'Bearer\s+[A-Za-z0-9._\-]+'),
              RegExp(r'eyJ[A-Za-z0-9._\-]{16,}'),
            ],
        sensitiveParamKeys = sensitiveParamKeys ??
            <String>{
              // Whole-value masking. `headers` is intentionally excluded so
              // that individual sensitive header values can be replaced
              // while non-sensitive ones (e.g. `X-Trace`) survive.
              'cookies',
              'storage',
              'localStorage',
              'sessionStorage',
              'indexedDb',
              'token',
              'idToken',
              'refreshToken',
              'apiKey',
              'secret',
              'password',
            };

  /// Returns a redacted shallow copy of [input] and the list of redacted field names.
  RedactionOutcome redact(Map<String, dynamic> input) {
    final result = <String, dynamic>{};
    final touched = <String>{};
    for (final entry in input.entries) {
      final key = entry.key;
      final value = entry.value;
      if (sensitiveParamKeys.contains(key)) {
        result[key] = _redactionToken(key);
        touched.add(key);
        continue;
      }
      if (key.toLowerCase() == 'headers' && value is Map) {
        result[key] = _redactHeaders(value, touched, parentKey: key);
        continue;
      }
      if (value is String) {
        final redacted = _maybeRedactString(value);
        if (redacted != value) touched.add(key);
        result[key] = redacted;
        continue;
      }
      result[key] = value;
    }
    return RedactionOutcome(redacted: result, fields: touched.toList()..sort());
  }

  Map<String, dynamic> _redactHeaders(
    Map<dynamic, dynamic> headers,
    Set<String> touched, {
    required String parentKey,
  }) {
    final out = <String, dynamic>{};
    for (final entry in headers.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (sensitiveHeaderNames.contains(key.toLowerCase())) {
        out[key] = _redactionToken('header');
        touched.add('$parentKey.$key');
        continue;
      }
      if (value is String) {
        final redacted = _maybeRedactString(value);
        if (redacted != value) touched.add('$parentKey.$key');
        out[key] = redacted;
        continue;
      }
      out[key] = value;
    }
    return out;
  }

  String _maybeRedactString(String value) {
    for (final pattern in sensitiveValuePatterns) {
      if (pattern.hasMatch(value)) {
        return _redactionToken('match');
      }
    }
    return value;
  }

  String _redactionToken(String label) => '<redacted:$label>';
}

/// Result of a [BrowserRedactionPolicy.redact] call.
class RedactionOutcome {
  final Map<String, dynamic> redacted;
  final List<String> fields;

  const RedactionOutcome({required this.redacted, required this.fields});
}

// ---------------------------------------------------------------------------
// Engine descriptor
// ---------------------------------------------------------------------------

/// Capability flags an engine adapter advertises.
enum EngineCapability {
  readDom,
  readScreenshot,
  readPdf,
  readHar,
  executeNavigate,
  executeClick,
  executeType,
  executeFill,
  executeIntercept,
  executeDownload,
  executeEval,
  subscribeConsole,
  subscribeNetwork,
  subscribeDomMutation,
  contextEmulation,
  contextStorageState,
  headful,
  headless,
}

/// Self-description of a registered engine adapter.
class EngineDescriptor {
  final String id;
  final String name;
  final String version;
  final Set<EngineCapability> capabilities;

  const EngineDescriptor({
    required this.id,
    required this.name,
    required this.version,
    required this.capabilities,
  });

  bool supports(EngineCapability cap) => capabilities.contains(cap);
}

// ---------------------------------------------------------------------------
// Browser context handle
// ---------------------------------------------------------------------------

/// Lifecycle state of a [BrowserContextHandle].
enum ContextLifecycleState { warm, active, idle, closed }

/// Live handle to an engine-managed browser context.
///
/// Mutable fields are limited to lifecycle bookkeeping ([state],
/// [lastUsedAt]). Engine-specific opaque data lives in [enginePayload].
class BrowserContextHandle {
  final String contextId;
  final String engineId;
  final BrowserContextSpec spec;
  final DateTime createdAt;
  DateTime lastUsedAt;
  ContextLifecycleState state;

  /// Engine adapter's opaque per-context payload (e.g., CDP target id,
  /// Playwright BrowserContext reference). Treated as opaque by the core.
  final Object enginePayload;

  BrowserContextHandle({
    required this.contextId,
    required this.engineId,
    required this.spec,
    required this.enginePayload,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    this.state = ContextLifecycleState.warm,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastUsedAt = lastUsedAt ?? DateTime.now();

  /// True when [other] is compatible enough to satisfy the same spec
  /// (used for warm-pool reuse). Compares the stable spec hash.
  bool isCompatibleWith(BrowserContextSpec other) =>
      spec.specHash == other.specHash;
}

// ---------------------------------------------------------------------------
// Cookie (used by BrowserContextPort.setCookies)
// ---------------------------------------------------------------------------

/// HTTP cookie that may be injected into a context.
class BrowserCookie {
  final String name;
  final String value;
  final String? domain;
  final String? path;
  final DateTime? expires;
  final bool httpOnly;
  final bool secure;
  final String? sameSite;

  const BrowserCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expires,
    this.httpOnly = false,
    this.secure = false,
    this.sameSite,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'value': value,
        if (domain != null) 'domain': domain,
        if (path != null) 'path': path,
        if (expires != null) 'expires': expires!.toIso8601String(),
        'httpOnly': httpOnly,
        'secure': secure,
        if (sameSite != null) 'sameSite': sameSite,
      };
}

// ---------------------------------------------------------------------------
// Subscribe topics + events + payload envelope
// ---------------------------------------------------------------------------

/// Discriminator for subscribable streams.
enum BrowserTopicKind {
  consoleLog,
  consoleWarn,
  consoleError,
  request,
  response,
  requestFailed,
  domMutation,
  dialog,
  downloadStarted,
  downloadFinished,
  crawlProgress,
}

/// Topic descriptor passed to `subscribe()`.
class BrowserTopic {
  final BrowserTopicKind kind;

  /// Optional refinement (e.g., selector for `domMutation`).
  final String? filter;

  const BrowserTopic({required this.kind, this.filter});

  factory BrowserTopic.consoleError() =>
      const BrowserTopic(kind: BrowserTopicKind.consoleError);

  factory BrowserTopic.requestFailed() =>
      const BrowserTopic(kind: BrowserTopicKind.requestFailed);
}

/// Event delivered by a `subscribe()` stream.
class BrowserEvent {
  final BrowserTopicKind topic;
  final String? contextId;
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  BrowserEvent({
    required this.topic,
    required this.payload,
    this.contextId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Result of `read()` — bytes/text plus metadata.
class BrowserPayloadEnvelope {
  /// Owning context (may be null when the read is global, e.g., `describe`).
  final String? contextId;

  /// MIME type (e.g., `text/plain`, `image/png`).
  final String mime;

  /// Body — either a `String`, `List<int>`, or a structured `Map`.
  final Object body;

  /// Free-form metadata (selector hits, render time, etc.).
  final Map<String, dynamic> meta;

  /// Wall-clock when the read completed.
  final DateTime timestamp;

  BrowserPayloadEnvelope({
    required this.mime,
    required this.body,
    this.contextId,
    Map<String, dynamic>? meta,
    DateTime? timestamp,
  })  : meta = meta ?? const <String, dynamic>{},
        timestamp = timestamp ?? DateTime.now();
}

// ---------------------------------------------------------------------------
// Browser descriptor (top-level catalogue)
// ---------------------------------------------------------------------------

/// Top-level catalogue returned by `BrowserRuntime.describe()`.
class BrowserDescriptor {
  final List<EngineDescriptor> engines;
  final int activeContexts;
  final BrowserResourceCaps resourceCaps;

  /// Search provider IDs registered at the moment of capture.
  final List<String> searchProviders;

  /// Extraction template IDs registered at the moment of capture.
  final List<String> extractionTemplates;

  const BrowserDescriptor({
    required this.engines,
    required this.activeContexts,
    required this.resourceCaps,
    this.searchProviders = const <String>[],
    this.extractionTemplates = const <String>[],
  });
}

// ---------------------------------------------------------------------------
// Auth profile
// ---------------------------------------------------------------------------

/// Refresh callback signature. Implementations may consult an IdP to mint
/// a new profile carrying fresh credentials. May throw on failure.
typedef BrowserAuthRefreshCallback =
    Future<BrowserAuthProfile> Function(BrowserAuthProfile expired);

/// A bundle of credentials that can be injected into a browser context to
/// impersonate a real user. Treated as immutable; refresh produces a new
/// instance.
class BrowserAuthProfile {
  /// Stable identifier (often the user's email/uid).
  final String id;

  /// Tenant the profile belongs to.
  final String tenantId;

  /// Optional human-readable label for UI/audit.
  final String? label;

  /// Cookies to inject into the context.
  final List<BrowserCookie> cookies;

  /// `localStorage` entries (all values are stringified by the consumer).
  final Map<String, String> localStorage;

  /// `sessionStorage` entries.
  final Map<String, String> sessionStorage;

  /// IndexedDB entries — `{dbName: {storeName: {key: value}}}`.
  /// Used by Firebase Auth to seed the `firebaseLocalStorageDb` database.
  final Map<String, Map<String, Map<String, dynamic>>> indexedDb;

  /// Extra request headers (e.g., Bearer tokens).
  final Map<String, String> headers;

  /// Wall-clock when the profile expires; `null` means no auto-expiry.
  final DateTime? expiresAt;

  /// Optional callback that mints a fresh profile from this expired one.
  final BrowserAuthRefreshCallback? refresh;

  BrowserAuthProfile({
    required this.id,
    required this.tenantId,
    this.label,
    List<BrowserCookie>? cookies,
    Map<String, String>? localStorage,
    Map<String, String>? sessionStorage,
    Map<String, Map<String, Map<String, dynamic>>>? indexedDb,
    Map<String, String>? headers,
    this.expiresAt,
    this.refresh,
  })  : cookies = List<BrowserCookie>.unmodifiable(
            cookies ?? const <BrowserCookie>[]),
        localStorage = Map<String, String>.unmodifiable(
            localStorage ?? const <String, String>{}),
        sessionStorage = Map<String, String>.unmodifiable(
            sessionStorage ?? const <String, String>{}),
        indexedDb = Map<String, Map<String, Map<String, dynamic>>>.unmodifiable(
            indexedDb ?? const <String, Map<String, Map<String, dynamic>>>{}),
        headers = Map<String, String>.unmodifiable(
            headers ?? const <String, String>{});

  /// Whether this profile has reached its [expiresAt] (UTC compared).
  bool isExpiredAt(DateTime now) {
    final exp = expiresAt;
    if (exp == null) return false;
    return !now.toUtc().isBefore(exp.toUtc());
  }

  /// Convert to a JSON-serializable map. Cookies/IndexedDB are encoded.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'tenantId': tenantId,
        if (label != null) 'label': label,
        'cookies': cookies.map((BrowserCookie c) => c.toJson()).toList(),
        'localStorage': localStorage,
        'sessionStorage': sessionStorage,
        'indexedDb': indexedDb,
        'headers': headers,
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      };

  /// Reverse of [toJson]; cookies are reconstructed from their JSON form.
  /// `refresh` is *not* serialized — hosts must re-attach it after load.
  factory BrowserAuthProfile.fromJson(Map<String, dynamic> json) {
    return BrowserAuthProfile(
      id: json['id'] as String,
      tenantId: json['tenantId'] as String,
      label: json['label'] as String?,
      cookies: (json['cookies'] as List<dynamic>?)
              ?.map((dynamic c) =>
                  _cookieFromJson(Map<String, dynamic>.from(c as Map)))
              .toList() ??
          const <BrowserCookie>[],
      localStorage: (json['localStorage'] as Map?)?.cast<String, String>() ??
          const <String, String>{},
      sessionStorage:
          (json['sessionStorage'] as Map?)?.cast<String, String>() ??
              const <String, String>{},
      indexedDb: _indexedDbFromJson(json['indexedDb'] as Map<dynamic, dynamic>?),
      headers: (json['headers'] as Map?)?.cast<String, String>() ??
          const <String, String>{},
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
    );
  }
}

Map<String, Map<String, Map<String, dynamic>>> _indexedDbFromJson(
  Map<dynamic, dynamic>? raw,
) {
  if (raw == null) return const <String, Map<String, Map<String, dynamic>>>{};
  return <String, Map<String, Map<String, dynamic>>>{
    for (final entry in raw.entries)
      entry.key.toString(): <String, Map<String, dynamic>>{
        for (final store in (entry.value as Map<dynamic, dynamic>).entries)
          store.key.toString(): Map<String, dynamic>.from(
              store.value as Map<dynamic, dynamic>),
      },
  };
}

BrowserCookie _cookieFromJson(Map<String, dynamic> json) => BrowserCookie(
      name: json['name'] as String,
      value: json['value'] as String,
      domain: json['domain'] as String?,
      path: json['path'] as String?,
      expires: json['expires'] != null
          ? DateTime.parse(json['expires'] as String)
          : null,
      httpOnly: json['httpOnly'] as bool? ?? false,
      secure: json['secure'] as bool? ?? false,
      sameSite: json['sameSite'] as String?,
    );

/// Lightweight metadata for `AuthProfileStore.list` — omits credential bytes.
class BrowserAuthProfileMeta {
  final String id;
  final String tenantId;
  final String? label;
  final DateTime? expiresAt;

  const BrowserAuthProfileMeta({
    required this.id,
    required this.tenantId,
    this.label,
    this.expiresAt,
  });

  factory BrowserAuthProfileMeta.fromProfile(BrowserAuthProfile p) =>
      BrowserAuthProfileMeta(
        id: p.id,
        tenantId: p.tenantId,
        label: p.label,
        expiresAt: p.expiresAt,
      );
}

// ---------------------------------------------------------------------------
// Extraction template
// ---------------------------------------------------------------------------

/// Selector dialect used by [BrowserSelectorRule].
enum BrowserSelectorMode { css, xpath, role, text }

/// Single field selector with extraction and optional transform chain.
class BrowserSelectorRule {
  /// Selector expression (dialect per [mode]).
  final String selector;

  /// Selector dialect.
  final BrowserSelectorMode mode;

  /// What to pull off matched nodes. One of `'text'`, `'html'`,
  /// `'innerHtml'`, or `'attr:<NAME>'`.
  final String extract;

  /// When true, returns a list; otherwise the first match (or null).
  final bool many;

  /// Ordered list of transform ids (registered in the runtime) applied to
  /// each extracted value.
  final List<String> transforms;

  const BrowserSelectorRule({
    required this.selector,
    this.mode = BrowserSelectorMode.css,
    this.extract = 'text',
    this.many = false,
    this.transforms = const <String>[],
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'selector': selector,
        'mode': mode.name,
        'extract': extract,
        'many': many,
        if (transforms.isNotEmpty) 'transforms': transforms,
      };

  factory BrowserSelectorRule.fromJson(Map<String, dynamic> json) {
    return BrowserSelectorRule(
      selector: json['selector'] as String,
      mode: json['mode'] != null
          ? BrowserSelectorMode.values.firstWhere(
              (BrowserSelectorMode m) => m.name == json['mode'] as String,
              orElse: () => BrowserSelectorMode.css,
            )
          : BrowserSelectorMode.css,
      extract: (json['extract'] as String?) ?? 'text',
      many: (json['many'] as bool?) ?? false,
      transforms: (json['transforms'] as List<dynamic>?)
              ?.map((dynamic e) => e as String)
              .toList(growable: false) ??
          const <String>[],
    );
  }
}

/// Post-selector transform applied to a named field's value.
class BrowserTransformStep {
  final String field;
  final String op;
  final Map<String, dynamic> params;

  const BrowserTransformStep({
    required this.field,
    required this.op,
    this.params = const <String, dynamic>{},
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'field': field,
        'op': op,
        if (params.isNotEmpty) 'params': params,
      };

  factory BrowserTransformStep.fromJson(Map<String, dynamic> json) {
    return BrowserTransformStep(
      field: json['field'] as String,
      op: json['op'] as String,
      params: (json['params'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }
}

/// Minimal output schema — a required field list and a name→type map.
/// Types: `'string'`, `'int'`, `'double'`, `'bool'`, `'array'`, `'object'`.
class BrowserOutputSchema {
  final List<String> required;
  final Map<String, String> properties;

  const BrowserOutputSchema({
    this.required = const <String>[],
    this.properties = const <String, String>{},
  });

  /// Returns the list of field names that failed validation.
  List<String> validate(Map<String, dynamic> value) {
    final failures = <String>[];
    for (final name in required) {
      if (!value.containsKey(name) || value[name] == null) {
        failures.add(name);
      }
    }
    return failures;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (required.isNotEmpty) 'required': required,
        if (properties.isNotEmpty) 'properties': properties,
      };

  factory BrowserOutputSchema.fromJson(Map<String, dynamic> json) {
    return BrowserOutputSchema(
      required: (json['required'] as List<dynamic>?)
              ?.map((dynamic e) => e as String)
              .toList(growable: false) ??
          const <String>[],
      properties: (json['properties'] as Map?)?.cast<String, String>() ??
          const <String, String>{},
    );
  }
}

/// Extraction template — mapping selectors to output fields with optional
/// post-transforms and an output schema.
class BrowserExtractionTemplate {
  final String id;
  final String version;
  final Map<String, BrowserSelectorRule> selectors;
  final List<BrowserTransformStep> transforms;
  final BrowserOutputSchema outputSchema;

  const BrowserExtractionTemplate({
    required this.id,
    required this.version,
    required this.selectors,
    this.transforms = const <BrowserTransformStep>[],
    this.outputSchema = const BrowserOutputSchema(),
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'version': version,
        'selectors': <String, dynamic>{
          for (final entry in selectors.entries) entry.key: entry.value.toJson(),
        },
        if (transforms.isNotEmpty)
          'transforms': transforms
              .map((BrowserTransformStep t) => t.toJson())
              .toList(growable: false),
        if (outputSchema.required.isNotEmpty ||
            outputSchema.properties.isNotEmpty)
          'outputSchema': outputSchema.toJson(),
      };

  factory BrowserExtractionTemplate.fromJson(Map<String, dynamic> json) {
    return BrowserExtractionTemplate(
      id: json['id'] as String,
      version: json['version'] as String,
      selectors: <String, BrowserSelectorRule>{
        for (final entry
            in (json['selectors'] as Map<dynamic, dynamic>).entries)
          entry.key.toString(): BrowserSelectorRule.fromJson(
              Map<String, dynamic>.from(entry.value as Map)),
      },
      transforms: (json['transforms'] as List<dynamic>?)
              ?.map((dynamic e) => BrowserTransformStep.fromJson(
                  Map<String, dynamic>.from(e as Map)))
              .toList(growable: false) ??
          const <BrowserTransformStep>[],
      outputSchema: json['outputSchema'] != null
          ? BrowserOutputSchema.fromJson(
              Map<String, dynamic>.from(json['outputSchema'] as Map))
          : const BrowserOutputSchema(),
    );
  }
}

/// Lightweight metadata for listing templates without decoding every blob.
class BrowserExtractionTemplateMeta {
  final String id;
  final String version;

  const BrowserExtractionTemplateMeta({
    required this.id,
    required this.version,
  });

  factory BrowserExtractionTemplateMeta.fromTemplate(
          BrowserExtractionTemplate t) =>
      BrowserExtractionTemplateMeta(id: t.id, version: t.version);
}

/// Error thrown when a template's output fails schema validation.
class BrowserExtractionSchemaError extends StateError {
  final Map<String, dynamic> partial;
  final List<String> missingFields;
  BrowserExtractionSchemaError(this.partial, this.missingFields)
      : super(
          'E3002 ExtractionTemplateInvalid: missing=${missingFields.join(',')}',
        );
}

// ---------------------------------------------------------------------------
// Download
// ---------------------------------------------------------------------------

/// Lifecycle state of a download.
enum BrowserDownloadStatus {
  started,
  inProgress,
  finished,
  failed,
  quarantined,
}

/// Identifier carriers for a download request. Either [url] (direct fetch)
/// or [contextId] + [trigger] (browser-initiated) — direct fetch is the
/// Phase 2 path; trigger mode is reserved for Phase 4.
class BrowserDownloadSpec {
  /// Direct URL fetch.
  final String? url;

  /// When set, the download is initiated via the engine (page-driven).
  /// The runtime is expected to resolve the resulting download via
  /// `subscribe(downloadFinished)`.
  final String? contextId;

  /// Optional explicit destination filename (default: derived from URL).
  final String? destFilename;

  /// Optional headers to send on the fetch.
  final Map<String, String>? headers;

  /// Maximum bytes to write before failing. `null` means use cap defaults.
  final int? maxBytes;

  /// Tenant scope (used for quota + isolation directory).
  final String tenantId;

  /// Optional context scope (used for isolation directory).
  final String? contextScopeId;

  const BrowserDownloadSpec({
    required this.tenantId,
    this.url,
    this.contextId,
    this.destFilename,
    this.headers,
    this.maxBytes,
    this.contextScopeId,
  });

  factory BrowserDownloadSpec.fromJson(Map<String, dynamic> json) {
    return BrowserDownloadSpec(
      tenantId: (json['tenantId'] as String?) ?? '_default',
      url: json['url'] as String?,
      contextId: json['contextId'] as String?,
      destFilename: json['destFilename'] as String?,
      headers: (json['headers'] as Map?)?.cast<String, String>(),
      maxBytes: json['maxBytes'] as int?,
      contextScopeId: json['contextScopeId'] as String?,
    );
  }
}

/// Persistable record of a single download attempt.
class BrowserDownloadDescriptor {
  final String id;
  final String tenantId;
  final String? contextScopeId;
  final String url;
  final String destPath;
  final String? sha256;
  final int sizeBytes;
  final String? mime;
  final BrowserDownloadStatus status;
  final DateTime startedAt;
  final DateTime? finishedAt;

  /// Optional error code on failure (E8001/E8002/E8003).
  final String? errorCode;

  const BrowserDownloadDescriptor({
    required this.id,
    required this.tenantId,
    required this.url,
    required this.destPath,
    required this.status,
    required this.startedAt,
    this.contextScopeId,
    this.sha256,
    this.sizeBytes = 0,
    this.mime,
    this.finishedAt,
    this.errorCode,
  });

  BrowserDownloadDescriptor copyWith({
    BrowserDownloadStatus? status,
    String? sha256,
    int? sizeBytes,
    String? mime,
    DateTime? finishedAt,
    String? errorCode,
    String? destPath,
  }) {
    return BrowserDownloadDescriptor(
      id: id,
      tenantId: tenantId,
      contextScopeId: contextScopeId,
      url: url,
      destPath: destPath ?? this.destPath,
      sha256: sha256 ?? this.sha256,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      mime: mime ?? this.mime,
      status: status ?? this.status,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      errorCode: errorCode ?? this.errorCode,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'tenantId': tenantId,
        if (contextScopeId != null) 'contextScopeId': contextScopeId,
        'url': url,
        'destPath': destPath,
        if (sha256 != null) 'sha256': sha256,
        'sizeBytes': sizeBytes,
        if (mime != null) 'mime': mime,
        'status': status.name,
        'startedAt': startedAt.toIso8601String(),
        if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
        if (errorCode != null) 'errorCode': errorCode,
      };

  factory BrowserDownloadDescriptor.fromJson(Map<String, dynamic> json) {
    return BrowserDownloadDescriptor(
      id: json['id'] as String,
      tenantId: json['tenantId'] as String,
      contextScopeId: json['contextScopeId'] as String?,
      url: json['url'] as String,
      destPath: json['destPath'] as String,
      sha256: json['sha256'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      mime: json['mime'] as String?,
      status: BrowserDownloadStatus.values.firstWhere(
        (BrowserDownloadStatus s) => s.name == json['status'],
        orElse: () => BrowserDownloadStatus.failed,
      ),
      startedAt: DateTime.parse(json['startedAt'] as String),
      finishedAt: json['finishedAt'] != null
          ? DateTime.parse(json['finishedAt'] as String)
          : null,
      errorCode: json['errorCode'] as String?,
    );
  }
}

/// Progress / lifecycle event emitted while downloads are in flight.
class BrowserDownloadEvent {
  final BrowserDownloadStatus kind;
  final BrowserDownloadDescriptor descriptor;
  final int? bytesWritten;
  final int? totalBytes;

  const BrowserDownloadEvent({
    required this.kind,
    required this.descriptor,
    this.bytesWritten,
    this.totalBytes,
  });
}

/// Virus scan port — host wires ClamAV / VirusTotal / etc.
abstract class BrowserVirusScanPort {
  Future<BrowserVirusScanResult> scan(String filePath);
}

class BrowserVirusScanResult {
  final bool clean;
  final String? threat;
  final Map<String, dynamic> raw;

  const BrowserVirusScanResult({
    required this.clean,
    this.threat,
    this.raw = const <String, dynamic>{},
  });
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

/// Mode an adapter uses to talk to a search provider.
enum BrowserSearchMode { api, browser }

/// Search intent / vertical.
enum BrowserSearchIntent { web, news, images, videos, academic }

/// Options carried into a [BrowserSearchPort.search] call.
class BrowserSearchOptions {
  /// Override the adapter's preferred mode. When `null` the adapter picks.
  final BrowserSearchMode? mode;

  /// Maximum results to return. Defaults to 10.
  final int limit;

  /// Pagination offset.
  final int offset;

  /// Vertical / intent.
  final BrowserSearchIntent intent;

  /// Optional ISO 639-1 language hint (e.g. `'ko'`).
  final String? language;

  /// Optional ISO 3166-1 region hint (e.g. `'KR'`).
  final String? region;

  /// Cache TTL. `Duration.zero` disables caching for this call.
  final Duration cacheTtl;

  const BrowserSearchOptions({
    this.mode,
    this.limit = 10,
    this.offset = 0,
    this.intent = BrowserSearchIntent.web,
    this.language,
    this.region,
    this.cacheTtl = const Duration(hours: 1),
  });

  /// Stable cache hash for `(query, provider, options)` triple.
  String hashFor(String providerId, String query) {
    final buffer = StringBuffer()
      ..write(providerId)
      ..write('|')
      ..write(query.trim().toLowerCase())
      ..write('|')
      ..write(intent.name)
      ..write('|')
      ..write(limit)
      ..write('|')
      ..write(offset)
      ..write('|')
      ..write(language ?? '')
      ..write('|')
      ..write(region ?? '')
      ..write('|')
      ..write(mode?.name ?? '');
    return buffer.toString();
  }
}

/// One search result.
class BrowserSearchResult {
  final String title;
  final String url;
  final String? snippet;
  final String? source;
  final DateTime? published;
  final int rank;

  const BrowserSearchResult({
    required this.title,
    required this.url,
    this.snippet,
    this.source,
    this.published,
    this.rank = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'url': url,
        if (snippet != null) 'snippet': snippet,
        if (source != null) 'source': source,
        if (published != null) 'published': published!.toIso8601String(),
        'rank': rank,
      };

  factory BrowserSearchResult.fromJson(Map<String, dynamic> json) {
    return BrowserSearchResult(
      title: json['title'] as String,
      url: json['url'] as String,
      snippet: json['snippet'] as String?,
      source: json['source'] as String?,
      published: json['published'] != null
          ? DateTime.parse(json['published'] as String)
          : null,
      rank: (json['rank'] as num?)?.toInt() ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Crawl + Monitor
// ---------------------------------------------------------------------------

/// Deduplication strategy during a crawl.
enum BrowserDedupStrategy { urlCanonical, contentHash, both }

/// Lifecycle of a [BrowserCrawlHandle] analogue.
enum BrowserCrawlState { running, paused, completed, stopped, failed }

/// Crawl configuration.
class BrowserCrawlPolicy {
  /// Maximum link-follow depth from a seed.
  final int depth;

  /// Maximum pages to visit across the entire crawl.
  final int breadth;

  /// Per-domain throughput cap (requests/second). `0` disables rate limit.
  final double ratePerDomain;

  /// Worker concurrency.
  final int concurrency;

  /// Honor robots.txt (default true).
  final bool respectRobots;

  /// Only follow links on these domains. Empty = unrestricted.
  final List<String> allowedDomains;

  /// Dedup mode.
  final BrowserDedupStrategy dedupStrategy;

  /// Navigation retry count on failure.
  final int maxNavigateRetries;

  const BrowserCrawlPolicy({
    this.depth = 1,
    this.breadth = 50,
    this.ratePerDomain = 1.0,
    this.concurrency = 1,
    this.respectRobots = true,
    this.allowedDomains = const <String>[],
    this.dedupStrategy = BrowserDedupStrategy.both,
    this.maxNavigateRetries = 3,
  });

  /// Validate simple invariants; throws [ArgumentError] on violation.
  void validate() {
    if (depth < 0) {
      throw ArgumentError('CrawlPolicy.depth must be >= 0');
    }
    if (breadth < 0) {
      throw ArgumentError('CrawlPolicy.breadth must be >= 0');
    }
    if (ratePerDomain < 0) {
      throw ArgumentError('CrawlPolicy.ratePerDomain must be >= 0');
    }
    if (concurrency < 1) {
      throw ArgumentError('CrawlPolicy.concurrency must be >= 1');
    }
    if (maxNavigateRetries < 0) {
      throw ArgumentError('CrawlPolicy.maxNavigateRetries must be >= 0');
    }
  }
}

/// Reason a page was skipped (or visited).
enum BrowserCrawlEventKind {
  visited,
  skippedPolicy,
  skippedRobots,
  deduped,
  failed,
}

/// Emitted by [CrawlScheduler] during a run.
class BrowserCrawlProgressEvent {
  final BrowserCrawlEventKind kind;
  final String url;
  final int depth;
  final String? contentHash;
  final String? errorCode;
  final String? errorMessage;
  final DateTime timestamp;

  BrowserCrawlProgressEvent({
    required this.kind,
    required this.url,
    required this.depth,
    this.contentHash,
    this.errorCode,
    this.errorMessage,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Emitted by a monitor when the observed URL changes or fails.
enum BrowserMonitorEventKind { changed, unchanged, error }

class BrowserMonitorEvent {
  final BrowserMonitorEventKind kind;
  final String url;
  final String? contentHash;
  final String? errorMessage;
  final DateTime timestamp;

  BrowserMonitorEvent({
    required this.kind,
    required this.url,
    this.contentHash,
    this.errorMessage,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Self-description of a registered search adapter.
class BrowserSearchProviderDescriptor {
  final String id;
  final String name;

  /// Mode(s) this adapter supports. Most adapters report a single mode but
  /// hybrid adapters may advertise both.
  final Set<BrowserSearchMode> supportedModes;

  /// Verticals this adapter handles.
  final Set<BrowserSearchIntent> supportedIntents;

  /// Whether the adapter requires an API key (for API-mode adapters).
  final bool requiresKey;

  const BrowserSearchProviderDescriptor({
    required this.id,
    required this.name,
    required this.supportedModes,
    this.supportedIntents = const <BrowserSearchIntent>{
      BrowserSearchIntent.web,
    },
    this.requiresKey = false,
  });

  bool supports(BrowserSearchMode mode) => supportedModes.contains(mode);
}
