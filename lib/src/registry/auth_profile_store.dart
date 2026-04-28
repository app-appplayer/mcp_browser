/// MOD-REG-003 — AuthProfileStore implementation.
///
/// See `docs/03_DDD/06-auth.md` for the design specification and
/// `docs/04_TEST/06-auth.md` for the test plan.
library;

import 'dart:convert';

import '../_internal.dart';

import 'secret_box.dart';

/// Error thrown when no profile exists for `(tenantId, id)`.
class AuthProfileNotFoundError extends StateError {
  AuthProfileNotFoundError(String tenantId, String id)
      : super('E4001 AuthProfileNotFound: $tenantId/$id');
}

/// Error thrown when applying a profile to a context fails at the engine.
class AuthInjectionFailedError extends StateError {
  AuthInjectionFailedError(String reason)
      : super('E4002 AuthInjectionFailed: $reason');
}

/// Error thrown when an expired profile cannot be refreshed.
class AuthExpiredError extends StateError {
  AuthExpiredError(String tenantId, String id, String reason)
      : super('E4004 AuthExpired: $tenantId/$id ($reason)');
}

/// Storage + lifecycle for browser auth profiles. Implements
/// [BrowserAuthProfilePort]; profile injection into a live context is
/// handled by [applyProfileTo] (top-level helper, kept separate so the
/// store remains BrowserRuntime-agnostic).
class AuthProfileStore implements BrowserAuthProfilePort {

  AuthProfileStore({
    required this.kv,
    required this.crypto,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final KvStoragePort kv;
  final SecretBox crypto;
  final DateTime Function() _now;

  /// In-memory decrypted cache, keyed by `tenantId/id`.
  final Map<String, BrowserAuthProfile> _hot = <String, BrowserAuthProfile>{};

  /// Refresh callbacks are not persisted to KV; reattach them after load.
  final Map<String, BrowserAuthRefreshCallback> _refreshCallbacks =
      <String, BrowserAuthRefreshCallback>{};

  @override
  Future<void> put(BrowserAuthProfile profile) async {
    final hotKey = _key(profile.tenantId, profile.id);
    _hot[hotKey] = profile;
    if (profile.refresh != null) {
      _refreshCallbacks[hotKey] = profile.refresh!;
    }
    final encoded = jsonEncode(profile.toJson());
    final cipher = crypto.encrypt(encoded);
    await kv.set(_kvKey(profile.tenantId, profile.id), cipher);
  }

  @override
  Future<BrowserAuthProfile?> get(String tenantId, String id) async {
    final hotKey = _key(tenantId, id);
    final cached = _hot[hotKey];
    if (cached != null) return cached;
    final raw = await kv.get(_kvKey(tenantId, id));
    if (raw is! String) return null;
    final plain = crypto.decrypt(raw);
    if (plain == null) return null;
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(plain) as Map);
    } on Object {
      return null;
    }
    final profile = BrowserAuthProfile.fromJson(json);
    final reattached = _refreshCallbacks[hotKey];
    final hydrated = reattached != null
        ? _withCallback(profile, reattached)
        : profile;
    _hot[hotKey] = hydrated;
    return hydrated;
  }

  @override
  Future<void> delete(String tenantId, String id) async {
    final hotKey = _key(tenantId, id);
    _hot.remove(hotKey);
    _refreshCallbacks.remove(hotKey);
    await kv.remove(_kvKey(tenantId, id));
  }

  @override
  Future<List<BrowserAuthProfileMeta>> list(String tenantId) async {
    final prefix = _kvPrefix(tenantId);
    final keys = await kv.keys(prefix: prefix);
    final out = <BrowserAuthProfileMeta>[];
    for (final key in keys) {
      final id = key.substring(prefix.length);
      final profile = await get(tenantId, id);
      if (profile != null) {
        out.add(BrowserAuthProfileMeta.fromProfile(profile));
      }
    }
    return out;
  }

  @override
  Future<bool> isExpired(String tenantId, String id) async {
    final profile = await get(tenantId, id);
    if (profile == null) return false;
    return profile.isExpiredAt(_now());
  }

  @override
  Future<BrowserAuthProfile> refreshProfile(String tenantId, String id) async {
    final profile = await get(tenantId, id);
    if (profile == null) throw AuthProfileNotFoundError(tenantId, id);
    final cb = profile.refresh ?? _refreshCallbacks[_key(tenantId, id)];
    if (cb == null) {
      throw AuthExpiredError(tenantId, id, 'no refresh callback registered');
    }
    BrowserAuthProfile fresh;
    try {
      fresh = await cb(profile);
    } on Object catch (e) {
      throw AuthExpiredError(tenantId, id, 'refresh failed: $e');
    }
    await put(fresh);
    return fresh;
  }

