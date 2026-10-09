import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class FileEntry {
  FileEntry(this.name, this.isDir, this.size, this.modified, this.mode);
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;

  /// Unix permission bits, when the backend knows them.
  final int? mode;
}

/// A file tree the SFTP view can browse: this computer or a server.
abstract class FileBackend {
  String get label;
  Future<String> home();
  String join(String dir, String name);
  String parent(String path);
  Future<List<FileEntry>> list(String path);
  Future<void> mkdir(String path);
  Future<void> rename(String from, String to);
  Future<void> delete(String path, {required bool isDir});
  Stream<Uint8List> read(String path);
  Future<void> write(String path, Stream<Uint8List> data);
  Future<void> chmod(String path, int mode);
}

class LocalFiles implements FileBackend {
  @override
  String get label => 'This computer';

  @override
  Future<String> home() async =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  @override
  String join(String dir, String name) => dir.endsWith(Platform.pathSeparator)
      ? '$dir$name'
      : '$dir${Platform.pathSeparator}$name';

  @override
  String parent(String path) => Directory(path).parent.path;

  @override
  Future<List<FileEntry>> list(String path) async {
    final out = <FileEntry>[];
    await for (final e in Directory(path).list(followLinks: false)) {
      try {
        final st = await e.stat();
        final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        out.add(
          FileEntry(
            Uri.decodeComponent(name),
            st.type == FileSystemEntityType.directory,
            st.size,
            st.modified,
            Platform.isWindows ? null : st.mode & 0xFFF,
          ),
        );
      } on FileSystemException {
        // Unreadable entry (permissions, broken link): leave it out.
      }
    }
    return out;
  }

  @override
  Future<void> mkdir(String path) => Directory(path).create();

  @override
  Future<void> rename(String from, String to) async {
    if (await FileSystemEntity.isDirectory(from)) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  @override
  Future<void> delete(String path, {required bool isDir}) =>
      isDir ? Directory(path).delete(recursive: true) : File(path).delete();

  @override
  Stream<Uint8List> read(String path) =>
      File(path).openRead().map(Uint8List.fromList);

  @override
  Future<void> write(String path, Stream<Uint8List> data) async {
    final sink = File(path).openWrite();
    try {
      await sink.addStream(data);
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> chmod(String path, int mode) async {
    final r = await Process.run('chmod', [mode.toRadixString(8), path]);
    if (r.exitCode != 0) throw FileSystemException('${r.stderr}'.trim(), path);
  }
}

class RemoteFiles implements FileBackend {
  RemoteFiles(this.sftp, this.label);
  final SftpClient sftp;

  @override
  final String label;

  @override
  Future<String> home() => sftp.absolute('.');

  @override
  String join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  @override
  String parent(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  @override
  Future<List<FileEntry>> list(String path) async {
    final out = <FileEntry>[];
    for (final n in await sftp.listdir(path)) {
      if (n.filename == '.' || n.filename == '..') continue;
      var attr = n.attr;
      if (attr.isSymbolicLink) {
        try {
          attr = await sftp.stat(join(path, n.filename));
        } on SftpStatusError {
          // Dangling link: show it as a plain file.
        }
      }
      out.add(
        FileEntry(
          n.filename,
          attr.isDirectory,
          attr.size ?? 0,
          attr.modifyTime == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(attr.modifyTime! * 1000),
          attr.mode == null ? null : attr.mode!.value & 0xFFF,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> mkdir(String path) => sftp.mkdir(path);

  @override
  Future<void> rename(String from, String to) => sftp.rename(from, to);

  @override
  Future<void> delete(String path, {required bool isDir}) async {
    if (!isDir) return sftp.remove(path);
    for (final e in await list(path)) {
      // A link to a directory is removed as a link, never followed.
      final child = join(path, e.name);
      final link = (await sftp.stat(child, followLink: false)).isSymbolicLink;
      await delete(child, isDir: e.isDir && !link);
    }
    await sftp.rmdir(path);
  }

  @override
  Stream<Uint8List> read(String path) async* {
    final f = await sftp.open(path);
    try {
      yield* f.read();
    } finally {
      await f.close();
    }
  }

  @override
  Future<void> write(String path, Stream<Uint8List> data) async {
    final f = await sftp.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await f.write(data);
    } finally {
      await f.close();
    }
  }

  @override
  Future<void> chmod(String path, int mode) =>
      sftp.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(mode)));
}

class Transfer {
  Transfer(this.name, this.direction);
  final String name;
  final String direction;
  int bytes = 0;
  int? total;
  String current = '';
  bool done = false;
  bool cancelled = false;
  String? error;
}

/// Copies files and folders between two backends, one item at a time.
class TransferManager extends ChangeNotifier {
  final List<Transfer> transfers = [];
  DateTime _lastTick = DateTime(0);
  Future<void> _queue = Future.value();

  bool get busy => transfers.any((t) => !t.done);

  Future<void> copy(
    FileBackend from,
    String fromDir,
    FileEntry entry,
    FileBackend to,
    String toDir,
  ) {
    final t = Transfer(entry.name, '${from.label} → ${to.label}')
      ..total = entry.isDir ? null : entry.size;
    transfers.insert(0, t);
    notifyListeners();
    return _queue = _queue.then((_) async {
      try {
        await _copy(
          t,
          from,
          from.join(fromDir, entry.name),
          entry.isDir,
          to,
          to.join(toDir, entry.name),
        );
      } catch (e) {
        if (!t.cancelled) t.error = e.toString();
      }
      t.done = true;
      notifyListeners();
    });
  }

  Future<void> _copy(
    Transfer t,
    FileBackend from,
    String src,
    bool isDir,
    FileBackend to,
    String dst,
  ) async {
    if (t.cancelled) throw StateError('cancelled');
    if (!isDir) {
      t.current = src;
      await to.write(
        dst,
        from.read(src).map((chunk) {
          if (t.cancelled) throw StateError('cancelled');
          t.bytes += chunk.length;
          _tick();
          return chunk;
        }),
      );
      return;
    }
    try {
      await to.mkdir(dst);
    } catch (_) {
      // Merging into an existing folder is fine; a real failure surfaces on
      // the first file written into it.
    }
    for (final e in await from.list(src)) {
      await _copy(
        t,
        from,
        from.join(src, e.name),
        e.isDir,
        to,
        to.join(dst, e.name),
      );
    }
  }

  void _tick() {
    final now = DateTime.now();
    if (now.difference(_lastTick).inMilliseconds < 120) return;
    _lastTick = now;
    notifyListeners();
  }

  void cancel(Transfer t) {
    t.cancelled = true;
    notifyListeners();
  }

  void clearFinished() {
    transfers.removeWhere((t) => t.done);
    notifyListeners();
  }
}
