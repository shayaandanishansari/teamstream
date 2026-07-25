import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in main() with the real instance.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPrefsProvider must be overridden in main()'),
);

const _memberKey = 'current_member_id';

/// Holds the current member id (who "I" am on this device). No password —
/// pick your name, remembered locally.
class IdentityNotifier extends Notifier<String?> {
  @override
  String? build() => ref.read(sharedPrefsProvider).getString(_memberKey);

  Future<void> select(String memberId) async {
    await ref.read(sharedPrefsProvider).setString(_memberKey, memberId);
    state = memberId;
  }

  Future<void> clear() async {
    await ref.read(sharedPrefsProvider).remove(_memberKey);
    state = null;
  }
}

final identityProvider =
    NotifierProvider<IdentityNotifier, String?>(IdentityNotifier.new);