  // -------------------------------------------------------------------------

  static String _key(String tenantId, String id) => '$tenantId/$id';

  static String _kvPrefix(String tenantId) =>
      'mcp_browser/auth/$tenantId/';

  static String _kvKey(String tenantId, String id) =>
      '${_kvPrefix(tenantId)}$id';

  static BrowserAuthProfile _withCallback(
    BrowserAuthProfile profile,
    BrowserAuthRefreshCallback cb,
  ) {
    return BrowserAuthProfile(
      id: profile.id,
      tenantId: profile.tenantId,
      label: profile.label,
      cookies: profile.cookies,
      localStorage: profile.localStorage,
      sessionStorage: profile.sessionStorage,
      indexedDb: profile.indexedDb,
      headers: profile.headers,
      expiresAt: profile.expiresAt,
      refresh: cb,
    );
  }
}

// ---------------------------------------------------------------------------
// applyProfileTo — bridges Store to a live engine/context.
// ---------------------------------------------------------------------------

/// Apply [profile] to [handle] using [engine] + [contextPort].
///
/// 1. Cookies + extra headers go through the lifecycle port.
/// 2. localStorage / sessionStorage / indexedDb entries are seeded by
///    issuing `evalJs` actions against the engine.
///
/// Throws [AuthInjectionFailedError] when the engine reports failure.
Future<void> applyProfileTo({
  required BrowserContextHandle handle,
  required BrowserAuthProfile profile,
  required BrowserEnginePort engine,
  required BrowserContextPort contextPort,
}) async {
  await contextPort.setCookies(handle, profile.cookies);
  await contextPort.setExtraHeaders(handle, profile.headers);

  Future<void> exec(String expression) async {
    final result = await engine.execute(handle, BrowserAction.evalJs(expression));
    if (!result.success) {
      throw AuthInjectionFailedError(
          result.errorMessage ?? result.errorCode ?? 'unknown');
    }
  }

  for (final entry in profile.localStorage.entries) {
    await exec(
      'localStorage.setItem(${jsonEncode(entry.key)}, ${jsonEncode(entry.value)})',
    );
  }
  for (final entry in profile.sessionStorage.entries) {
    await exec(
      'sessionStorage.setItem(${jsonEncode(entry.key)}, ${jsonEncode(entry.value)})',
    );
  }
  for (final db in profile.indexedDb.entries) {
    for (final store in db.value.entries) {
      for (final kv in store.value.entries) {
        final scriptArgs = <String, dynamic>{
          'db': db.key,
          'store': store.key,
          'key': kv.key,
          'value': kv.value,
        };
        await exec(_idbInsertScript(scriptArgs));
      }
    }
  }
}

String _idbInsertScript(Map<String, dynamic> args) {
  // Browser-side helper expected to exist; engines that need a different
  // bootstrap should override the script via a future hook.
  return 'window.__mcpBrowserIdbInsert(${jsonEncode(args)})';
}

// ---------------------------------------------------------------------------
// FirebaseAuthHelper — produce a profile that mirrors the Firebase Auth
// client SDK's IndexedDB schema.
// ---------------------------------------------------------------------------

class FirebaseAuthHelper {
  FirebaseAuthHelper._();

  /// Build a [BrowserAuthProfile] that, when injected, will let the Firebase
  /// Auth client SDK pick up an authenticated session for `[uid]`.
  static BrowserAuthProfile fromIdToken({
    required String tenantId,
    required String profileId,
    required String firebaseApiKey,
    required String uid,
    required String idToken,
    required String refreshToken,
    DateTime? expiresAt,
    String label = 'firebase',
  }) {
    final entry = <String, dynamic>{
      'uid': uid,
      'stsTokenManager': <String, dynamic>{
        'accessToken': idToken,
        'refreshToken': refreshToken,
        if (expiresAt != null)
          'expirationTime': expiresAt.toUtc().millisecondsSinceEpoch,
      },
      'apiKey': firebaseApiKey,
      'appName': '[DEFAULT]',
    };
    final key = 'firebase:authUser:$firebaseApiKey:[DEFAULT]';
    return BrowserAuthProfile(
      id: profileId,
      tenantId: tenantId,
      label: label,
      indexedDb: <String, Map<String, Map<String, dynamic>>>{
        'firebaseLocalStorageDb': <String, Map<String, dynamic>>{
          'firebaseLocalStorage': <String, dynamic>{key: entry},
        },
      },
      expiresAt: expiresAt,
    );
  }
}

