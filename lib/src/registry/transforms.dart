/// Built-in post-selector transforms used by [ExtractionRegistry].
///
/// Hosts may add or override transforms through [TransformRegistry].
/// Transforms are deliberately pure (no IO) so they can be evaluated
/// deterministically in tests.
library;

import 'dart:convert';

/// Signature of a transform. [input] is the current value (may be null when
/// a previous transform produced null). [context] carries page-level data
/// such as `pageUrl`. Throws on invalid input — the registry catches and
/// keeps the original value, per DDD 07-extraction §6.
typedef Transform = dynamic Function(dynamic input, Map<String, dynamic> context);

/// Registry of named transforms. Construct with [TransformRegistry.defaults]
/// for the built-in set and `register`/`override` additional ones.
class TransformRegistry {

  TransformRegistry();

  /// Built-in set: trim, toInt, toDouble, toBool, toDate, lower, upper,
  /// urlAbsolutize, split, join, regexExtract.
  factory TransformRegistry.defaults() {
    final r = TransformRegistry()
      ..register('trim', _trim)
      ..register('toInt', _toInt)
      ..register('toDouble', _toDouble)
      ..register('toBool', _toBool)
      ..register('toDate', _toDate)
      ..register('lower', _lower)
      ..register('upper', _upper)
      ..register('urlAbsolutize', _urlAbsolutize)
      ..register('split', _split)
      ..register('join', _join)
      ..register('regexExtract', _regexExtract)
      ..register('jsonDecode', _jsonDecode);
    return r;
  }
  final Map<String, Transform> _fns = <String, Transform>{};

  void register(String id, Transform fn) {
    _fns[id] = fn;
  }

  bool has(String id) => _fns.containsKey(id);

  Transform? get(String id) => _fns[id];

  /// Apply the transform by id. When unknown, returns [input] unchanged.
  dynamic apply(
    String id,
    dynamic input,
    Map<String, dynamic> context,
  ) {
    final fn = _fns[id];
    if (fn == null) return input;
    try {
      return fn(input, context);
    } on Object {
      // Transform exceptions keep the original value (DDD §6).
      return input;
    }
  }
}

// ---------------------------------------------------------------------------
// Built-ins
// ---------------------------------------------------------------------------

dynamic _trim(dynamic input, Map<String, dynamic> _) {
  if (input is String) return input.trim();
  if (input is Iterable) {
    return input.map((dynamic e) => e is String ? e.trim() : e).toList();
  }
  return input;
}

dynamic _toInt(dynamic input, Map<String, dynamic> _) {
  if (input is int) return input;
  if (input is num) return input.toInt();
  if (input is String) return int.parse(input.trim());
  throw ArgumentError('toInt: unsupported input ${input.runtimeType}');
}

dynamic _toDouble(dynamic input, Map<String, dynamic> _) {
  if (input is double) return input;
  if (input is num) return input.toDouble();
  if (input is String) return double.parse(input.trim());
  throw ArgumentError('toDouble: unsupported input');
}

dynamic _toBool(dynamic input, Map<String, dynamic> _) {
  if (input is bool) return input;
  if (input is num) return input != 0;
  if (input is String) {
    final lower = input.trim().toLowerCase();
    if (<String>{'true', 'yes', '1', 'on'}.contains(lower)) return true;
    if (<String>{'false', 'no', '0', 'off'}.contains(lower)) return false;
  }
  throw ArgumentError('toBool: unsupported input');
}

dynamic _toDate(dynamic input, Map<String, dynamic> _) {
  if (input is DateTime) return input;
  if (input is String) return DateTime.parse(input.trim());
  throw ArgumentError('toDate: unsupported input');
}

dynamic _lower(dynamic input, Map<String, dynamic> _) {
  return input is String ? input.toLowerCase() : input;
}

dynamic _upper(dynamic input, Map<String, dynamic> _) {
  return input is String ? input.toUpperCase() : input;
}

dynamic _urlAbsolutize(dynamic input, Map<String, dynamic> context) {
  if (input is! String) return input;
  final pageUrl = context['pageUrl'] as String?;
  if (pageUrl == null) return input;
  final base = Uri.tryParse(pageUrl);
  if (base == null) return input;
  final resolved = base.resolve(input);
  return resolved.toString();
}

dynamic _split(dynamic input, Map<String, dynamic> context) {
  if (input is! String) return input;
  final sep = context['sep'] as String? ?? ',';
  return input.split(sep);
}

dynamic _join(dynamic input, Map<String, dynamic> context) {
  if (input is! Iterable) return input;
  final sep = context['sep'] as String? ?? '';
  return input.map((dynamic e) => e?.toString() ?? '').join(sep);
}

dynamic _regexExtract(dynamic input, Map<String, dynamic> context) {
  if (input is! String) return input;
  final pattern = context['pattern'] as String?;
  if (pattern == null) return input;
  final group = (context['group'] as int?) ?? 1;
  final match = RegExp(pattern).firstMatch(input);
  if (match == null) return null;
  if (group < 0 || group > match.groupCount) return null;
  return match.group(group);
}

dynamic _jsonDecode(dynamic input, Map<String, dynamic> _) {
  if (input is! String) return input;
  return jsonDecode(input);
}
