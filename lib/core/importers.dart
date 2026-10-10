import 'dart:convert';
import 'dart:typed_data';

import '../ssh/ssh_config.dart';

/// A host read from another program's export, before it becomes a [Host].
class ImportedHost {
  ImportedHost({
    required this.address,
    this.label = '',
    this.port = 22,
    this.username = '',
    this.password = '',
    this.group = '',
    this.tags = const [],
    this.identityFile,
    this.proxyJump,
  });
  final String address;
  final String label;
  final int port;
  final String username;
  final String password;
  final String group;
  final List<String> tags;

  /// OpenSSH config only: the key file and jump-host alias the entry names.
  final String? identityFile;
  final String? proxyJump;
}

class ImportResult {
  ImportResult(this.source, this.hosts);

  /// Human name of the detected format, e.g. "PuTTY sessions".
  final String source;
  final List<ImportedHost> hosts;
}

class ImportError implements Exception {
  ImportError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Text of an export file. Windows tools (regedit, MobaXterm) write UTF-16
/// or a legacy code page rather than UTF-8.
String decodeText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final units = <int>[
      for (var i = 2; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ];
    return String.fromCharCodes(units);
  }
  final start =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  try {
    return utf8.decode(bytes.sublist(start));
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Recognises the file by its content and reads the SSH hosts out of it.
/// Supported: OpenSSH config, CSV (Termius' import layout and similar), PuTTY
/// registry exports and MobaXterm session files.
ImportResult parseImport(String text) {
  final ImportResult result;
  if (text.contains(r'\SimonTatham\PuTTY\Sessions')) {
    result = ImportResult('PuTTY sessions', _putty(text));
  } else if (RegExp(r'^\[Bookmarks', multiLine: true).hasMatch(text)) {
    result = ImportResult('MobaXterm sessions', _mobaXterm(text));
  } else if (RegExp(
    // A `Host alias` line with no separators, so a CSV header such as
    // "Host Name,Port" is not mistaken for one.
    r'^[ \t]*Host[ \t]+[^,;\s]+([ \t]+[^,;\s]+)*[ \t]*\r?$',
    multiLine: true,
    caseSensitive: false,
  ).hasMatch(text)) {
    result = ImportResult('OpenSSH config', [
      for (final e in parseSshConfig(text))
        ImportedHost(
          label: e.alias,
          address: e.hostName ?? e.alias,
          port: e.port,
          username: e.user ?? '',
          identityFile: e.identityFile,
          proxyJump: e.proxyJump,
        ),
    ]);
  } else {
    result = ImportResult('CSV', _csv(text));
  }
  if (result.hosts.isEmpty) {
    throw ImportError(
      'No SSH hosts found. Supported files: an OpenSSH config, a CSV with a '
      'host column, a PuTTY registry export (.reg) or a MobaXterm sessions '
      'file (.mxtsessions).',
    );
  }
  return result;
}

// ---------------------------------------------------------------- CSV

List<List<String>> _rows(String text) {
  final first = text.split('\n').first;
  // Whichever separator the header uses most.
  final sep = [',', ';', '\t'].reduce(
    (a, b) => a.allMatches(first).length >= b.allMatches(first).length ? a : b,
  );
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n') {
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = [];
    } else if (c != '\r') {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
}

// Header names seen in the wild, lower-cased with punctuation removed.
const _columns = {
  'address': [
    'hostnameip',
    'hostname',
    'host',
    'ip',
    'address',
    'ipaddress',
    'server',
  ],
  'label': ['label', 'name', 'title', 'alias', 'sessionname'],
  'port': ['port'],
  'username': ['username', 'user', 'login'],
  'password': ['password', 'pass'],
  'group': ['groups', 'group', 'folder', 'category'],
  'tags': ['tags', 'tag'],
  'protocol': ['protocol', 'type'],
};

List<ImportedHost> _csv(String text) {
  final rows = _rows(text);
  if (rows.length < 2) return [];
  final header = [
    for (final h in rows.first)
      h.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''),
  ];
  int col(String field) {
    for (final name in _columns[field]!) {
      final i = header.indexOf(name);
      if (i >= 0) return i;
    }
    return -1;
  }

  final idx = {for (final f in _columns.keys) f: col(f)};
  if (idx['address']! < 0) return [];
  String at(List<String> row, String field) {
    final i = idx[field]!;
    return i < 0 || i >= row.length ? '' : row[i].trim();
  }

  final out = <ImportedHost>[];
  for (final row in rows.skip(1)) {
    final address = at(row, 'address');
    final protocol = at(row, 'protocol').toLowerCase();
    if (address.isEmpty) continue;
    // Skip telnet/RDP/VNC rows from tools that mix protocols in one sheet.
    if (protocol.isNotEmpty && !protocol.contains('ssh')) continue;
    out.add(
      ImportedHost(
        address: address,
        label: at(row, 'label'),
        port: int.tryParse(at(row, 'port')) ?? 22,
        username: at(row, 'username'),
        password: at(row, 'password'),
        // Nested folders ("Prod/Web") flatten to their path.
        group: at(row, 'group'),
        tags: [
          for (final t in at(row, 'tags').split(RegExp(r'[,;|]')))
            if (t.trim().isNotEmpty) t.trim(),
        ],
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------- PuTTY

String _regString(String block, String name) {
  final m = RegExp(
    '^"$name"="(.*)"\\s*\$',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(block);
  return (m?[1] ?? '').replaceAll(r'\\', r'\').replaceAll(r'\"', '"');
}

List<ImportedHost> _putty(String text) {
  final out = <ImportedHost>[];
  final blocks = text.split(RegExp(r'^\[', multiLine: true)).skip(1);
  for (final block in blocks) {
    final key = block.split(']').first;
    final marker = r'\PuTTY\Sessions\';
    final at = key.indexOf(marker);
    if (at < 0) continue;
    final name = Uri.decodeComponent(key.substring(at + marker.length));
    var address = _regString(block, 'HostName');
    final protocol = _regString(block, 'Protocol');
    if (address.isEmpty || (protocol.isNotEmpty && protocol != 'ssh')) {
      continue;
    }
    // PuTTY allows "user@host" in the host field.
    var user = _regString(block, 'UserName');
    final split = address.lastIndexOf('@');
    if (split > 0) {
      if (user.isEmpty) user = address.substring(0, split);
      address = address.substring(split + 1);
    }
    final port = RegExp(
      r'^"PortNumber"=dword:([0-9a-fA-F]{8})',
      multiLine: true,
    ).firstMatch(block);
    out.add(
      ImportedHost(
        label: name,
        address: address,
        port: port == null ? 22 : int.parse(port[1]!, radix: 16),
        username: user,
        group: 'PuTTY',
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------- MobaXterm

List<ImportedHost> _mobaXterm(String text) {
  final out = <ImportedHost>[];
  var folder = '';
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.startsWith('[')) {
      folder = '';
    } else if (line.startsWith('SubRep=')) {
      folder = line.substring(7).replaceAll(r'\', '/');
    } else if (!line.startsWith('ImgNum=')) {
      // name=#109#0%host%port%user%...   109 is the SSH session type.
      final eq = line.indexOf('=#109#');
      if (eq < 0) continue;
      final fields = line.substring(eq + 1).split('%');
      if (fields.length < 4 || fields[1].isEmpty) continue;
      out.add(
        ImportedHost(
          label: line.substring(0, eq),
          address: fields[1],
          port: int.tryParse(fields[2]) ?? 22,
          username: fields[3],
          group: folder,
        ),
      );
    }
  }
  return out;
}