// ---------------------------------------------------------------------------
// SupabaseAuthHelper — produce a profile mirroring `supabase-js` localStorage
// layout. The JS client stores the session JSON under
// `sb-<projectRef>-auth-token`, keyed by the project ref derived from the
// Supabase URL (e.g. `https://abcd1234.supabase.co` → `abcd1234`).
// ---------------------------------------------------------------------------

class SupabaseAuthHelper {
  SupabaseAuthHelper._();

  /// Build a [BrowserAuthProfile] compatible with supabase-js.
  ///
  /// [supabaseUrl] is the project URL (e.g. `https://abcd1234.supabase.co`);
  /// the project ref is extracted from the first host label.
  static BrowserAuthProfile fromSession({
    required String tenantId,
    required String profileId,
    required String supabaseUrl,
    required String accessToken,
    required String refreshToken,
    required String userId,
    String tokenType = 'bearer',
    DateTime? expiresAt,
    String? providerToken,
    String? providerRefreshToken,
    String label = 'supabase',
  }) {
    final projectRef = _extractSupabaseProjectRef(supabaseUrl);
    final expiresAtSec = expiresAt?.toUtc().millisecondsSinceEpoch ?? 0;
    final expiresIn = expiresAt != null
        ? expiresAt
                .toUtc()
                .difference(DateTime.now().toUtc())
                .inSeconds
                .clamp(0, 1 << 31)
        : 3600;
    final session = <String, dynamic>{
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'token_type': tokenType,
      'expires_in': expiresIn,
      if (expiresAt != null) 'expires_at': expiresAtSec ~/ 1000,
      if (providerToken != null) 'provider_token': providerToken,
      if (providerRefreshToken != null)
        'provider_refresh_token': providerRefreshToken,
      'user': <String, dynamic>{'id': userId},
    };
    return BrowserAuthProfile(
      id: profileId,
      tenantId: tenantId,
      label: label,
      localStorage: <String, String>{
        'sb-$projectRef-auth-token': jsonEncode(session),
      },
      expiresAt: expiresAt,
    );
  }

  static String _extractSupabaseProjectRef(String supabaseUrl) {
    final uri = Uri.parse(supabaseUrl);
    final host = uri.host;
    if (host.isEmpty) {
      throw ArgumentError.value(
          supabaseUrl, 'supabaseUrl', 'URL must include a host');
    }
    final firstLabel = host.split('.').first;
    if (firstLabel.isEmpty) {
      throw ArgumentError.value(
          supabaseUrl, 'supabaseUrl', 'cannot derive project ref');
    }
    return firstLabel;
  }
}

// ---------------------------------------------------------------------------
// Auth0Helper — produce a profile mirroring `@auth0/auth0-spa-js` localStorage
// layout. When `useRefreshTokens=true`, the SPA SDK writes cache entries under
// keys shaped as `@@auth0spajs@@::<clientId>::<audience>::<scope>`.
// ---------------------------------------------------------------------------

class Auth0Helper {
  Auth0Helper._();

  /// Build a [BrowserAuthProfile] compatible with `auth0-spa-js`.
  static BrowserAuthProfile fromToken({
    required String tenantId,
    required String profileId,
    required String auth0Domain,
    required String clientId,
    required String accessToken,
    String audience = 'default',
    String scope = 'openid profile email',
    String tokenType = 'Bearer',
    String? idToken,
    String? refreshToken,
    DateTime? expiresAt,
    String label = 'auth0',
  }) {
    final expiresIn = expiresAt != null
        ? expiresAt
                .toUtc()
                .difference(DateTime.now().toUtc())
                .inSeconds
                .clamp(0, 1 << 31)
        : 3600;
    final cacheKey =
        '@@auth0spajs@@::$clientId::$audience::$scope';
    final entry = <String, dynamic>{
      'body': <String, dynamic>{
        'client_id': clientId,
        'audience': audience,
        'scope': scope,
        'access_token': accessToken,
        if (idToken != null) 'id_token': idToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
        'expires_in': expiresIn,
        'token_type': tokenType,
        'decodedToken': <String, dynamic>{},
      },
      if (expiresAt != null)
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    };
    return BrowserAuthProfile(
      id: profileId,
      tenantId: tenantId,
      label: label,
      localStorage: <String, String>{cacheKey: jsonEncode(entry)},
      headers: <String, String>{
        'X-Auth0-Domain': auth0Domain,
      },
      expiresAt: expiresAt,
    );
  }
}
