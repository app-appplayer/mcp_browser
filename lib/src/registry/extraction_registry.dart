/// MOD-REG-004 — ExtractionRegistry implementation.
///
/// See `docs/03_DDD/07-extraction.md` for the design specification and
/// `docs/04_TEST/07-extraction.md` for the test plan.
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../_internal.dart';

import 'transforms.dart';

/// Error thrown on invalid template inputs (missing id/version, malformed
/// selector rules, etc.).
class ExtractionTemplateInvalidError extends ArgumentError {
  ExtractionTemplateInvalidError(super.message);
}

/// Registry-backed implementation of [BrowserExtractionTemplatePort].
class ExtractionRegistry implements BrowserExtractionTemplatePort {

  ExtractionRegistry({this.storage, TransformRegistry? transforms})
      : transforms = transforms ?? TransformRegistry.defaults();
  final KvStoragePort? storage;
  final TransformRegistry transforms;

  /// id -> version -> template.
  final Map<String, Map<String, BrowserExtractionTemplate>> _hot =
      <String, Map<String, BrowserExtractionTemplate>>{};

  @override
  Future<void> register(BrowserExtractionTemplate template) async {
    if (template.id.isEmpty) {
      throw ExtractionTemplateInvalidError('template.id must be non-empty');
    }
    if (template.version.isEmpty) {
      throw ExtractionTemplateInvalidError(
        'template.version must be non-empty',
      );
    }
    _hot
        .putIfAbsent(template.id,
            () => <String, BrowserExtractionTemplate>{})[template.version] =
        template;
    if (storage != null) {
      await storage!.set(
        _key(template.id, template.version),
        jsonEncode(template.toJson()),
      );
    }
  }

  @override
  Future<BrowserExtractionTemplate?> get(String id, {String? version}) async {
    await _hydrate(id);
    final byVersion = _hot[id];
    if (byVersion == null || byVersion.isEmpty) return null;
    if (version != null) return byVersion[version];
    final latest = _latestVersion(byVersion.keys);
    return latest == null ? null : byVersion[latest];
  }

  @override
  Future<List<BrowserExtractionTemplateMeta>> list() async {
    if (storage != null) {
      final keys = await storage!.keys(prefix: _prefix);
      for (final key in keys) {
        final parts = key.substring(_prefix.length).split('/');
        if (parts.length != 2) continue;
        await _hydrate(parts.first);
      }
    }
    final out = <BrowserExtractionTemplateMeta>[];
    _hot.forEach((String id, Map<String, BrowserExtractionTemplate> byVer) {
      for (final entry in byVer.entries) {
        out.add(BrowserExtractionTemplateMeta(id: id, version: entry.key));
      }
    });
    return out;
  }

  @override
  Future<void> remove(String id, String version) async {
    _hot[id]?.remove(version);
    if (_hot[id]?.isEmpty ?? false) _hot.remove(id);
    if (storage != null) {
      await storage!.remove(_key(id, version));
    }
  }

  @override
  Future<Map<String, dynamic>> evaluate(
    BrowserExtractionTemplate template, {
    required String html,
    String? pageUrl,
  }) async {
    final doc = html_parser.parse(html);
    final context = <String, dynamic>{
      if (pageUrl != null) 'pageUrl': pageUrl,
    };
    final result = <String, dynamic>{};
    for (final entry in template.selectors.entries) {
      result[entry.key] = _evaluateRule(doc, entry.value, context);
    }
    for (final step in template.transforms) {
      final stepContext = <String, dynamic>{...context, ...step.params};
      result[step.field] =
          transforms.apply(step.op, result[step.field], stepContext);
    }
    final missing = template.outputSchema.validate(result);
    if (missing.isNotEmpty) {
      throw BrowserExtractionSchemaError(result, missing);
    }
    return result;
  }

  // -------------------------------------------------------------------------

  dynamic _evaluateRule(
    dom.Document doc,
    BrowserSelectorRule rule,
    Map<String, dynamic> context,
  ) {
    List<dom.Element> matches;
    switch (rule.mode) {
      case BrowserSelectorMode.css:
        matches = doc.querySelectorAll(rule.selector);
        break;
      case BrowserSelectorMode.xpath:
      case BrowserSelectorMode.role:
      case BrowserSelectorMode.text:
        throw UnsupportedError(
          '${rule.mode.name} selector mode is not yet implemented',
        );
    }
    if (matches.isEmpty) {
      return rule.many ? const <dynamic>[] : null;
    }
    final values = matches
        .map((dom.Element el) => _extractValue(el, rule.extract))
        .toList(growable: false);
    final projected = rule.transforms.isEmpty
        ? values
        : values
            .map((dynamic v) =>
                _applyTransformChain(v, rule.transforms, context))
            .toList(growable: false);
    return rule.many ? projected : projected.first;
  }

  dynamic _applyTransformChain(
    dynamic input,
    List<String> ids,
    Map<String, dynamic> context,
  ) {
    var current = input;
    for (final id in ids) {
      current = transforms.apply(id, current, context);
    }
    return current;
  }

  dynamic _extractValue(dom.Element el, String kind) {
    if (kind == 'text') return el.text;
    if (kind == 'html') return el.outerHtml;
    if (kind == 'innerHtml') return el.innerHtml;
    if (kind.startsWith('attr:')) {
      return el.attributes[kind.substring('attr:'.length)];
    }
    throw ArgumentError('Unknown selector extract: $kind');
  }

  Future<void> _hydrate(String id) async {
    if (_hot.containsKey(id) || storage == null) return;
    final keys = await storage!.keys(prefix: '$_prefix$id/');
    if (keys.isEmpty) return;
    final bucket = <String, BrowserExtractionTemplate>{};
    for (final key in keys) {
      final raw = await storage!.get(key);
      if (raw is! String) continue;
      try {
        final json = jsonDecode(raw);
        final template = BrowserExtractionTemplate.fromJson(
            Map<String, dynamic>.from(json as Map));
        bucket[template.version] = template;
      } on Object {
        // Skip corrupt entries — host can remove them explicitly.
      }
    }
    if (bucket.isNotEmpty) _hot[id] = bucket;
  }

  String? _latestVersion(Iterable<String> versions) {
    String? best;
    for (final v in versions) {
      if (best == null || _compareSemver(v, best) > 0) best = v;
    }
    return best;
  }

  static int _compareSemver(String a, String b) {
    final aParts = a.split('.').map((String p) => int.tryParse(p) ?? 0).toList();
    final bParts = b.split('.').map((String p) => int.tryParse(p) ?? 0).toList();
    for (var i = 0; i < aParts.length && i < bParts.length; i++) {
      if (aParts[i] != bParts[i]) return aParts[i].compareTo(bParts[i]);
    }
    return aParts.length.compareTo(bParts.length);
  }

  static const _prefix = 'mcp_browser/extraction/';
  static String _key(String id, String version) => '$_prefix$id/$version';
}
