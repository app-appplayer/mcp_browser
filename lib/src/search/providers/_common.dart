/// Shared helpers for built-in search adapters.
library;

import 'dart:convert';

import '../../ops/http_fetcher.dart';
import '../../registry/search_router.dart';

/// Drain the body of [response] into a UTF-8 string.
Future<String> drainResponseText(HttpFetchResponse response) async {
  final bytes = <int>[];
  await for (final chunk in response.body) {
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Decode [response] as JSON, raising [SearchProviderRateLimitException] on
/// HTTP 429 and [StateError] on other non-2xx responses.
Future<Map<String, dynamic>> decodeJsonResponse(
  HttpFetchResponse response, {
  required String providerId,
}) async {
  if (response.statusCode == 429) {
    throw SearchProviderRateLimitException('$providerId returned 429');
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('$providerId returned HTTP ${response.statusCode}');
  }
  final text = await drainResponseText(response);
  final decoded = jsonDecode(text);
  if (decoded is! Map) {
    throw StateError('$providerId returned non-JSON-object body');
  }
  return Map<String, dynamic>.from(decoded);
}
