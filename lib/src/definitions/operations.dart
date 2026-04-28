/// MOD-DEF-001 — BrowserOperations.
///
/// See `docs/03_DDD/12-operations.md` for the design specification and
/// `docs/04_TEST/12-operations.md` for the test plan.
///
/// Nine built-in operation presets (`page_view`, `page_audit_role`,
/// `web_search`, `extract`, `crawl`, `monitor`, `download`, `submit_form`,
/// `page_compare_actors`) that compose the 4-Primitive Contract into
/// capability-level workflows. Hosts expose these to LLMs through
/// `McpIntegration`.
library;

import '../_internal.dart';

import '../core/browser_runtime.dart';
import '../registry/context_registry.dart';

/// A single browser-side operation preset exposed by mcp_browser.
class BrowserOperation {

  const BrowserOperation({
    required this.id,
    required this.description,
    required this.handler,
    this.readOnly = false,
    this.destructive = false,
  });
  final String id;

  final String description;

  final bool readOnly;

  final bool destructive;

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> args)
      handler;
}

/// Built-in operation registry — 9 presets covering view, audit, search,
/// extract, crawl, monitor, download, submit, and multi-actor compare.
class BrowserOperations {

  BrowserOperations({
    required this.runtime,
    required this.contexts,
  }) {
    _operations = <BrowserOperation>[
      BrowserOperation(
        id: 'page_view',
        description:
            'View a page as a specific actor and capture text/screenshot.',
        readOnly: true,
        handler: _pageView,
      ),
      BrowserOperation(
        id: 'page_audit_role',
        description:
            'Audit role-based page rendering across actors and routes.',
        readOnly: true,
        handler: _pageAuditRole,
      ),
      BrowserOperation(
        id: 'web_search',
        description: 'Search the web via a registered provider.',
        readOnly: true,
        handler: _webSearch,
      ),
      BrowserOperation(
        id: 'extract',
        description:
            'Navigate to a URL and apply a registered ExtractionTemplate.',
        readOnly: true,
        handler: _extract,
      ),
      BrowserOperation(
        id: 'crawl',
        description: 'Crawl seed URLs under a policy; returns a crawl id.',
        destructive: true,
        handler: _crawl,
      ),
      BrowserOperation(
        id: 'monitor',
        description: 'Start a periodic URL change monitor; returns a handle id.',
        destructive: true,
        handler: _monitor,
      ),
      BrowserOperation(
        id: 'download',
        description:
            'Download a URL to the isolated downloads directory.',
        destructive: true,
        handler: _download,
      ),
      BrowserOperation(
        id: 'submit_form',
        description:
            'Drive a sequence of form interactions ending in submit; '
            'optionally captures a receipt page.',
        destructive: true,
        handler: _submitForm,
      ),
      BrowserOperation(
        id: 'page_compare_actors',
        description:
            'View the same route as multiple actors and return per-actor '
            'envelopes side by side.',
        readOnly: true,
        handler: _pageCompareActors,
      ),
    ];
  }
  final BrowserRuntime runtime;
  final ContextRegistry contexts;

  late final List<BrowserOperation> _operations;

  List<BrowserOperation> all() =>
      List<BrowserOperation>.unmodifiable(_operations);

  BrowserOperation? get(String id) {
    for (final op in _operations) {
      if (op.id == id) return op;
    }
    return null;
  }

  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _pageView(Map<String, dynamic> args) async {
    final actor = args['actor'] as String?;
    final path = args['path'] as String?;
    if (path == null || path.isEmpty) {
      throw ArgumentError('page_view requires `path`');
    }
    final tenantId = (args['tenantId'] as String?) ?? '_default';
    final captures = (args['capture'] as List<dynamic>?)
            ?.map((dynamic e) => e as String)
            .toList() ??
        const <String>['text'];

    final handle = await contexts.acquire(BrowserContextSpec(
      tenantId: tenantId,
      actorId: actor,
    ));
    try {
      if (actor != null) {
        await runtime.execute(
          handle.contextId,
          BrowserAction(
            kind: BrowserActionKind.setAuth,
            params: <String, dynamic>{'profileId': actor},
          ),
        );
      }
      await runtime.execute(
        handle.contextId,
        BrowserAction.navigate(path),
      );
      final envelopes = <Map<String, dynamic>>[];
      for (final cap in captures) {
        final spec = _readSpecOf(cap);
        final env = await runtime.read(handle.contextId, spec);
        envelopes.add(<String, dynamic>{
          'kind': cap,
          'mime': env.mime,
          'body': env.body,
          'meta': env.meta,
        });
      }
      return <String, dynamic>{'envelopes': envelopes};
    } finally {
      await contexts.release(handle.contextId);
    }
  }

