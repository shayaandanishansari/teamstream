import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/providers.dart';
import '../../models/member.dart';
import '../../models/task.dart';
import '../../models/time_entry.dart';
import '../../models/time_math.dart';
import '../../models/work.dart';
import '../../theme.dart';

/// The window the log list is showing.
enum LogPeriod {
  today('Today'),
  week('This week'),
  month('This month'),
  all('All time');

  final String label;
  const LogPeriod(this.label);

  /// `[from, to)` for this period as of [now]. `all` starts at the epoch.
  (DateTime, DateTime) range(DateTime now) => switch (this) {
        LogPeriod.today => (startOfDay(now), nextDay(now)),
        LogPeriod.week => (startOfWeek(now), nextDay(now)),
        LogPeriod.month => (startOfMonth(now), nextDay(now)),
        LogPeriod.all => (DateTime.fromMillisecondsSinceEpoch(0), nextDay(now)),
      };
}

/// Effort concentration: where the team's time actually went.
///
/// Three stacked readings of the same entries, narrow to wide:
///   1. TODAY — one bar per Work, split by member. Today only, because the
///      running total stops moving perceptibly after a few weeks and a bar
///      that never changes tells you nothing about where effort is going now.
///   2. THIS WEEK — the same time re-cut per day, so today has a shape to sit
///      against.
///   3. THE LOG — the raw entries behind both, filterable.
///
/// Bars in (1) are scaled against the busiest Work rather than each filling the
/// width, so the comparison ACROSS Works survives — normalising every bar to
/// 100% would show the split but destroy the magnitude, which is the whole
/// question this screen answers.
///
/// Not a leaderboard. Nothing here ranks people; the split exists to show where
/// effort converged, and members keep their own colour wherever they appear.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _taskFilter; // null = every task
  String? _memberFilter; // null = everyone
  LogPeriod _period = LogPeriod.today;

  @override
  Widget build(BuildContext context) {
    final works = ref.watch(worksProvider).asData?.value;
    final tasks = ref.watch(tasksProvider).asData?.value;
    final entries = ref.watch(timeEntriesProvider).asData?.value;
    final members = ref.watch(membersProvider).asData?.value;
    // Live entries keep counting, so the bars grow while a timer runs.
    final now = ref.watch(clockProvider).asData?.value ?? DateTime.now();

    if (works == null || tasks == null || entries == null || members == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.teal));
    }

    if (entries.isEmpty) return const _NothingTrackedYet();

    final taskById = <String, Task>{for (final Task t in tasks) t.id: t};
    final workById = <String, Work>{for (final Work w in works) w.id: w};

    // Fixed order, so a member's colour never shifts between bars or sessions.
    final ordered = [...members]..sort((a, b) => a.id.compareTo(b.id));

    final dayStart = startOfDay(now);
    final dayEnd = nextDay(now);

    // ---- today: work id -> member id -> time ----
    final byWork = <String, Map<String, Duration>>{};
    final byMember = <String, Duration>{};
    var today = Duration.zero;

    for (final e in entries) {
      final workId = taskById[e.taskId]?.workId;
      if (workId == null) continue;
      final d = overlapWithin(e, dayStart, dayEnd, now);
      if (d == Duration.zero) continue;
      (byWork[workId] ??= {}).update(e.memberId, (v) => v + d, ifAbsent: () => d);
      byMember.update(e.memberId, (v) => v + d, ifAbsent: () => d);
      today += d;
    }

    Duration totalOf(Work w) =>
        (byWork[w.id]?.values ?? const <Duration>[]).fold(Duration.zero, (a, b) => a + b);

    // Only Works touched today — with a daily window most Works are zero, and
    // a page of empty tracks buries the ones that moved.
    final rows = works.where((w) => totalOf(w) > Duration.zero).toList()
      ..sort((a, b) => totalOf(b).compareTo(totalOf(a)));

    // Longest bar sets the scale for every other bar.
    final maxMs = rows.isEmpty
        ? 0
        : rows.map((w) => totalOf(w).inMilliseconds).reduce((a, b) => a > b ? a : b);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        Text('WHERE OUR EFFORT WENT TODAY',
            style: monoFont(size: 10, color: AppColors.inkDim)),
        const SizedBox(height: 6),
        Text(fmtTotal(today), style: displayFont(size: 34)),
        Text(
          rows.isEmpty
              ? DateFormat('EEEE d MMMM').format(now)
              : 'tracked across ${rows.length} work${rows.length == 1 ? '' : 's'} today',
          style: monoFont(size: 11),
        ),
        const SizedBox(height: 20),
        if (rows.isEmpty)
          _Quiet('Nothing tracked today yet — tap a task on the Board to start your timer.')
        else ...[
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
        const _SectionRule(),
        _WeekRecap(entries: entries, members: ordered, now: now),
        const _SectionRule(),
        _LogSection(
          entries: entries,
          taskById: taskById,
          workById: workById,
          members: ordered,
          now: now,
          taskFilter: _taskFilter,
          memberFilter: _memberFilter,
          period: _period,
          onTask: (v) => setState(() => _taskFilter = v),
          onMember: (v) => setState(() => _memberFilter = v),
          onPeriod: (v) => setState(() => _period = v),
        ),
      ],
    );
  }
}

