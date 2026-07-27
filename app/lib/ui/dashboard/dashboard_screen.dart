import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/member.dart';
import '../../models/task.dart';
import '../../models/work.dart';
import '../../theme.dart';

/// Effort concentration: where the team's time actually went.
///
/// One bar per Work, split by member. Bars are scaled against the busiest Work
/// rather than each filling the width, so the comparison ACROSS Works survives —
/// normalising every bar to 100% would show the split but destroy the magnitude,
/// which is the whole question this screen answers.
///
/// Not a leaderboard. Nothing here ranks people; the split exists to show where
/// effort converged, and members keep their own colour wherever they appear.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final works = ref.watch(worksProvider).asData?.value;
    final tasks = ref.watch(tasksProvider).asData?.value;
    final entries = ref.watch(timeEntriesProvider).asData?.value;
    final members = ref.watch(membersProvider).asData?.value;
    // Live entries keep counting, so the bars grow while a timer runs.
    final now = ref.watch(clockProvider).asData?.value ?? DateTime.now();

    if (works == null || tasks == null || entries == null || members == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.teal));
    }

    final workIdOfTask = <String, String>{
      for (final Task t in tasks) t.id: t.workId,
    };

    // work id -> member id -> time
    final byWork = <String, Map<String, Duration>>{};
    final byMember = <String, Duration>{};
    var grand = Duration.zero;

    for (final e in entries) {
      final workId = workIdOfTask[e.taskId];
      if (workId == null) continue;
      final d = e.durationAsOf(now);
      (byWork[workId] ??= {}).update(e.memberId, (v) => v + d, ifAbsent: () => d);
      byMember.update(e.memberId, (v) => v + d, ifAbsent: () => d);
      grand += d;
    }

    Duration totalOf(Work w) =>
        (byWork[w.id]?.values ?? const <Duration>[]).fold(Duration.zero, (a, b) => a + b);

    final rows = works.where((w) => !w.archived).toList()
      ..sort((a, b) => totalOf(b).compareTo(totalOf(a)));

    if (grand == Duration.zero) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insights_rounded, size: 40, color: AppColors.inkDim),
              const SizedBox(height: 12),
              Text('No time tracked yet', style: displayFont(size: 20)),
              const SizedBox(height: 8),
              Text(
                'Tap a task on the Board to start your timer.',
                textAlign: TextAlign.center,
                style: monoFont(size: 11, color: AppColors.inkDim),
              ),
            ],
          ),
        ),
      );
    }

    // Longest bar sets the scale for every other bar.
    final maxMs = rows.isEmpty
        ? 0
        : rows.map((w) => totalOf(w).inMilliseconds).reduce((a, b) => a > b ? a : b);

    // Fixed order, so a member's colour never shifts between bars or sessions.
    final ordered = [...members]..sort((a, b) => a.id.compareTo(b.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        Text('WHERE OUR EFFORT WENT', style: monoFont(size: 10, color: AppColors.inkDim)),
        const SizedBox(height: 6),
        Text(fmtTotal(grand), style: displayFont(size: 34)),
        Text('tracked across ${rows.length} works', style: monoFont(size: 11)),
        const SizedBox(height: 20),
        _Legend(members: ordered, totals: byMember),
        const SizedBox(height: 22),
        for (final w in rows)
          _WorkBar(
            title: w.title,
            total: totalOf(w),
            split: byWork[w.id] ?? const {},
            members: ordered,
            maxMs: maxMs,
          ),
      ],
    );
  }
}

/// Names + totals, so identity is never carried by colour alone — the palette
/// check flags these hues as low-contrast against the page.
class _Legend extends StatelessWidget {
  final List<Member> members;
  final Map<String, Duration> totals;

  const _Legend({required this.members, required this.totals});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final m in members)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: hexToColor(m.color),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(m.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text(
                fmtTotal(totals[m.id] ?? Duration.zero),
                style: monoFont(size: 11, color: AppColors.inkDim),
              ),
            ],
          ),
      ],
    );
  }
}

class _WorkBar extends StatelessWidget {
  final String title;
  final Duration total;
  final Map<String, Duration> split;
  final List<Member> members;
  final int maxMs;

  const _WorkBar({
    required this.title,
    required this.total,
    required this.split,
    required this.members,
    required this.maxMs,
  });

  static const _h = 14.0;
  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    final parts = [
      for (final m in members)
        if ((split[m.id] ?? Duration.zero) > Duration.zero)
          // Sub-millisecond slivers still deserve a flex of at least 1.
          (color: hexToColor(m.color), ms: split[m.id]!.inMilliseconds.clamp(1, 1 << 30)),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 10),
              // Direct label on every bar — the contrast warning makes visible
              // values mandatory rather than optional.
              Text(
                total > Duration.zero ? fmtTotal(total) : '—',
                style: monoFont(
                  size: 11,
                  color: total > Duration.zero ? AppColors.ink : AppColors.inkDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          LayoutBuilder(
            builder: (context, c) {
              final filled = maxMs == 0 ? 0.0 : c.maxWidth * (total.inMilliseconds / maxMs);
              return SizedBox(
                width: c.maxWidth,
                height: _h,
                child: Stack(
                  children: [
                    // Empty track, so a Work with no time still reads as a row
                    // rather than vanishing. Positioned.fill because a bare
                    // decorated Container in a Stack gets loose constraints and
                    // would collapse to nothing.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.line.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    if (parts.isNotEmpty)
                      SizedBox(
                        width: filled,
                        height: _h,
                        child: Row(
                          children: [
                            for (var i = 0; i < parts.length; i++) ...[
                              if (i > 0) const SizedBox(width: _gap),
                              Expanded(
                                flex: parts[i].ms,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: parts[i].color,
                                    borderRadius: BorderRadius.horizontal(
                                      left: Radius.circular(i == 0 ? 4 : 0),
                                      right: Radius.circular(i == parts.length - 1 ? 4 : 0),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
