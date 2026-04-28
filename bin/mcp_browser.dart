/// CLI entry for mcp_browser — ad-hoc runner for core primitives.
///
/// See PRD §8 Phase 5 (Tooling — CLI) and
/// `docs/03_DDD/12-skill-definitions.md`. The CLI is a *shell* around the
/// runtime: it wires a minimal InfraPorts set (no CDP engine) and prints
/// JSON so scripts can pipe results.
///
/// This CLI defaults to a stub engine so `describe` and `matrix --dry-run`
/// work without a real browser. Real browsing uses the built-in CDP engine
/// (in `lib/src/engines/cdp/`, once implemented) or an optional alternative
/// engine package wired by the host.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mcp_browser/mcp_browser.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'mcp_browser',
    'Ad-hoc runner for the mcp_browser 4-Primitive Contract.',
  )
    ..addCommand(_DescribeCommand())
    ..addCommand(_MatrixCommand())
    ..addCommand(_HarCommand());

  try {
    final code = await runner.run(arguments) ?? 0;
    exit(code);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on Object catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
  }
}

// ---------------------------------------------------------------------------

BrowserRuntime _buildStubRuntime() {
  final engine = _StubEngine();
  final engines = EngineRegistry()
    ..register('stub', engine: engine, context: _StubContextPort());
  final policy = PolicyEngine.defaults();
  final contexts = ContextRegistry(engines: engines, policy: policy);
  final audit = AuditTrail(sink: InMemoryAuditSink());
  return BrowserRuntime(
    engines: engines,
    contexts: contexts,
    policy: policy,
    audit: audit,
  );
}

class _StubEngine implements BrowserEnginePort {
  @override
  EngineDescriptor describe() => const EngineDescriptor(
        id: 'stub',
        name: 'Stub (no browser)',
        version: '0.1.0',
        capabilities: <EngineCapability>{EngineCapability.headless},
      );

  @override
  Future<void> initialize() async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<BrowserPayloadEnvelope> read(
    BrowserContextHandle handle,
    BrowserReadSpec spec,
  ) async {
    return BrowserPayloadEnvelope(
      contextId: handle.contextId,
      mime: 'text/plain',
      body: 'stub:${spec.kind.name}',
    );
  }

  @override
  Future<BrowserActionResult> execute(
    BrowserContextHandle handle,
    BrowserAction action,
  ) async =>
      const BrowserActionResult(success: true);

  @override
  Stream<BrowserEvent> subscribe(
    BrowserContextHandle handle,
    BrowserTopic topic,
  ) =>
      const Stream<BrowserEvent>.empty();
}

class _StubContextPort implements BrowserContextPort {
  @override
  Future<Object> openContext(BrowserContextSpec spec) async => spec;

  @override
  Future<void> closeContext(Object enginePayload) async {}

  @override
  Future<Map<String, dynamic>> saveStorageState(Object enginePayload) async =>
      const <String, dynamic>{};

  @override
  Future<void> restoreStorageState(
    Object enginePayload,
    Map<String, dynamic> state,
  ) async {}

  @override
  Future<void> setCookies(
    BrowserContextHandle handle,
    List<BrowserCookie> cookies,
  ) async {}

  @override
  Future<void> setExtraHeaders(
    BrowserContextHandle handle,
    Map<String, String> headers,
  ) async {}

  @override
  Future<void> setDownloadHandler(
    BrowserContextHandle handle,
    String directory,
  ) async {}
}

// ---------------------------------------------------------------------------

class _DescribeCommand extends Command<int> {
  @override
  String get name => 'describe';

  @override
  String get description =>
      'Print the BrowserDescriptor as JSON (stub engine).';

