import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../identity/identity.dart';
import '../../models/member.dart';
import '../../models/task.dart';
import '../../models/time_entry.dart';
import '../../models/work.dart';
import '../../theme.dart';

/// The beating heart: Works -> Tasks, tap a task to run YOUR timer, live glow.
class BoardScreen extends ConsumerWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worksAsync = ref.watch(worksProvider);
    final tasksAsync = ref.watch(tasksProvider);
    final entriesAsync = ref.watch(timeEntriesProvider);
    final membersAsync = ref.watch(membersProvider);
    final now = ref.watch(clockProvider).asData?.value ?? DateTime.now();
    final meId = ref.watch(identityProvider);

    final err = worksAsync.error ?? tasksAsync.error ?? entriesAsync.error ?? membersAsync.error;
    if (err != null) {
      return _CenterMessage(
        icon: Icons.cloud_off_rounded,
        title: "Can't reach the backend",
        detail: '$err',
        onRetry: () {
          ref.invalidate(worksProvider);
          ref.invalidate(tasksProvider);
          ref.invalidate(timeEntriesProvider);
          ref.invalidate(membersProvider);
        },
      );
    }

    final works = worksAsync.asData?.value;
    final tasks = tasksAsync.asData?.value;
    final entries = entriesAsync.asData?.value;
    final members = membersAsync.asData?.value;
    if (works == null || tasks == null || entries == null || members == null || meId == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.teal));
    }

    final membersById = {for (final m in members) m.id: m};

    // tasks grouped by work (exclude archived)
    final tasksByWork = <String, List<Task>>{};
    for (final t in tasks.where((t) => !t.isArchived)) {
      (tasksByWork[t.workId] ??= []).add(t);
    }
    for (final list in tasksByWork.values) {
      list.sort((a, b) => a.position.compareTo(b.position));
    }

    double completeness(Work w) {
      final list = tasksByWork[w.id] ?? const [];
      if (list.isEmpty) return 0;
      final done = list.where((t) => t.isDone).length;
      return done / list.length;
    }

    // more complete sinks lower -> ascending completeness, tie-break by position
    final activeWorks = works.where((w) => !w.archived).toList()
      ..sort((a, b) {
        final c = completeness(a).compareTo(completeness(b));
        return c != 0 ? c : a.position.compareTo(b.position);
      });

    final entriesByTask = <String, List<TimeEntry>>{};
    for (final e in entries) {
      (entriesByTask[e.taskId] ??= []).add(e);
    }

    return Stack(
      children: [
        if (activeWorks.isEmpty)
          const _CenterMessage(
            icon: Icons.grid_view_rounded,
            title: 'No works yet',
            detail: 'Create your first Work to start the board.',
          )
        else
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            children: [
              for (final w in activeWorks)
                _WorkSection(
                  work: w,
                  tasks: tasksByWork[w.id] ?? const [],
                  completeness: completeness(w),
                  entriesByTask: entriesByTask,
                  membersById: membersById,
                  meId: meId,
                  now: now,
                ),
            ],
          ),
        Positioned(
          right: 20,
          bottom: 24,
          child: FloatingActionButton.extended(
            backgroundColor: AppColors.ink,
            foregroundColor: Colors.white,
            onPressed: () async {
              final title = await promptText(context, title: 'New Work');
              if (title != null && title.trim().isNotEmpty) {
                await ref.read(repoProvider).createWork(title.trim());
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New Work'),
          ),
        ),
      ],
    );
  }
}

class _WorkSection extends ConsumerWidget {
  final Work work;
  final List<Task> tasks;
  final double completeness;
  final Map<String, List<TimeEntry>> entriesByTask;
  final Map<String, Member> membersById;
  final String meId;
  final DateTime now;

