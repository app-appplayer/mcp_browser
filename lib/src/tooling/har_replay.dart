/// HAR-backed HttpFetcher for offline deterministic reruns.
///
/// See `docs/03_DDD/10-download.md` §1 (HAR export) and PRD §8 Phase 5
/// (Tooling — HAR replay). Hosts load a HAR file captured during a live
/// crawl/download and replay it deterministically to reproduce bug reports
/// or run CI on a fixed fixture.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ops/http_fetcher.dart';

/// A single HAR entry keyed by request URL + method.
class _HarEntry {
  const _HarEntry({
    required this.statusCode,
    required this.body,
    required this.headers,
  });
  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
}

/// Error thrown when the underlying HAR document is not a HAR 1.2 file or
/// the structure is malformed.
class HarParseError extends FormatException {
  HarParseError(String message) : super('HarParseError: $message');
}

/// Replay fetcher that serves HTTP responses recorded in a HAR 1.2 file.
///
/// Lookup is keyed by `$method $url`. When no matching entry is found the
/// fetcher returns `404` so tests can assert the missing call.
class HarReplayFetcher implements HttpFetcher {

  HarReplayFetcher._(this._entries);

  /// Build from a HAR JSON string.
  factory HarReplayFetcher.fromJson(String harJson) {
    final dynamic decoded = jsonDecode(harJson);
    if (decoded is! Map) {
      throw HarParseError('top-level value must be an object');
    }
    final log = decoded['log'];
    if (log is! Map) {
      throw HarParseError('missing `log` object');
    }
    final entries = log['entries'];
    if (entries is! List) {
      throw HarParseError('missing `log.entries` list');
    }
    final map = <String, _HarEntry>{};
    for (final raw in entries) {
      if (raw is! Map) continue;
      final request = raw['request'];
      final response = raw['response'];
      if (request is! Map || response is! Map) continue;
      final method =
          ((request['method'] as String?) ?? 'GET').toUpperCase();
      final url = request['url'] as String?;
      if (url == null) continue;
      final status = (response['status'] as num?)?.toInt() ?? 200;
      final headerList = response['headers'];
      final headers = <String, String>{};
      if (headerList is List) {
        for (final h in headerList) {
          if (h is! Map) continue;
          final name = h['name'] as String?;
          final value = h['value'];
          if (name == null || value == null) continue;
          headers[name.toLowerCase()] = value.toString();
        }
      }
      List<int> body;
      final content = response['content'];
      if (content is Map) {
        final text = content['text'];
        final encoding = content['encoding'] as String?;
        if (text is String) {
          if (encoding == 'base64') {
            body = base64.decode(text);
          } else {
            body = utf8.encode(text);
          }
        } else {
          body = const <int>[];
        }
      } else {
        body = const <int>[];
      }
      map['$method $url'] = _HarEntry(
        statusCode: status,
        body: body,
        headers: headers,
      );
    }
    return HarReplayFetcher._(map);
  }
  final Map<String, _HarEntry> _entries;

  /// Convenience: load a HAR file from disk.
  static Future<HarReplayFetcher> fromFile(String path) async {
    final content = await File(path).readAsString();
    return HarReplayFetcher.fromJson(content);
  }

  /// Number of entries indexed.
  int get size => _entries.length;

  @override
  Future<HttpFetchResponse> fetch(
    String url, {
    Map<String, String>? headers,
    int? rangeStart,
  }) async {
    final key = 'GET $url';
    final entry = _entries[key];
    if (entry == null) {
      return const HttpFetchResponse(
        statusCode: 404,
        body: Stream<List<int>>.empty(),
      );
    }
    final body = rangeStart != null && rangeStart < entry.body.length
        ? entry.body.sublist(rangeStart)
        : entry.body;
    return HttpFetchResponse(
      statusCode: entry.statusCode,
      body: Stream<List<int>>.fromIterable(<List<int>>[body]),
      contentLength: body.length,
      headers: entry.headers,
    );
  }
}