class _NothingTrackedYet extends StatelessWidget {
  const _NothingTrackedYet();

  @override
  Widget build(BuildContext context) {
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

// ---------------------------------------------------------------- week recap

/// Mon–Sun of the current week, one row per day, each split by member.
///
/// Days are shown even when empty: the gaps are the point of a weekly read,
/// and dropping them would make a two-day week look identical to a full one.
class _WeekRecap extends StatelessWidget {
  final List<TimeEntry> entries;
  final List<Member> members;
  final DateTime now;

  const _WeekRecap({required this.entries, required this.members, required this.now});

  @override
  Widget build(BuildContext context) {
    final monday = startOfWeek(now);
    final days = [for (var i = 0; i < 7; i++) DateTime(monday.year, monday.month, monday.day + i)];

    // day index -> member id -> time
    final split = List.generate(7, (_) => <String, Duration>{});
    final totals = List.filled(7, Duration.zero);
    var week = Duration.zero;

    for (var i = 0; i < 7; i++) {
      final from = days[i];
      final to = nextDay(from);
      for (final e in entries) {
        final d = overlapWithin(e, from, to, now);
        if (d == Duration.zero) continue;
        split[i].update(e.memberId, (v) => v + d, ifAbsent: () => d);
        totals[i] += d;
        week += d;
      }
    }

    final maxMs = totals.map((d) => d.inMilliseconds).reduce((a, b) => a > b ? a : b);
    final today = startOfDay(now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('THIS WEEK', style: monoFont(size: 10, color: AppColors.inkDim)),
            const Spacer(),
            Text(fmtTotal(week), style: monoFont(size: 12, color: AppColors.ink)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${DateFormat('MMM d').format(days.first)} – ${DateFormat('MMM d').format(days.last)}',
          style: monoFont(size: 11),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < 7; i++)
          _DayRow(
            day: days[i],
            total: totals[i],
            split: split[i],
            members: members,
            maxMs: maxMs,
            isToday: days[i] == today,
            isFuture: days[i].isAfter(today),
          ),
      ],
    );
  }
}

class _DayRow extends StatelessWidget {
  final DateTime day;
  final Duration total;
  final Map<String, Duration> split;
  final List<Member> members;
  final int maxMs;
  final bool isToday;
  final bool isFuture;

  const _DayRow({
    required this.day,
    required this.total,
    required this.split,
    required this.members,
    required this.maxMs,
    required this.isToday,
    required this.isFuture,
  });

  static const _h = 10.0;

