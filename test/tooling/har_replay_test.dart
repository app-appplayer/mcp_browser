/// TEST — HAR replay fetcher (Phase 5 Tooling).
library;

import 'dart:convert';

import 'package:mcp_browser/mcp_browser.dart';
import 'package:test/test.dart';

String _har({
  String url = 'https://example.com/file.txt',
  String method = 'GET',
  int status = 200,
  String text = 'hello',
  String? encoding,
  Map<String, String> headers = const <String, String>{'content-type': 'text/plain'},
}) {
  final headerEntries = headers.entries
      .map((MapEntry<String, String> e) =>
          <String, dynamic>{'name': e.key, 'value': e.value})
      .toList();
  return jsonEncode(<String, dynamic>{
    'log': <String, dynamic>{
      'version': '1.2',
      'creator': <String, dynamic>{'name': 'test', 'version': '0'},
      'entries': <dynamic>[
        <String, dynamic>{
          'request': <String, dynamic>{'method': method, 'url': url},
          'response': <String, dynamic>{
            'status': status,
            'headers': headerEntries,
            'content': <String, dynamic>{
              'text': text,
              if (encoding != null) 'encoding': encoding,
            },
          },
        },
      ],
    },
  });
}

void main() {
  group('HarReplayFetcher — parse', () {
    test('indexes a single entry by method + url', () {
      final f = HarReplayFetcher.fromJson(_har());
      expect(f.size, 1);
    });

    test('base64-encoded binary body is decoded', () async {
      final raw = <int>[0, 1, 2, 3];
      final json = _har(
        url: 'https://example.com/bin',
        text: base64.encode(raw),
        encoding: 'base64',
        headers: const <String, String>{'content-type': 'application/octet-stream'},
      );
      final f = HarReplayFetcher.fromJson(json);
      final response = await f.fetch('https://example.com/bin');
      final chunks = <List<int>>[];
      await for (final chunk in response.body) {
        chunks.add(chunk);
      }
      expect(chunks.expand((List<int> e) => e).toList(), raw);
    });

    test('malformed HAR throws HarParseError', () {
      expect(() => HarReplayFetcher.fromJson('"just a string"'),
          throwsA(isA<HarParseError>()));
      expect(() => HarReplayFetcher.fromJson(jsonEncode(<String, dynamic>{})),
          throwsA(isA<HarParseError>()));
    });
  });

  group('HarReplayFetcher — fetch', () {
    test('matches by URL and returns body + headers', () async {
      final f = HarReplayFetcher.fromJson(_har(
        url: 'https://example.com/x',
        text: 'body-x',
      ));
      final r = await f.fetch('https://example.com/x');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], 'text/plain');
      final body = await r.body.fold<List<int>>(
          <int>[], (List<int> acc, List<int> chunk) => acc..addAll(chunk));
      expect(utf8.decode(body), 'body-x');
    });

    test('unknown URL surfaces as 404', () async {
      final f = HarReplayFetcher.fromJson(_har());
      final r = await f.fetch('https://example.com/missing');
      expect(r.statusCode, 404);
    });

    test('rangeStart slices the stored body', () async {
      final f = HarReplayFetcher.fromJson(_har(
        url: 'https://example.com/r',
        text: 'abcdefg',
      ));
      final r = await f.fetch('https://example.com/r', rangeStart: 3);
      final body = await r.body.fold<List<int>>(
          <int>[], (List<int> acc, List<int> chunk) => acc..addAll(chunk));
      expect(utf8.decode(body), 'defg');
    });
  });
}
