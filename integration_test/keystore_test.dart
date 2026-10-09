// Runs inside the real app on a desktop device, so it exercises the actual OS
// credential store rather than a fake:
//
//     flutter test integration_test -d macos     (or -d windows)
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:marsa/core/crypto.dart';
import 'package:marsa/platform/keystore.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a vault key round-trips through the OS credential store', (
    tester,
  ) async {
    final store = SystemKeyStore();
    final id = 'integration-test-${newId()}';
    final key = randomBytes(32);
    try {
      expect(await store.read(id), isNull);
      await store.write(id, key);
      expect(await store.read(id), key);
      final replaced = randomBytes(32);
      await store.write(id, replaced);
      expect(await store.read(id), replaced);
    } finally {
      await store.delete(id);
    }
    expect(await store.read(id), isNull);
  });
}
