import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'crypto.dart';
import 'sync.dart';

/// A cloud drive the vault file can be kept in after signing in to it.
class CloudService {
  CloudService({
    required this.type,
    required this.name,
    required this.clientId,
    this.clientSecret = '',
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.apiUrl,
    required this.scope,
    this.authExtras = const {},
    required this.where,
  });

  /// The [SyncConfig.type] this service is stored under.
  final String type;
  final String name;

  /// Identifies Marsa to the service. Empty in a build made without one,
  /// which hides the service.
  String clientId;
  String clientSecret;
  String authorizeUrl;
  String tokenUrl;
  String apiUrl;
  final String scope;
  final Map<String, String> authExtras;

  /// Where the file ends up, in the user's words.
  final String where;

  bool get available => clientId.isNotEmpty;
}

/// A sign-in waiting for the user to finish in their browser.
class CloudSignIn {
  CloudSignIn._(this.token, this.cancel);

  /// Completes with the long-lived token to keep in the vault's sync
  /// settings, or fails with a [SyncError].
  final Future<String> token;
  final void Function() cancel;
}

class Cloud {
  static final dropbox = CloudService(
    type: SyncConfig.dropbox,
    name: 'Dropbox',
    clientId: const String.fromEnvironment('DROPBOX_APP_KEY'),
    authorizeUrl: 'https://www.dropbox.com/oauth2/authorize',
    tokenUrl: 'https://api.dropboxapi.com/oauth2/token',
    apiUrl: 'https://content.dropboxapi.com',
    scope: 'files.content.read files.content.write',
    authExtras: const {'token_access_type': 'offline'},
    where: 'Marsa\'s own folder under Apps in your Dropbox',
  );

  static final google = CloudService(
    type: SyncConfig.google,
    name: 'Google Drive',
    clientId: const String.fromEnvironment('GOOGLE_CLIENT_ID'),
    // Google asks desktop apps to send this and does not treat it as secret.
    clientSecret: const String.fromEnvironment('GOOGLE_CLIENT_SECRET'),
    authorizeUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    apiUrl: 'https://www.googleapis.com',
    // Marsa's own hidden folder: it cannot see anything else in the Drive.
    scope: 'https://www.googleapis.com/auth/drive.appdata',
    authExtras: const {'access_type': 'offline', 'prompt': 'consent'},
    where: 'Marsa\'s private app folder in your Google Drive',
  );

  static final all = [dropbox, google];

  static CloudService? of(String type) =>
      all.where((s) => s.type == type).firstOrNull;

  /// The port the browser hands the sign-in back on. Fixed, because the
  /// services only accept an address registered in advance.
  static int redirectPort = 53127;
  static String get redirectUri => 'http://localhost:$redirectPort/';

  static Future<void> Function(String url) openBrowser = _openBrowser;

