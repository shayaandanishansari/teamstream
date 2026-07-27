import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/identity.dart';

/// Which Works this person has folded shut, remembered on this device.
///
/// Deliberately NOT shared state: how much of the board fits on your screen is
/// a fact about your screen, not about the work. Collapsing on your phone
/// shouldn't fold the same Work on someone else's laptop.
///
/// Only Works the person has explicitly toggled are stored — the map is read as
/// `folding[id] ?? theDefault`. Everything untouched follows whatever default
/// the board computes, so changing that default later doesn't have to fight
/// stale saved state.
class WorkFolding extends Notifier<Map<String, bool>> {
  static const _key = 'work_folding';

  @override
  Map<String, bool> build() {
    final saved = ref.read(sharedPrefsProvider).getStringList(_key) ?? const [];
    return {
      for (final row in saved)
        if (row.length > 2) row.substring(2): row.startsWith('1:'),
    };
  }

  void setCollapsed(String workId, bool collapsed) {
    state = {...state, workId: collapsed};
    ref.read(sharedPrefsProvider).setStringList(
          _key,
          [for (final e in state.entries) '${e.value ? 1 : 0}:${e.key}'],
        );
  }
}

final workFoldingProvider =
    NotifierProvider<WorkFolding, Map<String, bool>>(WorkFolding.new);
