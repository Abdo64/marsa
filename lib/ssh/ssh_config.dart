/// One concrete `Host` block from an OpenSSH client config.
class SshConfigEntry {
  SshConfigEntry(this.alias);
  final String alias;
  String? hostName;
  String? user;
  int port = 22;
  String? identityFile;
  String? proxyJump;
}

/// Reads the subset of `~/.ssh/config` that maps onto a saved host. Pattern
/// blocks (`Host *`, `Host *.corp`) and `Match` sections are skipped.
List<SshConfigEntry> parseSshConfig(String text) {
  final out = <SshConfigEntry>[];
  var current = <SshConfigEntry>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final m = RegExp(r'^(\S+?)(?:\s*=\s*|\s+)(.*)$').firstMatch(line);
    if (m == null) continue;
    final key = m[1]!.toLowerCase();
    var value = m[2]!.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (key == 'host') {
      current = [
        for (final a in value.split(RegExp(r'\s+')))
          if (!a.contains(RegExp(r'[*?!]'))) SshConfigEntry(a),
      ];
      out.addAll(current);
    } else if (key == 'match') {
      current = [];
    } else {
      for (final e in current) {
        switch (key) {
          case 'hostname':
            e.hostName ??= value;
          case 'user':
            e.user ??= value;
          case 'port':
            e.port = int.tryParse(value) ?? e.port;
          case 'identityfile':
            e.identityFile ??= value;
          case 'proxyjump':
            // Only a single plain alias can be mapped to a saved jump host.
            e.proxyJump ??= value.split(',').first.trim();
        }
      }
    }
  }
  return out;
}
