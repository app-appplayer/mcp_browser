/// Priority-ordered crawl frontier with content/URL dedup.
///
/// See `docs/03_DDD/09-crawl.md` §3.4.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../_internal.dart';

class FrontierItem {

  const FrontierItem({
    required this.url,
    required this.priority,
    required this.depth,
    required this.insertionOrder,
  });
  final String url;
  final int priority;
  final int depth;
  final int insertionOrder;
}

/// In-memory frontier. Lower [priority] wins; ties broken by insertion order.
class Frontier {

  Frontier({this.strategy = BrowserDedupStrategy.both});
  final BrowserDedupStrategy strategy;
  final Queue<FrontierItem> _queue = Queue<FrontierItem>();
  final Set<String> _seenUrls = <String>{};
  final Set<String> _seenHashes = <String>{};
  int _counter = 0;

  bool get isEmpty => _queue.isEmpty;
  int get length => _queue.length;

  /// Enqueue [url] if it has not already been enqueued under the URL-dedup
  /// strategy. Returns true when queued.
  bool enqueue(String url, {int priority = 0, int depth = 0}) {
    final canonical = _canonicalizeUrl(url);
    if (_dedupByUrl && _seenUrls.contains(canonical)) return false;
    _seenUrls.add(canonical);
    _insertSorted(FrontierItem(
      url: canonical,
      priority: priority,
      depth: depth,
      insertionOrder: _counter++,
    ));
    return true;
  }

  /// Remove and return the next item, or null when empty.
  FrontierItem? dequeue() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }

  /// Whether [contentHash] has already been observed.
  bool seen(String contentHash) => _seenHashes.contains(contentHash);

  /// Mark [contentHash] as observed.
  void markSeen(String contentHash) => _seenHashes.add(contentHash);

  /// Capture frontier state (queue + dedup sets) as JSON.
  Map<String, dynamic> snapshot() => <String, dynamic>{
        'strategy': strategy.name,
        'counter': _counter,
        'seenUrls': _seenUrls.toList(),
        'seenHashes': _seenHashes.toList(),
        'queue': _queue
            .map((FrontierItem i) => <String, dynamic>{
                  'url': i.url,
                  'priority': i.priority,
                  'depth': i.depth,
                  'order': i.insertionOrder,
                })
            .toList(),
      };

  /// Reload [snapshot] into a fresh frontier (replaces state).
  void restore(Map<String, dynamic> snapshot) {
    _queue.clear();
    _seenUrls
      ..clear()
      ..addAll((snapshot['seenUrls'] as List<dynamic>?)
              ?.map((dynamic e) => e as String) ??
          const <String>[]);
    _seenHashes
      ..clear()
      ..addAll((snapshot['seenHashes'] as List<dynamic>?)
              ?.map((dynamic e) => e as String) ??
          const <String>[]);
    _counter = (snapshot['counter'] as num?)?.toInt() ?? 0;
    for (final raw in (snapshot['queue'] as List<dynamic>? ?? <dynamic>[])) {
      final m = Map<String, dynamic>.from(raw as Map);
      _insertSorted(FrontierItem(
        url: m['url'] as String,
        priority: (m['priority'] as num).toInt(),
        depth: (m['depth'] as num).toInt(),
        insertionOrder: (m['order'] as num).toInt(),
      ));
    }
  }

  bool get _dedupByUrl =>
      strategy == BrowserDedupStrategy.urlCanonical ||
      strategy == BrowserDedupStrategy.both;

  bool get _dedupByHash =>
      strategy == BrowserDedupStrategy.contentHash ||
      strategy == BrowserDedupStrategy.both;

  /// Whether [contentHash] should block re-enqueue under the active strategy.
  bool shouldSkipByHash(String contentHash) =>
      _dedupByHash && _seenHashes.contains(contentHash);

  /// Canonicalize a URL for URL-based dedup: lowercase host, drop fragments,
  /// drop tracking query params (utm_*, fbclid, gclid, ref, ref_src).
  static String _canonicalizeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final dropKeys = <String>{
      'fbclid',
      'gclid',
      'ref',
      'ref_src',
    };
    final filtered = <MapEntry<String, String>>[
      for (final entry in uri.queryParameters.entries)
        if (!entry.key.toLowerCase().startsWith('utm_') &&
            !dropKeys.contains(entry.key.toLowerCase()))
          entry,
    ];
    final scheme = uri.scheme;
    final host = uri.host.toLowerCase();
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path;
    final qs = filtered.isEmpty
        ? ''
        : '?${filtered.map((MapEntry<String, String> e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    return '$scheme://$host$port$path$qs';
  }

  void _insertSorted(FrontierItem item) {
    if (_queue.isEmpty) {
      _queue.add(item);
      return;
    }
    final list = _queue.toList()..add(item);
    list.sort((FrontierItem a, FrontierItem b) {
      if (a.priority != b.priority) return a.priority.compareTo(b.priority);
      return a.insertionOrder.compareTo(b.insertionOrder);
    });
    _queue
      ..clear()
      ..addAll(list);
  }
}

/// Helper: SHA-256 hex digest of [bytes].
String sha256HexOf(List<int> bytes) => sha256.convert(bytes).toString();

/// Helper: SHA-256 hex digest of [text] encoded as UTF-8.
String sha256HexOfText(String text) => sha256HexOf(utf8.encode(text));
