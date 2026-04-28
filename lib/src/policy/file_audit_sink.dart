/// MOD-POL-002 — `FileAuditSink`.
///
/// See `docs/03_DDD/05-audit.md` §3.2 for the design specification and
/// `docs/04_TEST/05-audit.md` IT-031 for the rotation integration scenario.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../_internal.dart';

/// [BrowserAuditSink] implementation that appends JSONL records to a file.
/// Rotation kicks in when the active file exceeds [maxBytesPerFile]: the
/// current file is renamed to `<base>.<n>` and a fresh active file is
/// opened.
class FileAuditSink implements BrowserAuditSink {
  FileAuditSink({
    required String basePath,
    this.maxBytesPerFile = 10 * 1024 * 1024,
  }) : _basePath = basePath {
    final parent = File(_basePath).parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
  }

  final String _basePath;
  final int maxBytesPerFile;

  IOSink? _sink;
  int _bytesWritten = 0;
  int _rotationIndex = 0;

  @override
  Future<void> write(BrowserAuditRecord record) async {
    final line = '${jsonEncode(record.toJson())}\n';
    final bytes = utf8.encode(line).length;
    if (_sink == null) {
      _openActive();
    }
    if (_bytesWritten + bytes > maxBytesPerFile && _bytesWritten > 0) {
      await _rotate();
    }
    _sink!.write(line);
    _bytesWritten += bytes;
  }

  @override
  Future<void> flush() async {
    await _sink?.flush();
  }

  @override
  Stream<BrowserAuditRecord> query(BrowserAuditQuery filter) async* {
    await flush();
    final files = _rotatedFiles()..add(File(_basePath));
    var emitted = 0;
    for (final file in files) {
      if (!file.existsSync()) continue;
      final stream = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        if (line.isEmpty) continue;
        final BrowserAuditRecord record;
        try {
          record = BrowserAuditRecord.fromJson(
            Map<String, dynamic>.from(jsonDecode(line) as Map),
          );
        } on Object {
          continue;
        }
        if (!filter.matches(record)) continue;
        yield record;
        emitted++;
        if (filter.limit != null && emitted >= filter.limit!) return;
      }
    }
  }

  @override
  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      await sink.flush();
      await sink.close();
    }
  }

  void _openActive() {
    final file = File(_basePath);
    _bytesWritten = file.existsSync() ? file.lengthSync() : 0;
    _sink = file.openWrite(mode: FileMode.append);
    _rotationIndex = _nextRotationIndex();
  }

  Future<void> _rotate() async {
    await _sink?.flush();
    await _sink?.close();
    await File(_basePath).rename('$_basePath.$_rotationIndex');
    _rotationIndex++;
    _sink = File(_basePath).openWrite(mode: FileMode.append);
    _bytesWritten = 0;
  }

  int _nextRotationIndex() {
    var idx = 0;
    while (File('$_basePath.$idx').existsSync()) {
      idx++;
    }
    return idx;
  }

  List<File> _rotatedFiles() {
    final out = <File>[];
    var idx = 0;
    while (true) {
      final f = File('$_basePath.$idx');
      if (!f.existsSync()) break;
      out.add(f);
      idx++;
    }
    return out;
  }
}