  static Future<void> _openBrowser(String url) async {
    final (cmd, args) = Platform.isMacOS
        ? ('open', [url])
        : Platform.isWindows
        ? ('rundll32', ['url.dll,FileProtocolHandler', url])
        : ('xdg-open', [url]);
    await Process.run(cmd, args);
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// Opens the service's sign-in page in the browser and waits for the
  /// user to approve. Nothing but the resulting token reaches Marsa: the
  /// password is typed on the service's own page.
  static CloudSignIn signIn(CloudService s) {
    final servers = <HttpServer>[];
    final done = Completer<String>();
    void close() {
      for (final server in servers) {
        server.close(force: true);
      }
    }

    void fail(Object e) {
      if (!done.isCompleted) done.completeError(e);
      close();
    }

    final verifier = _b64(randomBytes(48));
    final challenge = _b64(
      SHA256Digest().process(Uint8List.fromList(ascii.encode(verifier))),
    );
    final state = _b64(randomBytes(16));

    Future<void> handle(HttpRequest req) async {
      final q = req.uri.queryParameters;
      // Favicon requests and anything not from this sign-in are not it.
      if (q['state'] != state) {
        req.response.statusCode = HttpStatus.notFound;
        return req.response.close();
      }
      final ok = q['code'] != null;
      req.response
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8"><title>Marsa</title>'
          '<body style="font:16px system-ui;margin:15vh auto;max-width:28em;'
          'text-align:center"><h2>${ok ? 'Signed in' : 'Sign-in was not completed'}</h2>'
          '<p>You can close this tab and go back to Marsa.</p>',
        );
      await req.response.close();
      if (!ok) {
        return fail(
          SyncError(
            '${s.name} sign-in was cancelled'
            '${q['error'] == null ? '' : ' (${q['error']})'}',
          ),
        );
      }
      try {
        final reply = await _form(s.tokenUrl, {
          'grant_type': 'authorization_code',
          'code': q['code']!,
          'redirect_uri': redirectUri,
          'client_id': s.clientId,
          'code_verifier': verifier,
          if (s.clientSecret.isNotEmpty) 'client_secret': s.clientSecret,
        });
        final token = reply.json['refresh_token'] as String?;
        if (!reply.ok || token == null) {
          throw SyncError('${s.name} did not complete the sign-in');
        }
        if (!done.isCompleted) done.complete(token);
        close();
      } catch (e) {
        fail(e);
      }
    }

    () async {
      try {
        // "localhost" is IPv4 for some browsers and IPv6 for others.
        servers.add(
          await HttpServer.bind(InternetAddress.loopbackIPv4, redirectPort),
        );
        try {
          servers.add(
            await HttpServer.bind(InternetAddress.loopbackIPv6, redirectPort),
          );
        } on SocketException {
          // No IPv6 on this machine.
        }
      } on SocketException {
        return fail(
          SyncError(
            'Port $redirectPort on this computer is in use, so the browser '
            'cannot hand the sign-in back. Close the program using it and '
            'try again.',
          ),
        );
      }
      for (final server in servers) {
        server.listen(handle);
      }
      final url = Uri.parse(s.authorizeUrl).replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': s.clientId,
          'redirect_uri': redirectUri,
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'scope': s.scope,
          ...s.authExtras,
        },
      );
      try {
        await openBrowser(url.toString());
      } catch (e) {
        fail(SyncError('Could not open the browser ($e)'));
      }
    }();

    final timeout = Timer(
      const Duration(minutes: 5),
      () => fail(SyncError('${s.name} sign-in timed out')),
    );
    return CloudSignIn._(
      done.future.whenComplete(timeout.cancel),
      () => fail(SyncError('${s.name} sign-in was cancelled')),
    );
  }

  // Short-lived access tokens, by service and the long-lived token they
  // came from.
  static final _access = <(String, String), (String, DateTime)>{};

  /// Drops the cached access tokens, as locking the vault should.
  static void forgetSessions() => _access.clear();

  static Future<String> _accessToken(CloudService s, String refresh) async {
    final cached = _access[(s.type, refresh)];
    if (cached != null && cached.$2.isAfter(DateTime.now())) return cached.$1;
    final reply = await _form(s.tokenUrl, {
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': s.clientId,
      if (s.clientSecret.isNotEmpty) 'client_secret': s.clientSecret,
    });
    final token = reply.json['access_token'] as String?;
    if (!reply.ok || token == null) {
      throw SyncError(
        reply.status == 400 || reply.status == 401
            ? '${s.name} no longer accepts this sign-in. Set sync up again '
                  'in Settings to sign in.'
            : '${s.name} sign-in failed (HTTP ${reply.status})',
      );
    }
    final seconds = (reply.json['expires_in'] as num?)?.toInt() ?? 600;
    _access[(s.type, refresh)] = (
      token,
      DateTime.now().add(Duration(seconds: seconds - 60)),
    );
    return token;
  }

  /// The vault file [name] in [s], reached with the token from [signIn].
  static SyncIo io(CloudService s, String refresh, String name) {
    if (!s.available) {
      throw SyncError('This build of Marsa cannot sign in to ${s.name}');
    }
    if (refresh.isEmpty) throw SyncError('Not signed in to ${s.name}');
    return s == dropbox
        ? _DropboxIo(s, refresh, name)
        : _GoogleIo(s, refresh, name);
  }
}

class _Reply {
  _Reply(this.status, this.body);
  final int status;
  final Uint8List body;

  bool get ok => status >= 200 && status < 300;
  String get text => utf8.decode(body, allowMalformed: true);
  Map<String, dynamic> get json {
    try {
      final j = jsonDecode(text);
      return j is Map<String, dynamic> ? j : const {};
    } on FormatException {
      return const {};
    }
  }
}

