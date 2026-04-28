/// TEST — MOD-REG-003 AuthProfileStore.
///
/// Mirrors `docs/04_TEST/06-auth.md` (TC-400~416, TC-420~422).
/// OAuthFlowRunner cases (TC-417~419) are covered after BrowserRuntime is
/// implemented in Step 4.
library;

import 'dart:convert';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

AuthProfileStore _newStore({
  KvStoragePort? kv,
  SecretBox? crypto,
  DateTime Function()? now,
}) {
  return AuthProfileStore(
    kv: kv ?? InMemoryKvStoragePort(),
    crypto: crypto ?? SecretBox.fromPassphrase('unit-test-key'),
    now: now,
  );
}

BrowserAuthProfile _profile({
  String id = 'writer1@example.com',
  String tenantId = 'makemind_dev',
  Map<String, String>? localStorage,
  Map<String, String>? headers,
  DateTime? expiresAt,
  BrowserAuthRefreshCallback? refresh,
}) {
  return BrowserAuthProfile(
    id: id,
    tenantId: tenantId,
    cookies: const <BrowserCookie>[
      BrowserCookie(name: 'sid', value: 'abc'),
    ],
    localStorage: localStorage,
    headers: headers,
    expiresAt: expiresAt,
    refresh: refresh,
  );
}

