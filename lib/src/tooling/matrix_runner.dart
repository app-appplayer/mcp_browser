/// Scenario matrix runner — automates actor × route × viewport traversal.
///
/// See PRD §8 Phase 5 (Tooling — scenario matrix runner) and
/// `docs/03_DDD/12-skill-definitions.md` §3.3 (page_audit_role). The matrix
/// runner generalises `page_audit_role` to also sweep viewports and capture
/// console/network diagnostics per cell.
library;

import 'dart:async';

import '../_internal.dart';

import '../core/browser_runtime.dart';
import '../registry/context_registry.dart';

/// Single viewport dimension.
class Viewport {

  const Viewport({
    required this.width,
    required this.height,
    this.label = '',
  });
  final int width;
  final int height;
  final String label;

  String describe() =>
      label.isEmpty ? '${width}x$height' : '$label(${width}x$height)';
}

/// Per-cell result of [MatrixRunner.run].
class MatrixCell {

  const MatrixCell({
    required this.actor,
    required this.route,
    required this.viewport,
    required this.captures,
    required this.consoleErrors,
    required this.requestFailed,
    required this.duration,
    this.error,
  });
  final String actor;
  final String route;
  final Viewport viewport;
  final Map<String, dynamic> captures;
  final List<String> consoleErrors;
  final List<String> requestFailed;
  final String? error;
  final Duration duration;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'actor': actor,
        'route': route,
        'viewport': viewport.describe(),
        if (captures.isNotEmpty) 'captures': captures,
        if (consoleErrors.isNotEmpty) 'consoleErrors': consoleErrors,
        if (requestFailed.isNotEmpty) 'requestFailed': requestFailed,
        'durationMs': duration.inMilliseconds,
        if (error != null) 'error': error,
      };
}

/// Specification for a single matrix run.
class MatrixSpec {

  const MatrixSpec({
    required this.tenantId,
    required this.actors,
    required this.routes,
    this.viewports = const <Viewport>[Viewport(width: 1280, height: 800)],
    this.captures = const <String>['text'],
    this.collectConsoleErrors = true,
    this.collectRequestFailed = true,
    this.cellTimeout = const Duration(seconds: 30),
  });
  final String tenantId;
  final List<String> actors;
  final List<String> routes;
  final List<Viewport> viewports;

  /// Which capture kinds to collect per cell (`text`, `html`, `markdown`,
  /// `screenshot`, `har`).
  final List<String> captures;

  /// When true, `subscribe(consoleError)` + `subscribe(requestFailed)` are
  /// drained for the duration of the cell.
  final bool collectConsoleErrors;
  final bool collectRequestFailed;

  /// Deadline per cell. Cells that don't finish within this duration are
  /// marked with `error: 'timeout'` and the runner proceeds to the next.
  final Duration cellTimeout;

  int get totalCells => actors.length * routes.length * viewports.length;
}

/// Executes a [MatrixSpec] against a live [BrowserRuntime] + [ContextRegistry].
class MatrixRunner {

  MatrixRunner({required this.runtime, required this.contexts});
  final BrowserRuntime runtime;
  final ContextRegistry contexts;

  /// Execute [spec] and return one [MatrixCell] per `(actor, route, viewport)`.
  Future<List<MatrixCell>> run(MatrixSpec spec) async {
    final cells = <MatrixCell>[];
    for (final actor in spec.actors) {
      for (final viewport in spec.viewports) {
        final contextSpec = BrowserContextSpec(
          tenantId: spec.tenantId,
          actorId: actor,
          viewport: <String, int>{
            'width': viewport.width,
            'height': viewport.height,
          },
        );
        final handle = await contexts.acquire(contextSpec);
        try {
          await runtime.execute(
            handle.contextId,
            BrowserAction(
              kind: BrowserActionKind.setAuth,
              params: <String, dynamic>{'profileId': actor},
            ),
          );
          for (final route in spec.routes) {
            final cell = await _runCell(
              handle.contextId,
              actor: actor,
              route: route,
              viewport: viewport,
              spec: spec,
            );
            cells.add(cell);
          }
        } on Object catch (e) {
          // Actor-level failure — every remaining route for this actor is
          // reported as the same error so the host can see what happened.
          for (final route in spec.routes) {
            cells.add(MatrixCell(
              actor: actor,
              route: route,
              viewport: viewport,
              captures: const <String, dynamic>{},
              consoleErrors: const <String>[],
              requestFailed: const <String>[],
              duration: Duration.zero,
              error: 'actor_setup_failed: $e',
            ));
          }
        } finally {
          await contexts.release(handle.contextId);
        }
      }
    }
    return cells;
  }

  Future<MatrixCell> _runCell(
    String contextId, {
    required String actor,
    required String route,
    required Viewport viewport,
    required MatrixSpec spec,
  }) async {
    final consoleErrors = <String>[];
    final requestFailed = <String>[];
    final subs = <StreamSubscription<BrowserEvent>>[];
    if (spec.collectConsoleErrors) {
      subs.add(runtime
          .subscribe(contextId, BrowserTopic.consoleError())
          .listen((BrowserEvent e) {
        final text = e.payload['text']?.toString();
        if (text != null) consoleErrors.add(text);
      }));
    }
    if (spec.collectRequestFailed) {
      subs.add(runtime
          .subscribe(contextId, BrowserTopic.requestFailed())
          .listen((BrowserEvent e) {
        final url = e.payload['url']?.toString();
        if (url != null) requestFailed.add(url);
      }));
    }

    final stopwatch = Stopwatch()..start();
    final captures = <String, dynamic>{};
    String? error;
    try {
      await runtime
          .execute(contextId, BrowserAction.navigate(route))
          .timeout(spec.cellTimeout);
      for (final kind in spec.captures) {
        final envelope = await runtime
            .read(contextId, _readSpecOf(kind))
            .timeout(spec.cellTimeout);
        captures[kind] = envelope.body;
      }
    } on TimeoutException {
      error = 'timeout';
    } on Object catch (e) {
      error = '$e';
    }
    stopwatch.stop();
    for (final sub in subs) {
      await sub.cancel();
    }
    return MatrixCell(
      actor: actor,
      route: route,
      viewport: viewport,
      captures: captures,
      consoleErrors: consoleErrors,
      requestFailed: requestFailed,
      duration: stopwatch.elapsed,
      error: error,
    );
  }

  static BrowserReadSpec _readSpecOf(String kind) {
    switch (kind) {
      case 'text':
        return BrowserReadSpec.text();
      case 'html':
        return BrowserReadSpec.html();
      case 'screenshot':
        return BrowserReadSpec.screenshot();
      default:
        return BrowserReadSpec(kind: BrowserReadKind.fromString(kind));
    }
  }
}
