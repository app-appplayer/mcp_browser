/// HTTP fetcher contract used by [DownloadManager].
///
/// The default implementation uses `dart:io HttpClient`. Tests inject a
/// fake to drive deterministic byte streams and status codes.
library;

import 'dart:async';
import 'dart:io';

/// Result of a single fetch.
class HttpFetchResponse {

  const HttpFetchResponse({
    required this.statusCode,
    required this.body,
    this.contentLength,
    this.headers = const <String, String>{},
  });
  final int statusCode;
  final Stream<List<int>> body;
  final int? contentLength;
  final Map<String, String> headers;
}

/// Streaming HTTP fetcher.
abstract class HttpFetcher {
  /// Issue a GET against [url]. When [rangeStart] is non-null, a Range
  /// header `bytes=$rangeStart-` is sent and the server is expected to
  /// reply with 206 Partial Content.
  Future<HttpFetchResponse> fetch(
    String url, {
    Map<String, String>? headers,
    int? rangeStart,
  });
}

/// `dart:io` backed implementation. Re-uses a single [HttpClient].
class IoHttpFetcher implements HttpFetcher {

  IoHttpFetcher() : _client = HttpClient();
  final HttpClient _client;

  @override
  Future<HttpFetchResponse> fetch(
    String url, {
    Map<String, String>? headers,
    int? rangeStart,
  }) async {
    final uri = Uri.parse(url);
    final request = await _client.getUrl(uri);
    headers?.forEach(request.headers.set);
    if (rangeStart != null) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-');
    }
    final response = await request.close();
    final hdrs = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      hdrs[name] = values.join(',');
    });
    return HttpFetchResponse(
      statusCode: response.statusCode,
      body: response,
      contentLength:
          response.contentLength >= 0 ? response.contentLength : null,
      headers: hdrs,
    );
  }

  /// Close the underlying client. Hosts call this on shutdown.
  void close({bool force = false}) {
    _client.close(force: force);
  }
}
