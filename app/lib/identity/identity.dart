import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';

/// Overridden in main() with the real instance.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden in main()'),
);

/// Who "I" am on this device = the authenticated member. Backed by the
/// PocketBase auth token (persisted via AsyncAuthStore), so it survives restarts
/// until the token expires — you enter the shared password once per device.
class IdentityNotifier extends Notifier<String?> {
  @override
  String? build() => ref.read(repoProvider).currentMember?.id;

  /// Log in with the shared password. `name` is one of the three members; the
  /// repo derives the backend login identity from it.
  Future<void> login(String name, String password) async {
    final member = await ref.read(repoProvider).authenticate(name, password);
    state = member.id;
  }

  Future<void> logout() async {
    ref.read(repoProvider).signOut();
    state = null;
  }
}

final identityProvider =
    NotifierProvider<IdentityNotifier, String?>(IdentityNotifier.new);