  const _WorkSection({
    required this.work,
    required this.tasks,
    required this.completeness,
    required this.entriesByTask,
    required this.membersById,
    required this.meId,
    required this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = (completeness * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(work.title, style: displayFont(size: 20, weight: FontWeight.w700)),
              const SizedBox(width: 10),
              Text('$pct%', style: monoFont(size: 11, color: AppColors.inkDim)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                color: AppColors.inkDim,
                tooltip: 'Add task',
                onPressed: () async {
                  final title = await promptText(context, title: 'New task in "${work.title}"');
                  if (title != null && title.trim().isNotEmpty) {
                    await ref.read(repoProvider).createTask(workId: work.id, title: title.trim());
                  }
                },
              ),
              _WorkMenu(work: work),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: completeness,
              minHeight: 4,
              backgroundColor: AppColors.line,
              color: AppColors.teal,
            ),
          ),
          const SizedBox(height: 12),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('No tasks yet', style: TextStyle(color: AppColors.inkDim, fontSize: 13)),
            ),
          for (final t in tasks)
            _TaskTile(
              task: t,
              entries: entriesByTask[t.id] ?? const [],
              membersById: membersById,
              meId: meId,
              now: now,
            ),
        ],
      ),
    );
  }
}

class _TaskTile extends ConsumerWidget {
  final Task task;
  final List<TimeEntry> entries;
  final Map<String, Member> membersById;
  final String meId;
  final DateTime now;

  const _TaskTile({
    required this.task,
    required this.entries,
    required this.membersById,
    required this.meId,
    required this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = entries.where((e) => e.isLive).toList();
    final hot = live.isNotEmpty;
    final hasHistory = entries.isNotEmpty;

    TimeEntry? myLive;
    for (final e in live) {
      if (e.memberId == meId) {
        myLive = e;
        break;
      }
    }
    final myElapsed = myLive?.durationAsOf(now);

    // Time banked on this task by the whole team. Live entries keep counting
    // into it, so the total never jumps when someone stops their timer.
    var total = Duration.zero;
    for (final e in entries) {
      total += e.durationAsOf(now);
    }

    // Everyone who has EVER logged time here, in first-touch order. These dots
    // persist after a timer stops, so "I worked on this" outlives the session.
    final liveMemberIds = {for (final e in live) e.memberId};
    final contributors = <String>[];
    for (final e in entries) {
      if (!contributors.contains(e.memberId)) contributors.add(e.memberId);
    }

    late Color bg;
    late Color fg;
    if (task.isDone) {
      // Recedes into the page. Teal is reserved for effort, so a done task
      // reads as finished rather than as a faint version of "worked on".
      bg = AppColors.bg;
      fg = AppColors.inkDim;
    } else if (hot) {
      bg = AppColors.teal;
      fg = Colors.white;
    } else if (hasHistory) {
      bg = AppColors.tealSoft;
      fg = AppColors.ink;
    } else {
      bg = AppColors.card;
      fg = AppColors.ink;
    }

    final tile = InkWell(
      onTap: task.isDone
          ? null
          : () => ref.read(repoProvider).toggleTimer(taskId: task.id, memberId: meId),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: hot ? AppColors.teal : AppColors.line, width: 1.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (task.critical)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.priority_high_rounded,
                              size: 16, color: hot ? Colors.white : AppColors.amber),
                        ),
                      Flexible(
                        child: Text(
                          task.title,
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            decoration: task.isDone ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (task.note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        task.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            if (contributors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final id in contributors)
                      Padding(
                        padding: const EdgeInsets.only(left: 3),
                        child: _Dot(
                          color: hexToColor(membersById[id]?.color ?? '#00A896'),
                          ring: liveMemberIds.contains(id),
                          faded: !liveMemberIds.contains(id),
                        ),
                      ),
                  ],
                ),
              ),
            if (myElapsed != null || total > Duration.zero)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // My live timer, ticking.
                    if (myElapsed != null)
                      Text(fmtDuration(myElapsed), style: monoFont(size: 12, color: fg)),
                    // Everything banked on this task — survives stopping.
                    if (total > Duration.zero)
                      Text(
                        fmtTotal(total),
                        style: monoFont(
                          size: myElapsed != null ? 10 : 12,
                          color: fg.withValues(alpha: myElapsed != null ? 0.6 : 0.85),
                        ),
                      ),
                  ],
                ),
              )
            else if (!task.isDone)
              Icon(Icons.play_arrow_rounded, color: fg.withValues(alpha: 0.45), size: 20),
            _TaskMenu(task: task, color: fg),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: hot ? _HotGlow(child: tile) : tile,
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final bool ring;

  /// Dimmed = this member has logged time here but isn't running right now.
  final bool faded;

  const _Dot({required this.color, required this.ring, this.faded = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: faded ? color.withValues(alpha: 0.45) : color,
        shape: BoxShape.circle,
        border: ring ? Border.all(color: Colors.white, width: 1.5) : null,
      ),
    );
  }
}