Future<_Reply> _http(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  List<int>? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close().timeout(const Duration(seconds: 60));
    final bytes = BytesBuilder(copy: false);
    await res.forEach(bytes.add).timeout(const Duration(seconds: 60));
    return _Reply(res.statusCode, bytes.takeBytes());
  } on Exception catch (e) {
    throw SyncError('Cannot reach ${url.host} ($e)');
  } finally {
    client.close(force: true);
  }
}

Future<_Reply> _form(String url, Map<String, String> fields) => _http(
  'POST',
  Uri.parse(url),
  headers: {'content-type': 'application/x-www-form-urlencoded'},
  body: utf8.encode(Uri(queryParameters: fields).query),
);

abstract class _CloudIo implements SyncIo {
  _CloudIo(this.service, this.refresh, this.name);
  final CloudService service;
  final String refresh;
  final String name;

  Future<_Reply> call(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final token = await Cloud._accessToken(service, refresh);
    final reply = await _http(
      method,
      Uri.parse(
        '${service.apiUrl}$path',
      ).replace(queryParameters: query.isEmpty ? null : query),
      headers: {'authorization': 'Bearer $token', ...headers},
      body: body,
    );
    if (reply.status == 401) {
      Cloud._access.remove((service.type, refresh));
      throw SyncError(
        '${service.name} no longer accepts this sign-in. Set sync up again '
        'in Settings to sign in.',
      );
    }
    return reply;
  }

  Never failed(String what, _Reply reply) => throw SyncError(
    '${service.name} could not $what the vault file (HTTP ${reply.status})',
  );
}

class _DropboxIo extends _CloudIo {
  _DropboxIo(super.service, super.refresh, super.name);

  // This header must be plain ASCII.
  String _arg(Map<String, dynamic> j) => jsonEncode(j).replaceAllMapped(
    RegExp(r'[^\x20-\x7e]'),
    (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
  );

  @override
  Future<String?> read() async {
    final reply = await call(
      'POST',
      '/2/files/download',
      headers: {
        'dropbox-api-arg': _arg({'path': '/$name'}),
      },
    );
    if (reply.status == 409 && reply.text.contains('not_found')) return null;
    if (!reply.ok) failed('read', reply);
    return reply.text;
  }

  @override
  Future<void> write(String content) async {
    final reply = await call(
      'POST',
      '/2/files/upload',
      headers: {
        'dropbox-api-arg': _arg({
          'path': '/$name',
          'mode': 'overwrite',
          'mute': true,
        }),
        'content-type': 'application/octet-stream',
      },
      body: utf8.encode(content),
    );
    if (!reply.ok) failed('save', reply);
  }
}

class _GoogleIo extends _CloudIo {
  _GoogleIo(super.service, super.refresh, super.name);

  Future<String?> _find() async {
    final reply = await call(
      'GET',
      '/drive/v3/files',
      query: {
        'spaces': 'appDataFolder',
        'q':
            "name = '${name.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}' "
            'and trashed = false',
        // Two devices can both create the file; everyone agrees on the oldest.
        'orderBy': 'createdTime',
        'fields': 'files(id)',
      },
    );
    if (!reply.ok) failed('look for', reply);
    final files = reply.json['files'] as List? ?? const [];
    return files.isEmpty ? null : (files.first as Map)['id'] as String;
  }

  @override
  Future<String?> read() async {
    final id = await _find();
    if (id == null) return null;
    final reply = await call(
      'GET',
      '/drive/v3/files/$id',
      query: {'alt': 'media'},
    );
    if (!reply.ok) failed('read', reply);
    return reply.text;
  }

  @override
  Future<void> write(String content) async {
    final id = await _find();
    final _Reply reply;
    if (id != null) {
      reply = await call(
        'PATCH',
        '/upload/drive/v3/files/$id',
        query: {'uploadType': 'media'},
        headers: {'content-type': 'application/octet-stream'},
        body: utf8.encode(content),
      );
    } else {
      const boundary = 'marsa-vault-upload';
      reply = await call(
        'POST',
        '/upload/drive/v3/files',
        query: {'uploadType': 'multipart'},
        headers: {'content-type': 'multipart/related; boundary=$boundary'},
        body: utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode({
            'name': name,
            'parents': ['appDataFolder'],
          })}\r\n'
          '--$boundary\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'
          '$content\r\n'
          '--$boundary--\r\n',
        ),
      );
    }
    if (!reply.ok) failed('save', reply);
  }
}
