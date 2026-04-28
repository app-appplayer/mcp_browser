/// In-package convenience barrel used by mcp_browser's own source files.
///
/// Pulls together the browser-local types + ports from this package and a
/// narrow slice of mcp_bundle (generic capability pool) so that sources
/// can write `import '../_internal.dart';` (or the appropriate relative
/// path) instead of stacking multiple imports.
library;

// Generic capability pool types from mcp_bundle (KV only — we intentionally
// do NOT pull Philosophy/Skill domain types into this capability package).
export 'package:mcp_bundle/mcp_bundle.dart' show
    KvStoragePort,
    InMemoryKvStoragePort;

// Browser-local types + ports.
export 'types/browser_types.dart';
export 'ports/browser_audit_port.dart';
export 'ports/browser_auth_profile_port.dart';
export 'ports/browser_context_port.dart';
export 'ports/browser_download_port.dart';
export 'ports/browser_engine_port.dart';
export 'ports/browser_extraction_template_port.dart';
export 'ports/browser_policy_port.dart';
export 'ports/browser_search_port.dart';