  @override
  Widget build(BuildContext context) {
    final parts = [
      for (final m in members)
        if ((split[m.id] ?? Duration.zero) > Duration.zero)
          (color: hexToColor(m.color), ms: split[m.id]!.inMilliseconds.clamp(1, 1 << 30)),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              DateFormat('EEE d').format(day).toUpperCase(),
              style: monoFont(
                size: 10,
                color: isToday ? AppColors.teal : AppColors.inkDim,
                weight: isToday ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final filled = maxMs == 0 ? 0.0 : c.maxWidth * (total.inMilliseconds / maxMs);
                return SizedBox(
                  height: _h,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.line.withValues(alpha: isFuture ? 0.35 : 0.7),
                            borderRadius: BorderRadius.circular(3),
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
                                if (i > 0) const SizedBox(width: 2),
                                Expanded(
                                  flex: parts[i].ms,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: parts[i].color,
                                      borderRadius: BorderRadius.horizontal(
                                        left: Radius.circular(i == 0 ? 3 : 0),
                                        right: Radius.circular(i == parts.length - 1 ? 3 : 0),
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
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 52,
            child: Text(
              total > Duration.zero ? fmtTotal(total) : '—',
              textAlign: TextAlign.right,
              style: monoFont(
                size: 11,
                color: total > Duration.zero ? AppColors.ink : AppColors.inkDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- the log

/// Every entry behind the bars above, newest first, filtered three ways.
///
/// The list scrolls inside a fixed height rather than extending the page: the
/// filters have to stay on screen while you read the result, otherwise you
/// scroll back up to change them on every question.
class _LogSection extends StatelessWidget {
  final List<TimeEntry> entries;
  final Map<String, Task> taskById;
  final Map<String, Work> workById;
  final List<Member> members;
  final DateTime now;
  final String? taskFilter;
  final String? memberFilter;
  final LogPeriod period;
  final ValueChanged<String?> onTask;
  final ValueChanged<String?> onMember;
  final ValueChanged<LogPeriod> onPeriod;

  const _LogSection({
    required this.entries,
    required this.taskById,
    required this.workById,
    required this.members,
    required this.now,
    required this.taskFilter,
    required this.memberFilter,
    required this.period,
    required this.onTask,
    required this.onMember,
    required this.onPeriod,
  });

  @override
  Widget build(BuildContext context) {
    final (from, to) = period.range(now);

    // Overlap, not start-time: a session that began before the window but ran
    // into it is part of what happened during that window.
    final shown = entries.where((e) {
      if (taskFilter != null && e.taskId != taskFilter) return false;
      if (memberFilter != null && e.memberId != memberFilter) return false;
      return overlapWithin(e, from, to, now) > Duration.zero;
    }).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    final logged = shown.fold(Duration.zero, (a, e) => a + e.durationAsOf(now));

    // Only tasks that have ever been tracked are worth offering as a filter.
    final trackedTaskIds = <String>{for (final e in entries) e.taskId};
    final taskOptions = [
      for (final id in trackedTaskIds) ?taskById[id],
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final memberName = <String, Member>{for (final m in members) m.id: m};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('THE LOG', style: monoFont(size: 10, color: AppColors.inkDim)),
            const Spacer(),
            Text(
              '${shown.length} entr${shown.length == 1 ? 'y' : 'ies'} · ${fmtTotal(logged)}',
              style: monoFont(size: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FilterPill<String?>(
              icon: Icons.checklist_rounded,
              label: taskFilter == null
                  ? 'All tasks'
                  : (taskById[taskFilter]?.title ?? 'All tasks'),
              active: taskFilter != null,
              value: taskFilter,
              options: [
                (null, 'All tasks'),
                for (final t in taskOptions) (t.id, t.title),
              ],
              onSelected: onTask,
            ),
            _FilterPill<String?>(
              icon: Icons.person_outline_rounded,
              label: memberFilter == null
                  ? 'Everyone'
                  : (memberName[memberFilter]?.name ?? 'Everyone'),
              active: memberFilter != null,
              value: memberFilter,
              options: [
                (null, 'Everyone'),
                for (final m in members) (m.id, m.name),
              ],
              onSelected: onMember,
            ),
            _FilterPill<LogPeriod>(
              icon: Icons.calendar_today_rounded,
              label: period.label,
              active: period != LogPeriod.today,
              value: period,
              options: [for (final p in LogPeriod.values) (p, p.label)],
              onSelected: onPeriod,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          height: 340,
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'No entries match these filters.',
                      textAlign: TextAlign.center,
                      style: monoFont(size: 11),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: shown.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    thickness: 1,
                    color: AppColors.line,
                  ),
                  itemBuilder: (context, i) {
                    final e = shown[i];
                    final task = taskById[e.taskId];
                    return _LogRow(
                      entry: e,
                      taskTitle: task?.title ?? 'Deleted task',
                      workTitle: task == null ? null : workById[task.workId]?.title,
                      member: memberName[e.memberId],
                      now: now,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  final TimeEntry entry;
  final String taskTitle;
  final String? workTitle;
  final Member? member;
  final DateTime now;

  const _LogRow({
    required this.entry,
    required this.taskTitle,
    required this.workTitle,
    required this.member,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final started = entry.startedAt;
    final clock = DateFormat('HH:mm');
    final span = entry.isLive
        ? '${clock.format(started)} → now'
        : '${clock.format(started)} → ${clock.format(entry.endedAt!)}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: hexToColor(member?.color ?? '#5C6D6A'),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  taskTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    member?.name ?? 'Someone',
                    ?workTitle,
                    DateFormat('EEE d MMM').format(started),
                    span,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoFont(size: 10),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                fmtTotal(entry.durationAsOf(now)),
                style: monoFont(size: 11, color: AppColors.ink),
              ),
              if (entry.isLive) ...[
                const SizedBox(height: 2),
                Text('LIVE', style: monoFont(size: 9, color: AppColors.teal, weight: FontWeight.w700)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A tap-to-choose pill. PopupMenuButton rather than a DropdownButton so the
/// task list — which can run long — scrolls in its own overlay.
class _FilterPill<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  const _FilterPill({
    required this.icon,
    required this.label,
    required this.active,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final (v, text) in options)
          PopupMenuItem<T>(
            value: v,
            child: Row(
              children: [
                Icon(
                  v == value ? Icons.check_rounded : null,
                  size: 16,
                  color: AppColors.teal,
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(text, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: active ? AppColors.tealSoft : AppColors.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? AppColors.teal : AppColors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: active ? AppColors.teal : AppColors.inkDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoFont(
                  size: 10,
                  color: active ? AppColors.teal : AppColors.ink,
                  weight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded,
                size: 14, color: active ? AppColors.teal : AppColors.inkDim),
          ],
        ),
      ),
    );
  }
}

class _SectionRule extends StatelessWidget {
  const _SectionRule();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Divider(height: 1, thickness: 1, color: AppColors.line),
      );
}

class _Quiet extends StatelessWidget {
  final String text;
  const _Quiet(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: monoFont(size: 11)),
      );
}
