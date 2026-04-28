/// BrowserAuthProfilePort - persistence + injection contract for credentials.
///
/// Hosts back this with their preferred secret store. The default
/// implementation lives in mcp_browser (`AuthProfileStore`) and uses a
/// host-supplied `KvStoragePort` plus a `SecretBox` for encryption.
library;

import '../types/browser_types.dart';

/// Storage and injection of [BrowserAuthProfile] instances.
abstract class BrowserAuthProfilePort {
  /// Persist [profile]. Existing entries with the same `(tenantId, id)` are
  /// overwritten.
  Future<void> put(BrowserAuthProfile profile);

  /// Fetch a profile by `(tenantId, id)`; returns `null` when not found or
  /// when decryption fails.
  Future<BrowserAuthProfile?> get(String tenantId, String id);

  /// Remove a profile.
  Future<void> delete(String tenantId, String id);

  /// Lightweight metadata listing.
  Future<List<BrowserAuthProfileMeta>> list(String tenantId);

  /// True when the stored profile has crossed its `expiresAt`.
  Future<bool> isExpired(String tenantId, String id);

  /// Mint a fresh profile via the stored profile's `refresh` callback,
  /// persist it, and return it. Throws when no callback was supplied or the
  /// callback fails.
  Future<BrowserAuthProfile> refreshProfile(String tenantId, String id);
}
