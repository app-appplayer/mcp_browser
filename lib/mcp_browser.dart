/// mcp_browser — Universal Web Automation Backbone.
///
/// Public surface re-exports the 4-Primitive Contract types from
/// `mcp_bundle` plus the runtime modules implemented in this package.
library;

// Generic capability pool port re-exported from mcp_bundle.
export 'package:mcp_bundle/ports.dart' show StoragePort;

// Browser-specific types + ports (this package).
export 'src/ports/browser_audit_port.dart';
export 'src/ports/browser_auth_profile_port.dart';
export 'src/ports/browser_context_port.dart';
export 'src/ports/browser_download_port.dart';
export 'src/ports/browser_engine_port.dart';
export 'src/ports/browser_extraction_template_port.dart';
export 'src/ports/browser_policy_port.dart';
export 'src/ports/browser_search_port.dart';
export 'src/types/browser_types.dart';

// Policy
export 'src/policy/audit_trail.dart';
export 'src/policy/file_audit_sink.dart';
export 'src/policy/kv_audit_sink.dart';
export 'src/policy/policy_engine.dart';

// Registry
export 'src/registry/auth_profile_store.dart';
export 'src/registry/context_registry.dart';
export 'src/registry/engine_registry.dart';
export 'src/registry/extraction_registry.dart';
export 'src/registry/oauth_flow_runner.dart';
export 'src/registry/search_router.dart';
export 'src/registry/secret_box.dart';
export 'src/registry/transforms.dart';

// Ops
export 'src/ops/crawl_scheduler.dart';
export 'src/ops/download_manager.dart';
export 'src/ops/frontier.dart';
export 'src/ops/http_fetcher.dart';

// Core
export 'src/core/browser_runtime.dart';

// Built-in CDP engine (pure Dart — no puppeteer)
export 'src/engines/cdp/cdp_client.dart';
export 'src/engines/cdp/cdp_context_port.dart';
export 'src/engines/cdp/cdp_engine.dart';
export 'src/engines/cdp/cdp_launcher.dart';

// Built-in search adapters (6 providers, all in-package)
export 'src/search/providers/providers.dart';

// Definitions
export 'src/definitions/mcp_integration.dart';
export 'src/definitions/operations.dart';

// Tooling
export 'src/tooling/har_replay.dart';
export 'src/tooling/matrix_runner.dart';
