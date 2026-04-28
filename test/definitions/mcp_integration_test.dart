/// TEST — MOD-DEF-002 McpIntegration.
///
/// Mirrors `docs/04_TEST/12-skill-definitions.md` TC-1017, TC-1018, TC-1019.
library;

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

import '../_fakes/fake_engine.dart';

class _ToolEntry {
  _ToolEntry(
    this.name, {
    required this.description,
    required this.readOnly,
    required this.destructive,
    required this.handler,
  });
  final String name;
  final String description;
  final bool readOnly;
  final bool destructive;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler;
}

void main() {
  group('McpIntegration', () {
    late McpIntegration integ;
    late List<_ToolEntry> tools;
    late Map<String, Future<dynamic> Function()> resources;

    setUp(() {
      final engines = EngineRegistry()
        ..register('fake',
            engine: FakeEngine(), context: FakeContextPort());
      final policy = PolicyEngine.defaults();
      final contexts = ContextRegistry(engines: engines, policy: policy);
      final runtime = BrowserRuntime(
        engines: engines,
        contexts: contexts,
        policy: policy,
        audit: AuditTrail(sink: InMemoryAuditSink()),
      );
      integ = McpIntegration(
        runtime: runtime,
        operations: BrowserOperations(runtime: runtime, contexts: contexts),
      );
      tools = <_ToolEntry>[];
      resources = <String, Future<dynamic> Function()>{};
      integ.registerWith(
        tool: (
          String name, {
          required String description,
          required bool readOnly,
          required bool destructive,
          required Future<Map<String, dynamic>> Function(Map<String, dynamic>)
              handler,
        }) {
          tools.add(_ToolEntry(
            name,
            description: description,
            readOnly: readOnly,
            destructive: destructive,
            handler: handler,
          ));
        },
        resource: (String uri, Future<dynamic> Function() reader) {
          resources[uri] = reader;
        },
      );
    });

    test('TC-1017 registers all 9 Phase 4 operations as tools', () {
      expect(tools.map((_ToolEntry t) => t.name).toSet(), <String>{
        'page_view',
        'page_audit_role',
        'web_search',
        'extract',
        'crawl',
        'monitor',
        'download',
        'submit_form',
        'page_compare_actors',
      });
    });

    test('TC-1018 read-only operations carry readOnly=true', () {
      const readOnlyOps = <String>{
        'page_view',
        'page_audit_role',
        'web_search',
        'extract',
        'page_compare_actors',
      };
      for (final t in tools.where(
          (_ToolEntry t) => readOnlyOps.contains(t.name))) {
        expect(t.readOnly, isTrue, reason: '${t.name} should be readOnly');
      }
    });

    test('TC-1019 destructive operations carry destructive=true', () {
      const destructiveOps = <String>{
        'crawl',
        'monitor',
        'download',
        'submit_form',
      };
      for (final t in tools.where(
          (_ToolEntry t) => destructiveOps.contains(t.name))) {
        expect(t.destructive, isTrue,
            reason: '${t.name} should be destructive');
      }
    });

    test('TC-1020 descriptor resource is registered', () {
      expect(resources.keys, contains('browser://descriptor'));
    });
  });
}