  Future<Map<String, dynamic>> _pageAuditRole(
      Map<String, dynamic> args) async {
    final actors = (args['actors'] as List<dynamic>?)
            ?.map((dynamic e) => e as String)
            .toList() ??
        const <String>[];
    final routes = (args['routes'] as List<dynamic>?)
            ?.map((dynamic e) => e as String)
            .toList() ??
        const <String>[];
    if (actors.isEmpty || routes.isEmpty) {
      throw ArgumentError('page_audit_role requires `actors` and `routes`');
    }
    final tenantId = (args['tenantId'] as String?) ?? '_default';
    final captures = (args['captures'] as List<dynamic>?)
            ?.map((dynamic e) => e as String)
            .toList() ??
        const <String>['text'];

    final cells = <Map<String, dynamic>>[];
    for (final actor in actors) {
      final handle = await contexts.acquire(BrowserContextSpec(
        tenantId: tenantId,
        actorId: actor,
      ));
      try {
        await runtime.execute(
          handle.contextId,
          BrowserAction(
            kind: BrowserActionKind.setAuth,
            params: <String, dynamic>{'profileId': actor},
          ),
        );
        for (final route in routes) {
          final cell = <String, dynamic>{
            'actor': actor,
            'route': route,
            'capture': <String, dynamic>{},
            'errors': <String>[],
          };
          try {
            await runtime.execute(
              handle.contextId,
              BrowserAction.navigate(route),
            );
            for (final cap in captures) {
              final env =
                  await runtime.read(handle.contextId, _readSpecOf(cap));
              (cell['capture'] as Map<String, dynamic>)[cap] = env.body;
            }
          } on Object catch (e) {
            (cell['errors'] as List<String>).add(e.toString());
          }
          cells.add(cell);
        }
      } finally {
        await contexts.release(handle.contextId);
      }
    }
    return <String, dynamic>{'matrix': cells};
  }

  static BrowserReadSpec _readSpecOf(String capture) {
    switch (capture) {
      case 'text':
        return BrowserReadSpec.text();
      case 'html':
        return BrowserReadSpec.html();
      case 'screenshot':
        return BrowserReadSpec.screenshot();
      default:
        return BrowserReadSpec(kind: BrowserReadKind.fromString(capture));
    }
  }