class _TaskMenu extends ConsumerWidget {
  final Task task;
  final Color color;
  const _TaskMenu({required this.task, required this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repoProvider);
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: color.withValues(alpha: 0.7)),
      onSelected: (v) async {
        switch (v) {
          case 'done':
            await repo.setTaskDone(task.id, !task.isDone);
          case 'critical':
            await repo.setTaskCritical(task.id, !task.critical);
          case 'note':
            final n = await promptText(context, title: 'Note', initial: task.note);
            if (n != null) await repo.updateTaskNote(task.id, n.trim());
          case 'archive':
            await repo.setTaskArchived(task.id, true);
          case 'delete':
            final ok = await confirmDialog(
              context,
              title: 'Delete task?',
              message:
                  'Permanently deletes "${task.title}" and its tracked time. This cannot be undone.',
            );
            if (ok) await repo.deleteTask(task.id);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'done', child: Text(task.isDone ? 'Mark not done' : 'Mark done')),
        PopupMenuItem(
            value: 'critical', child: Text(task.critical ? 'Unmark critical' : 'Mark critical')),
        const PopupMenuItem(value: 'note', child: Text('Edit note')),
        const PopupMenuItem(value: 'archive', child: Text('Archive')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete', style: TextStyle(color: Color(0xFFE05555))),
        ),
      ],
    );
  }
}

class _WorkMenu extends ConsumerWidget {
  final Work work;
  const _WorkMenu({required this.work});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz, size: 20, color: AppColors.inkDim),
      onSelected: (v) async {
        if (v == 'delete') {
          final ok = await confirmDialog(
            context,
            title: 'Delete Work?',
            message:
                'Permanently deletes "${work.title}" and everything inside it — all its tasks and their tracked time. This cannot be undone.',
          );
          if (ok) await ref.read(repoProvider).deleteWork(work.id);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'delete',
          child: Text('Delete Work', style: TextStyle(color: Color(0xFFE05555))),
        ),
      ],
    );
  }
}

/// A soft pulsing glow behind a "hot" (live) task.
class _HotGlow extends StatefulWidget {
  final Widget child;
  const _HotGlow({required this.child});

  @override
  State<_HotGlow> createState() => _HotGlowState();
}

class _HotGlowState extends State<_HotGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.teal.withValues(alpha: 0.15 + 0.25 * _c.value),
                blurRadius: 8 + 14 * _c.value,
                spreadRadius: _c.value * 2,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _CenterMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;
  const _CenterMessage({required this.icon, required this.title, this.detail, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.inkDim),
            const SizedBox(height: 12),
            Text(title, style: displayFont(size: 20)),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(detail!,
                  textAlign: TextAlign.center, style: monoFont(size: 10, color: AppColors.inkDim)),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small single-field prompt dialog. Returns null on cancel.
Future<String?> promptText(BuildContext context, {required String title, String? initial}) {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(title, style: displayFont(size: 18)),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Type here...'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
}

/// Destructive-action confirmation. Returns true only if the user confirms.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(title, style: displayFont(size: 18)),
      content: Text(message, style: const TextStyle(fontSize: 14, color: AppColors.inkDim, height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE05555)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}
