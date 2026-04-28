/// Chromium launcher — spawns a Chromium process with remote-debugging
/// enabled and resolves the browser-level WebSocket URL.
///
/// Pure Dart: no `puppeteer`, no Node, no external library. Uses
/// `dart:io` (Process + HttpClient) + `web_socket_channel`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Return value of [ChromiumLauncher.spawn].
class ChromiumProcess {
  ChromiumProcess({
    required this.process,
    required this.wsUrl,
    required this.userDataDir,
  });

  final Process process;
  final String wsUrl;
  final String userDataDir;
}

class ChromiumLauncher {
  ChromiumLauncher({
    this.executablePath,
    this.headless = true,
    this.extraArgs = const <String>[],
  });

  /// Explicit path to the Chromium/Chrome binary. When null, the launcher
  /// auto-discovers based on the OS (Applications/Chromium, which, etc).
  final String? executablePath;

  /// Launch headless by default; flip for Recorder/Selector picker flows.
  final bool headless;

  /// Additional Chromium CLI flags.
  final List<String> extraArgs;

  ChromiumProcess? _current;

  /// Process-wide shared launcher; call [configure] to replace.
  static ChromiumLauncher? _shared;

  static ChromiumLauncher shared() => _shared ??= ChromiumLauncher();

  static void configure(ChromiumLauncher launcher) {
    _shared = launcher;
  }

  /// Return the currently launched Chromium process, spawning it on first
  /// access.
  Future<ChromiumProcess> browser() async {
    if (_current != null) return _current!;
    _current = await _spawn();
    return _current!;
  }

  /// Terminate the current Chromium process. Idempotent.
  Future<void> close() async {
    final cur = _current;
    _current = null;
    if (cur == null) return;
    try {
      cur.process.kill();
      await cur.process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          cur.process.kill(ProcessSignal.sigkill);
          return cur.process.exitCode;
        },
      );
    } on Object {
      // Process already exited — swallow.
    }
    try {
      final dir = Directory(cur.userDataDir);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on Object {/* best-effort */}
  }

  Future<ChromiumProcess> _spawn() async {
    final path = executablePath ?? _findChromiumBinary();
    final userDataDir = await Directory.systemTemp
        .createTemp('mcp_browser_chromium_');
    final args = <String>[
      '--remote-debugging-port=0',
      '--remote-debugging-address=127.0.0.1',
      '--user-data-dir=${userDataDir.path}',
      if (headless) '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-breakpad',
      '--disable-client-side-phishing-detection',
      '--disable-component-update',
      '--disable-default-apps',
      '--disable-dev-shm-usage',
      '--disable-extensions',
      '--disable-features=Translate',
      '--disable-hang-monitor',
      '--disable-sync',
      '--metrics-recording-only',
      '--no-pings',
      '--password-store=basic',
      '--use-mock-keychain',
      ...extraArgs,
      'about:blank',
    ];

    final process = await Process.start(path, args);
    final portRegex =
        RegExp(r'DevTools listening on ws://[^:]+:(\d+)/devtools/browser/');
    final portCompleter = Completer<int>();
    late StreamSubscription<String> sub;
    sub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      final match = portRegex.firstMatch(line);
      if (match != null && !portCompleter.isCompleted) {
        portCompleter.complete(int.parse(match.group(1)!));
        unawaited(sub.cancel());
      }
    });
    final port = await portCompleter.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw StateError(
          'Chromium did not report a DevTools port within 15 seconds. '
          'Check that the binary at `$path` is a recent Chromium build.',
        );
      },
    );

    final wsUrl = await _fetchBrowserWsUrl(port);
    return ChromiumProcess(
      process: process,
      wsUrl: wsUrl,
      userDataDir: userDataDir.path,
    );
  }

  Future<String> _fetchBrowserWsUrl(int port) async {
    final client = HttpClient();
    try {
      final req =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/version'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final wsUrl = json['webSocketDebuggerUrl'] as String?;
      if (wsUrl == null) {
        throw StateError('Chromium /json/version missing webSocketDebuggerUrl');
      }
      return wsUrl;
    } finally {
      client.close(force: true);
    }
  }

  static String _findChromiumBinary() {
    if (Platform.isMacOS) {
      const candidates = <String>[
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta',
        '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
      ];
      for (final p in candidates) {
        if (File(p).existsSync()) return p;
      }
    }
    if (Platform.isLinux) {
      for (final name in const <String>[
        'chromium',
        'chromium-browser',
        'google-chrome',
        'google-chrome-stable',
      ]) {
        final result = Process.runSync('which', <String>[name]);
        if (result.exitCode == 0) {
          final path = (result.stdout as String).trim();
          if (path.isNotEmpty) return path;
        }
      }
    }
    if (Platform.isWindows) {
      for (final p in const <String>[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      ]) {
        if (File(p).existsSync()) return p;
      }
    }
    throw StateError(
      'Chromium not found. Set ChromiumLauncher(executablePath: ...) or '
      'install Chromium/Chrome and make it discoverable.',
    );
  }
}