  @override
  Future<int> run() async {
    final runtime = _buildStubRuntime();
    await runtime.initialize();
    final desc = await runtime.describe();
    stdout.writeln(jsonEncode(<String, dynamic>{
      'engines': desc.engines
          .map((EngineDescriptor e) => <String, dynamic>{
                'id': e.id,
                'name': e.name,
                'version': e.version,
                'capabilities':
                    e.capabilities.map((EngineCapability c) => c.name).toList(),
              })
          .toList(),
      'activeContexts': desc.activeContexts,
      'resourceCaps': <String, dynamic>{
        'maxConcurrentContexts': desc.resourceCaps.maxConcurrentContexts,
        'maxPagesPerContext': desc.resourceCaps.maxPagesPerContext,
      },
    }));
    await runtime.shutdown();
    return 0;
  }
}

class _MatrixCommand extends Command<int> {
  _MatrixCommand() {
    argParser
      ..addMultiOption('actor',
          abbr: 'a', help: 'Actor identifier (repeatable).')
      ..addMultiOption('route',
          abbr: 'r', help: 'Route URL (repeatable).')
      ..addOption('tenant', defaultsTo: '_default')
      ..addMultiOption('capture',
          defaultsTo: const <String>['text'],
          help: 'Capture kinds to collect per cell.')
      ..addFlag('dry-run',
          negatable: false,
          help: 'Print the plan without hitting the engine.');
  }

  @override
  String get name => 'matrix';

  @override
  String get description =>
      'Run an actor × route matrix (stub engine unless linked with a real adapter).';

  @override
  Future<int> run() async {
    final args = argResults!;
    final actors = args['actor'] as List<String>;
    final routes = args['route'] as List<String>;
    if (actors.isEmpty || routes.isEmpty) {
      stderr.writeln('matrix requires at least one --actor and --route.');
      return 64;
    }
    final spec = MatrixSpec(
      tenantId: args['tenant'] as String,
      actors: actors,
      routes: routes,
      captures: args['capture'] as List<String>,
    );
    if (args['dry-run'] as bool) {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'planned': spec.totalCells,
        'actors': spec.actors,
        'routes': spec.routes,
        'captures': spec.captures,
      }));
      return 0;
    }
    final runtime = _buildStubRuntime();
    await runtime.initialize();
    final store = AuthProfileStore(
      kv: InMemoryKvStoragePort(),
      crypto: SecretBox.generate(),
    );
    for (final actor in actors) {
      await store.put(
          BrowserAuthProfile(id: actor, tenantId: spec.tenantId));
    }
    final runner =
        MatrixRunner(runtime: runtime, contexts: runtime.contexts);
    final cells = await runner.run(spec);
    stdout.writeln(jsonEncode(<String, dynamic>{
      'cells': cells.map((MatrixCell c) => c.toJson()).toList(),
    }));
    await runtime.shutdown();
    return 0;
  }
}

class _HarCommand extends Command<int> {
  _HarCommand() {
    argParser
      ..addOption('file', abbr: 'f', help: 'Path to a HAR 1.2 file.')
      ..addOption('url', help: 'URL to fetch from the HAR index.');
  }

  @override
  String get name => 'har';

  @override
  String get description =>
      'Inspect or replay a HAR 1.2 file through HarReplayFetcher.';

  @override
  Future<int> run() async {
    final path = argResults!['file'] as String?;
    if (path == null) {
      stderr.writeln('har requires --file <path>.');
      return 64;
    }
    final fetcher = await HarReplayFetcher.fromFile(path);
    final targetUrl = argResults!['url'] as String?;
    if (targetUrl == null) {
      stdout.writeln(
          jsonEncode(<String, dynamic>{'entries': fetcher.size}));
      return 0;
    }
    final response = await fetcher.fetch(targetUrl);
    final body = await response.body.fold<List<int>>(
        <int>[], (List<int> acc, List<int> chunk) => acc..addAll(chunk));
    stdout.writeln(jsonEncode(<String, dynamic>{
      'statusCode': response.statusCode,
      'headers': response.headers,
      'contentLength': body.length,
      'preview': body.length < 512 ? utf8.decode(body, allowMalformed: true) : null,
    }));
    return 0;
  }
}
