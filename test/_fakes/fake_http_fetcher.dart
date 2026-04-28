/// In-memory HTTP fetcher for unit tests.
library;

import 'dart:async';

import 'package:mcp_browser/mcp_browser.dart';

class FakeHttpResponse {
  const FakeHttpResponse({
    this.statusCode = 200,
    required this.body,
    this.headers = const <String, String>{},
  });
  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
}

class FakeHttpFetcher implements HttpFetcher {

  FakeHttpFetcher({
    Map<String, FakeHttpResponse>? responses,
    Map<String, Object>? exceptions,
  })  : responses = responses ?? <String, FakeHttpResponse>{},
        exceptions = exceptions ?? <String, Object>{};
  final Map<String, FakeHttpResponse> responses;
  final Map<String, Object> exceptions;
  int calls = 0;

  @override
  Future<HttpFetchResponse> fetch(
    String url, {
    Map<String, String>? headers,
    int? rangeStart,
  }) async {
    calls++;
    final ex = exceptions[url];
    // ignore: only_throw_errors — test-time arg: whatever the caller passed.
    if (ex != null) throw ex;
    final canned = responses[url];
    if (canned == null) {
      return const HttpFetchResponse(
        statusCode: 404,
        body: Stream<List<int>>.empty(),
      );
    }
    final body = rangeStart != null && rangeStart < canned.body.length
        ? canned.body.sublist(rangeStart)
        : canned.body;
    return HttpFetchResponse(
      statusCode: canned.statusCode,
      body: Stream<List<int>>.fromIterable(<List<int>>[body]),
      contentLength: body.length,
      headers: canned.headers,
    );
  }
}

class FakeVirusScan implements BrowserVirusScanPort {

  const FakeVirusScan({this.clean = true, this.threat});
  final bool clean;
  final String? threat;

  @override
  Future<BrowserVirusScanResult> scan(String filePath) async {
    return BrowserVirusScanResult(clean: clean, threat: threat);
  }
}
