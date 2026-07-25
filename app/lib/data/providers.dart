import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../config.dart';
import '../models/member.dart';
import '../models/work.dart';
import '../models/task.dart';
import '../models/time_entry.dart';
import '../models/event.dart';
import '../identity/identity.dart';
import 'pocketbase_repo.dart';
import 'team_stream_repo.dart';

final pocketBaseProvider = Provider<PocketBase>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  // Persist the auth token on-device so the shared password is entered once per
  // device, not every launch. Survives restarts until the token expires.
  final store = AsyncAuthStore(
    save: (data) async => prefs.setString('pb_auth', data),
    clear: () async => prefs.remove('pb_auth'),
    initial: prefs.getString('pb_auth'),
  );
  return PocketBase(kPocketBaseUrl, authStore: store);
});

final repoProvider = Provider<TeamStreamRepo>((ref) {
  final repo = PocketBaseRepo(ref.watch(pocketBaseProvider));
  ref.onDispose(repo.dispose);
  return repo;
});

final membersProvider =
    FutureProvider<List<Member>>((ref) => ref.watch(repoProvider).fetchMembers());

final worksProvider =
    StreamProvider<List<Work>>((ref) => ref.watch(repoProvider).watchWorks());

final tasksProvider =
    StreamProvider<List<Task>>((ref) => ref.watch(repoProvider).watchTasks());

final timeEntriesProvider =
    StreamProvider<List<TimeEntry>>((ref) => ref.watch(repoProvider).watchTimeEntries());

final eventsProvider =
    StreamProvider<List<CalendarEvent>>((ref) => ref.watch(repoProvider).watchEvents());

/// Ticks once a second so live timers re-render.
final clockProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(const Duration(seconds: 1), (_) => DateTime.now());
});

/// Keeps the repo's actor (for history attribution) in sync with the current member.
/// Watch it somewhere always-mounted (the app shell) to keep it active.
final actorSyncProvider = Provider<void>((ref) {
  final meId = ref.watch(identityProvider);
  final members = ref.watch(membersProvider).asData?.value ?? const <Member>[];
  Member? me;
  for (final m in members) {
    if (m.id == meId) me = m;
  }
  ref.watch(repoProvider).setActor(me?.id ?? '', me?.name ?? '');
});
