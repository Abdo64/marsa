import 'dart:io';

import 'package:flutter/services.dart';

/// The Mac App Store edition runs inside Apple's sandbox, which confines the
/// app to its own container: it sees a folder only after the user has picked
/// it, and it cannot start other programs. This is what it asks macOS for
/// instead. Everywhere else [on] is false and none of it is used.
class Sandbox {
  static final bool on =
      Platform.isMacOS &&
      Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');

  /// The user's real home folder; inside the sandbox `HOME` points at the
  /// app's container.
  static String get home => on
      ? '/Users/${Platform.environment['USER']}'
      : Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '';

  static const _channel = MethodChannel('marsa/native');

  static Future<void> openUrl(String url) async {
    if (await _channel.invokeMethod<bool>('openUrl', {'url': url}) != true) {
      throw Exception('macOS could not open the browser');
    }
  }

  /// Asks the user to pick a folder, starting at [start]. The bookmark lets
  /// the app reach that folder again after a restart, through [useFolder].
  static Future<({String path, String bookmark})?> grantFolder({
    required String message,
    required String start,
    String button = 'Allow',
  }) async {
    final r = await _channel.invokeMapMethod<String, String>('grantFolder', {
      'message': message,
      'start': start,
      'button': button,
    });
    return r == null ? null : (path: r['path']!, bookmark: r['bookmark']!);
  }

  /// Reopens a folder granted earlier; null when macOS no longer honours it.
  static Future<String?> useFolder(String bookmark) =>
      _channel.invokeMethod<String>('useFolder', {'bookmark': bookmark});
}