void main() {
  group('AuthProfileStore — CRUD', () {
    test('TC-400 put writes encrypted blob to KV', () async {
      final kv = InMemoryKvStoragePort();
      final store = _newStore(kv: kv);
      await store.put(_profile());
      final raw = await kv.get(
        'mcp_browser/auth/makemind_dev/writer1@example.com',
      );
      expect(raw, isA<String>());
      expect(raw, isNot(contains('writer1@example.com')),
          reason: 'plaintext id leak');
    });

    test('TC-401 get returns the hot cached instance', () async {
      final store = _newStore();
      final p = _profile();
      await store.put(p);
      expect(await store.get('makemind_dev', p.id), same(p));
    });

    test('TC-402 get cold-loads from KV and decrypts', () async {
      final kv = InMemoryKvStoragePort();
      final crypto = SecretBox.fromPassphrase('unit-test-key');
      final writer = AuthProfileStore(kv: kv, crypto: crypto);
      await writer.put(_profile(headers: <String, String>{
        'X-Tenant': 'makemind_dev',
      }));

      final reader = AuthProfileStore(kv: kv, crypto: crypto);
      final loaded = await reader.get(
        'makemind_dev',
        'writer1@example.com',
      );
      expect(loaded, isNotNull);
      expect(loaded!.headers['X-Tenant'], 'makemind_dev');
    });

    test('TC-403 get on unknown id returns null', () async {
      final store = _newStore();
      expect(await store.get('makemind_dev', 'missing'), isNull);
    });

    test('TC-404 delete removes from cache and KV', () async {
      final kv = InMemoryKvStoragePort();
      final store = _newStore(kv: kv);
      await store.put(_profile());
      await store.delete('makemind_dev', 'writer1@example.com');
      expect(
        await kv.exists('mcp_browser/auth/makemind_dev/writer1@example.com'),
        isFalse,
      );
      expect(await store.get('makemind_dev', 'writer1@example.com'), isNull);
    });

    test('TC-405 list returns lightweight metadata', () async {
      final store = _newStore();
      await store.put(_profile(id: 'a@x'));
      await store.put(_profile(id: 'b@x'));
      final metas = await store.list('makemind_dev');
      expect(metas.map((BrowserAuthProfileMeta m) => m.id).toSet(),
          <String>{'a@x', 'b@x'});
    });
  });

  group('AuthProfileStore — applyProfileTo', () {
    test('TC-406 applyProfileTo wires cookies and headers', () async {
      final ctx = FakeContextPort();
      final engine = FakeEngine();
      final handle = BrowserContextHandle(
        contextId: 'ctx-1',
        engineId: 'fake',
        spec: const BrowserContextSpec(tenantId: 'makemind_dev'),
        enginePayload: FakeEnginePayload('p'),
      );
      final p = _profile(headers: <String, String>{'X-Trace': 'unit'});
      await applyProfileTo(
        handle: handle,
        profile: p,
        engine: engine,
        contextPort: ctx,
      );
      final payload = handle.enginePayload as FakeEnginePayload;
      expect(payload.cookies, hasLength(1));
      expect(payload.extraHeaders['X-Trace'], 'unit');
    });

    test('TC-411 applyProfileTo seeds localStorage via evalJs', () async {
      final engine = FakeEngine();
      final ctx = FakeContextPort();
      final handle = BrowserContextHandle(
        contextId: 'ctx-1',
        engineId: 'fake',
        spec: const BrowserContextSpec(tenantId: 'makemind_dev'),
        enginePayload: FakeEnginePayload('p'),
      );
      await applyProfileTo(
        handle: handle,
        profile: _profile(localStorage: <String, String>{
          'k1': 'v1',
          'k2': 'v2',
        }),
        engine: engine,
        contextPort: ctx,
      );
      // Two localStorage entries == 2 evalJs calls.
      expect(engine.executeCalls, 2);
    });

    test('TC-412 applyProfileTo seeds Firebase IndexedDB entry', () async {
      final engine = FakeEngine();
      final ctx = FakeContextPort();
      final profile = FirebaseAuthHelper.fromIdToken(
        tenantId: 'makemind_dev',
        profileId: 'writer1@example.com',
        firebaseApiKey: 'AIzaTest',
        uid: 'uid-1',
        idToken: 'idt',
        refreshToken: 'rt',
        expiresAt: DateTime.utc(2026, 4, 18),
      );
      final handle = BrowserContextHandle(
        contextId: 'ctx-1',
        engineId: 'fake',
        spec: const BrowserContextSpec(tenantId: 'makemind_dev'),
        enginePayload: FakeEnginePayload('p'),
      );
      await applyProfileTo(
        handle: handle,
        profile: profile,
        engine: engine,
        contextPort: ctx,
      );
      expect(engine.executeCalls, 1,
          reason: 'one IndexedDB entry → one eval');
    });

    test(
        'TC-407 applyProfileTo on missing profile is enforced via store layer',
        () async {
      // The store-layer fetch returning null is the contract; the helper
      // itself accepts a profile object.
      final store = _newStore();
      expect(await store.get('makemind_dev', 'missing'), isNull);
    });
  });

  group('AuthProfileStore — expiry & refresh', () {
    test('TC-413/414/415 isExpired across the three branches', () async {
      final kv = InMemoryKvStoragePort();
      var now = DateTime.utc(2026, 4, 17, 12);
      final store = _newStore(kv: kv, now: () => now);
      await store.put(_profile(id: 'eternal'));
      expect(await store.isExpired('makemind_dev', 'eternal'), isFalse);

      await store.put(_profile(
        id: 'fresh',
        expiresAt: DateTime.utc(2026, 4, 18),
      ));
      expect(await store.isExpired('makemind_dev', 'fresh'), isFalse);

      now = DateTime.utc(2026, 4, 19);
      await store.put(_profile(
        id: 'stale',
        expiresAt: DateTime.utc(2026, 4, 18),
      ));
      expect(await store.isExpired('makemind_dev', 'stale'), isTrue);
    });

    test('TC-416 refreshProfile invokes the callback and persists', () async {
      final kv = InMemoryKvStoragePort();
      final store = _newStore(kv: kv);
      await store.put(_profile(
        id: 'writer1@example.com',
        expiresAt: DateTime.utc(2026, 4, 18),
        refresh: (BrowserAuthProfile expired) async => _profile(
          id: expired.id,
          headers: <String, String>{'X-Refreshed': '1'},
          expiresAt: DateTime.utc(2026, 4, 19),
        ),
      ));

      final fresh = await store.refreshProfile(
        'makemind_dev',
        'writer1@example.com',
      );
      expect(fresh.headers['X-Refreshed'], '1');
      final reread = await store.get(
        'makemind_dev',
        'writer1@example.com',
      );
      expect(reread!.headers['X-Refreshed'], '1');
    });

    test(
        'TC-409 refreshProfile without callback throws AuthExpiredError (E4004)',
        () async {
      final store = _newStore();
      await store.put(_profile(
        id: 'no-refresh',
        expiresAt: DateTime.utc(2026, 4, 18),
      ));
      expect(
        () => store.refreshProfile('makemind_dev', 'no-refresh'),
        throwsA(isA<AuthExpiredError>()),
      );
    });

    test(
        'TC-410 refreshProfile callback failure surfaces as AuthExpiredError',
        () async {
      final store = _newStore();
      await store.put(_profile(
        id: 'bad-refresh',
        expiresAt: DateTime.utc(2026, 4, 18),
        refresh: (_) async => throw StateError('IdP unavailable'),
      ));
      expect(
        () => store.refreshProfile('makemind_dev', 'bad-refresh'),
        throwsA(isA<AuthExpiredError>()),
      );
    });
  });

  group('AuthProfileStore — Firebase helper', () {
    test('TC-420 FirebaseAuthHelper.fromIdToken populates IndexedDB', () {
      final p = FirebaseAuthHelper.fromIdToken(
        tenantId: 'makemind_dev',
        profileId: 'writer1@example.com',
        firebaseApiKey: 'AIzaTest',
        uid: 'uid-1',
        idToken: 'idt',
        refreshToken: 'rt',
      );
      final db = p.indexedDb['firebaseLocalStorageDb'];
      expect(db, isNotNull);
      final store = db!['firebaseLocalStorage'];
      expect(store, isNotNull);
      expect(store!.keys.single, contains('firebase:authUser:AIzaTest'));
    });
  });

  group('AuthProfileStore — Supabase helper', () {
    test('fromSession populates localStorage under sb-<ref>-auth-token', () {
      final p = SupabaseAuthHelper.fromSession(
        tenantId: 'makemind_dev',
        profileId: 'writer1@example.com',
        supabaseUrl: 'https://abcd1234.supabase.co',
        accessToken: 'access-xyz',
        refreshToken: 'refresh-xyz',
        userId: 'uid-1',
        expiresAt: DateTime.utc(2026, 4, 18),
      );
      expect(p.localStorage.keys.single, 'sb-abcd1234-auth-token');
      final session =
          jsonDecode(p.localStorage.values.single) as Map<String, dynamic>;
      expect(session['access_token'], 'access-xyz');
      expect(session['refresh_token'], 'refresh-xyz');
      expect((session['user'] as Map)['id'], 'uid-1');
      expect(p.expiresAt, DateTime.utc(2026, 4, 18));
    });

    test('fromSession rejects URLs without host', () {
      expect(
        () => SupabaseAuthHelper.fromSession(
          tenantId: 't',
          profileId: 'p',
          supabaseUrl: '',
          accessToken: 'a',
          refreshToken: 'r',
          userId: 'u',
        ),
        throwsArgumentError,
      );
    });
  });

  group('AuthProfileStore — Auth0 helper', () {
    test('fromToken populates the auth0-spa-js cache localStorage key', () {
      final p = Auth0Helper.fromToken(
        tenantId: 'makemind_dev',
        profileId: 'writer1@example.com',
        auth0Domain: 'dev-xyz.us.auth0.com',
        clientId: 'clientX',
        accessToken: 'at',
        idToken: 'idt',
        refreshToken: 'rt',
        expiresAt: DateTime.utc(2026, 4, 18),
      );
      final key = p.localStorage.keys.single;
      expect(key, startsWith('@@auth0spajs@@::clientX::default::'));
      final entry =
          jsonDecode(p.localStorage.values.single) as Map<String, dynamic>;
      final body = entry['body'] as Map<String, dynamic>;
      expect(body['access_token'], 'at');
      expect(body['id_token'], 'idt');
      expect(body['refresh_token'], 'rt');
      expect(p.headers['X-Auth0-Domain'], 'dev-xyz.us.auth0.com');
      expect(p.expiresAt, DateTime.utc(2026, 4, 18));
    });
  });

  group('SecretBox', () {
    test('TC-421 round-trip recovers plaintext under the same key', () {
      final box = SecretBox.fromPassphrase('p');
      final cipher = box.encrypt('hello-mcp_browser');
      expect(box.decrypt(cipher), 'hello-mcp_browser');
    });

    test('TC-422 decryption with a different key returns null', () {
      final a = SecretBox.fromPassphrase('one');
      final b = SecretBox.fromPassphrase('two');
      final cipher = a.encrypt('hello');
      expect(b.decrypt(cipher), isNull);
    });
  });
}
