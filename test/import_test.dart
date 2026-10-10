import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marsa/core/importers.dart';

void main() {
  test('CSV in the Termius import layout', () {
    final r = parseImport(
      'Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password,SSH_KEY\n'
      'Production,web-01,"web, eu",203.0.113.10,ssh,22,root,,\n'
      'Production/DB,"db, primary",postgres,203.0.113.20,ssh,2222,deploy,"p@ss,""word""",\n'
      ',router,,192.168.1.1,telnet,23,admin,,\n'
      ',bare,,198.51.100.7,,,,,\n',
    );
    expect(r.source, 'CSV');
    expect(r.hosts.map((h) => h.label), ['web-01', 'db, primary', 'bare']);
    final web = r.hosts[0];
    expect(web.address, '203.0.113.10');
    expect(web.group, 'Production');
    expect(web.tags, ['web', 'eu']);
    expect(web.username, 'root');
    final db = r.hosts[1];
    expect(db.port, 2222);
    expect(db.group, 'Production/DB');
    expect(db.password, 'p@ss,"word"');
    expect(r.hosts[2].port, 22);
  });

  test('generic CSV with other header names and separators', () {
    final r = parseImport(
      'Name;IP Address;User;Port;Folder\r\n'
      'nas;192.168.1.40;adnan;;Home\r\n',
    );
    final h = r.hosts.single;
    expect(h.label, 'nas');
    expect(h.address, '192.168.1.40');
    expect(h.username, 'adnan');
    expect(h.group, 'Home');

    // A header that starts with the word Host is still a CSV, not ssh config.
    expect(parseImport('Host Name,Port\nexample.com,22\n').source, 'CSV');
  });

  test('OpenSSH config', () {
    final r = parseImport('''
Host bastion
  HostName bastion.example.com
  User ops
Host inner
  HostName 10.0.0.5
  Port 2200
  IdentityFile ~/.ssh/id_work
  ProxyJump bastion
Host *
  ServerAliveInterval 30
''');
    expect(r.source, 'OpenSSH config');
    expect(r.hosts.map((h) => h.label), ['bastion', 'inner']);
    expect(r.hosts[1].port, 2200);
    expect(r.hosts[1].identityFile, '~/.ssh/id_work');
    expect(r.hosts[1].proxyJump, 'bastion');
  });

  test('PuTTY registry export, as regedit writes it (UTF-16)', () {
    const reg =
        'Windows Registry Editor Version 5.00\r\n\r\n'
        r'[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions]'
        '\r\n\r\n'
        r'[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Default%20Settings]'
        '\r\n"HostName"=""\r\n"Protocol"="ssh"\r\n"PortNumber"=dword:00000016\r\n\r\n'
        r'[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Web%20Server]'
        '\r\n"HostName"="deploy@203.0.113.10"\r\n"Protocol"="ssh"\r\n'
        '"PortNumber"=dword:000008ae\r\n"UserName"=""\r\n\r\n'
        r'[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\serial]'
        '\r\n"HostName"="COM1"\r\n"Protocol"="serial"\r\n';
    final bytes = Uint8List.fromList([
      0xFF, 0xFE, //
      for (final u in reg.codeUnits) ...[u & 0xFF, u >> 8],
    ]);
    final r = parseImport(decodeText(bytes));
    expect(r.source, 'PuTTY sessions');
    final h = r.hosts.single;
    expect(h.label, 'Web Server');
    expect(h.address, '203.0.113.10');
    expect(h.username, 'deploy');
    expect(h.port, 2222);
  });

  test('MobaXterm sessions file', () {
    final r = parseImport(
      '[Bookmarks]\r\nSubRep=\r\nImgNum=42\r\n'
      'home=#109#0%192.168.1.40%22%adnan%%-1%-1%%%%%0%0%0%%%-1%0\r\n\r\n'
      '[Bookmarks_1]\r\nSubRep=Work\\Prod\r\nImgNum=41\r\n'
      'web=#109#0%203.0.113.10%2222%root%%-1%-1\r\n'
      'desktop=#91#4%10.0.0.9%3389%admin\r\n',
    );
    expect(r.source, 'MobaXterm sessions');
    expect(r.hosts.map((h) => h.label), ['home', 'web']);
    expect(r.hosts[0].username, 'adnan');
    expect(r.hosts[1].port, 2222);
    expect(r.hosts[1].group, 'Work/Prod');
  });

  test('unreadable input is reported, not imported', () {
    expect(() => parseImport('just some notes'), throwsA(isA<ImportError>()));
    expect(() => parseImport(''), throwsA(isA<ImportError>()));
    expect(
      decodeText(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x68, 0x69])),
      'hi',
    );
    expect(decodeText(Uint8List.fromList(latin1.encode('café'))), 'café');
  });
}