  Future<Map<String, dynamic>> _webSearch(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    final provider = args['provider'] as String?;
    if (query == null || provider == null) {
      throw ArgumentError('web_search requires `query` and `provider`');
    }
    final result = await runtime.execute(
      '_search',
      BrowserAction(
        kind: BrowserActionKind.search,
        params: Map<String, dynamic>.from(args),
      ),
    );
    return result.output ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _extract(Map<String, dynamic> args) async {
    final url = args['url'] as String?;
    final templateId = args['templateId'] as String?;
    if (url == null || templateId == null) {
      throw ArgumentError('extract requires `url` and `templateId`');
    }
    final tenantId = (args['tenantId'] as String?) ?? '_default';
    final handle = await contexts.acquire(BrowserContextSpec(tenantId: tenantId));
    try {
      await runtime.execute(
        handle.contextId,
        BrowserAction.navigate(url),
      );
      final env = await runtime.read(
        handle.contextId,
        BrowserReadSpec.extract(
          templateId: templateId,
          templateVersion: args['templateVersion'] as String?,
        ),
      );
      return <String, dynamic>{
        'data': env.body,
        'meta': env.meta,
      };
    } finally {
      await contexts.release(handle.contextId);
    }
  }

  Future<Map<String, dynamic>> _crawl(Map<String, dynamic> args) async {
    final result = await runtime.execute(
      '_crawl',
      BrowserAction(
        kind: BrowserActionKind.crawl,
        params: Map<String, dynamic>.from(args),
      ),
    );
    return result.output ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _monitor(Map<String, dynamic> args) async {
    final url = args['url'] as String?;
    final intervalSeconds = args['interval_seconds'] as int?;
    if (url == null || intervalSeconds == null) {
      throw ArgumentError(
          'monitor requires `url` and `interval_seconds`');
    }
    final scheduler = runtime.crawler;
    if (scheduler == null) {
      throw StateError('E7001 monitor requires CrawlScheduler wired');
    }
    final handle = await scheduler.monitor(
      url,
      Duration(seconds: intervalSeconds),
    );
    return <String, dynamic>{'monitorId': handle.monitorId};
  }

  Future<Map<String, dynamic>> _download(Map<String, dynamic> args) async {
    final url = args['url'] as String?;
    if (url == null) {
      throw ArgumentError('download requires `url`');
    }
    final params = <String, dynamic>{
      ...args,
      'tenantId': (args['tenantId'] as String?) ?? '_default',
    };
    final result = await runtime.execute(
      '_download',
      BrowserAction(
        kind: BrowserActionKind.download,
        params: params,
      ),
    );
    return result.output ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _submitForm(Map<String, dynamic> args) async {
    final url = args['url'] as String?;
    final stepsRaw = args['steps'];
    if (url == null || stepsRaw is! List) {
      throw ArgumentError('submit_form requires `url` and `steps`');
    }
    final tenantId = (args['tenantId'] as String?) ?? '_default';
    final actor = args['actor'] as String?;
    final captureReceipt = args['capture_receipt'] as bool? ?? false;

    final handle = await contexts.acquire(BrowserContextSpec(
      tenantId: tenantId,
      actorId: actor,
    ));
    try {
      if (actor != null) {
        await runtime.execute(
          handle.contextId,
          BrowserAction(
            kind: BrowserActionKind.setAuth,
            params: <String, dynamic>{'profileId': actor},
          ),
        );
      }
      await runtime.execute(
        handle.contextId,
        BrowserAction.navigate(url),
      );

      final errors = <String>[];
      for (final raw in stepsRaw) {
        final step = Map<String, dynamic>.from(raw as Map);
        final stepError = await _runFormStep(handle.contextId, step);
        if (stepError != null) errors.add(stepError);
      }

      Map<String, dynamic>? receipt;
      if (captureReceipt) {
        final env = await runtime.read(
          handle.contextId,
          BrowserReadSpec.text(),
        );
        receipt = <String, dynamic>{
          'mime': env.mime,
          'body': env.body,
          'meta': env.meta,
        };
      }

      return <String, dynamic>{
        'success': errors.isEmpty,
        if (errors.isNotEmpty) 'errors': errors,
        if (receipt != null) 'receipt': receipt,
      };
    } finally {
      await contexts.release(handle.contextId);
    }
  }

  Future<String?> _runFormStep(
    String contextId,
    Map<String, dynamic> step,
  ) async {
    final action = step['action'] as String?;
    if (action == null) return 'step missing `action`';
    BrowserActionKind? kind;
    switch (action) {
      case 'fill':
        kind = BrowserActionKind.fill;
        break;
      case 'click':
        kind = BrowserActionKind.click;
        break;
      case 'type':
        kind = BrowserActionKind.type;
        break;
      case 'press':
        kind = BrowserActionKind.press;
        break;
      case 'select':
        kind = BrowserActionKind.select;
        break;
      case 'check':
        kind = BrowserActionKind.check;
        break;
      case 'upload':
        kind = BrowserActionKind.upload;
        break;
      case 'wait':
        final ms = (step['ms'] as int?) ?? 100;
        await Future<void>.delayed(Duration(milliseconds: ms));
        return null;
      default:
        return 'unsupported step action: $action';
    }
    try {
      await runtime.execute(
        contextId,
        BrowserAction(
          kind: kind,
          params: <String, dynamic>{
            if (step['selector'] != null) 'selector': step['selector'],
            if (step['value'] != null) 'value': step['value'],
            if (step['file'] != null) 'file': step['file'],
            if (step['key'] != null) 'key': step['key'],
          },
        ),
      );
      return null;
    } on Object catch (e) {
      return 'step `$action` failed: $e';
    }
  }

  Future<Map<String, dynamic>> _pageCompareActors(
      Map<String, dynamic> args) async {
    final actorsRaw = args['actors'];
    final route = args['route'] as String?;
    if (actorsRaw is! List || route == null) {
      throw ArgumentError('page_compare_actors requires `actors` and `route`');
    }
    final actors =
        actorsRaw.map((dynamic e) => e as String).toList(growable: false);
    final captures = (args['captures'] as List<dynamic>?)
            ?.map((dynamic e) => e as String)
            .toList() ??
        const <String>['text'];
    final tenantId = (args['tenantId'] as String?) ?? '_default';

    final byActor = <String, dynamic>{};
    for (final actor in actors) {
      final handle = await contexts.acquire(BrowserContextSpec(
        tenantId: tenantId,
        actorId: actor,
      ));
      try {
        await runtime.execute(
          handle.contextId,
          BrowserAction(
            kind: BrowserActionKind.setAuth,
            params: <String, dynamic>{'profileId': actor},
          ),
        );
        await runtime.execute(
          handle.contextId,
          BrowserAction.navigate(route),
        );
        final captured = <String, dynamic>{};
        for (final cap in captures) {
          final env = await runtime.read(handle.contextId, _readSpecOf(cap));
          captured[cap] = env.body;
        }
        byActor[actor] = captured;
      } on Object catch (e) {
        byActor[actor] = <String, dynamic>{'error': e.toString()};
      } finally {
        await contexts.release(handle.contextId);
      }
    }
    return <String, dynamic>{'route': route, 'byActor': byActor};
  }
}
