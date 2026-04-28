/// MOD-DEF-002 — McpIntegration.
///
/// Host-agnostic bridge that exposes [BrowserOperations] to an MCP host via
/// caller-supplied tool/resource registration callbacks. This keeps the
/// capability core free of any hard `mcp_server` dependency.
library;

import '../core/browser_runtime.dart';
import 'operations.dart';

/// Callback that registers a single MCP tool with the host server.
typedef McpToolRegistrar = void Function(
  String name, {
  required String description,
  required bool readOnly,
  required bool destructive,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic> args)
      handler,
});

/// Callback that registers a single MCP resource with the host server.
typedef McpResourceRegistrar = void Function(
  String uri,
  Future<dynamic> Function() reader,
);

/// Bridges [BrowserOperations] to a host MCP server via host-supplied
/// registration callbacks. The host is free to back the callbacks with
/// `mcp_server.Server` or any compatible surface.
class McpIntegration {

  const McpIntegration({required this.runtime, required this.operations});
  final BrowserRuntime runtime;
  final BrowserOperations operations;

  /// Register all operation presets + the descriptor resource.
  void registerWith({
    required McpToolRegistrar tool,
    required McpResourceRegistrar resource,
  }) {
    for (final op in operations.all()) {
      tool(
        op.id,
        description: op.description,
        readOnly: op.readOnly,
        destructive: op.destructive,
        handler: op.handler,
      );
    }
    resource('browser://descriptor', runtime.describe);
  }
}
