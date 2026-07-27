import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../data/providers.dart';
import '../../identity/identity.dart';
import '../../models/attachment.dart';
import '../../models/member.dart';
import '../../models/task.dart';
import '../../models/time_entry.dart';
import '../../models/work.dart';
import '../../theme.dart';
import 'work_folding.dart';

/// The beating heart: Works -> Tasks, tap a task to run YOUR timer, live glow.
class BoardScreen extends ConsumerWidget {
  const BoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worksAsync = ref.watch(worksProvider);
    final tasksAsync = ref.watch(tasksProvider);
    final entriesAsync = ref.watch(timeEntriesProvider);
    final membersAsync = ref.watch(membersProvider);
    final filesAsync = ref.watch(attachmentsProvider);
    final now = ref.watch(clockProvider).asData?.value ?? DateTime.now();
    final meId = ref.watch(identityProvider);

    final err = worksAsync.error ??
        tasksAsync.error ??
        entriesAsync.error ??
        membersAsync.error ??
        filesAsync.error;
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
          ref.invalidate(attachmentsProvider);
        },
      );
    }

    final works = worksAsync.asData?.value;
    final tasks = tasksAsync.asData?.value;
    final entries = entriesAsync.asData?.value;
    final members = membersAsync.asData?.value;
    final files = filesAsync.asData?.value;
    if (works == null ||
        tasks == null ||
        entries == null ||
        members == null ||
        files == null ||
        meId == null) {
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

    // Oldest first, so a task's files read in the order they were added.
    final filesByTask = <String, List<Attachment>>{};
    for (final a in files) {
      (filesByTask[a.taskId] ??= []).add(a);
    }
    for (final list in filesByTask.values) {
      list.sort((a, b) => a.created.compareTo(b.created));
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
                  filesByTask: filesByTask,
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
  final Map<String, List<Attachment>> filesByTask;
  final Map<String, Member> membersById;
  final String meId;
  final DateTime now;

  const _WorkSection({
    required this.work,
    required this.tasks,
    required this.completeness,
    required this.entriesByTask,
    required this.filesByTask,
    required this.membersById,
    required this.meId,
    required this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = (completeness * 100).round();
    final folding = ref.watch(workFoldingProvider);

    // A Work with nothing left to do is precisely the clutter folding is for,
    // so it arrives closed. Anything unfinished arrives open — the board's job
    // is to keep unfinished work in your face. An explicit tap always wins.
    final collapsed = folding[work.id] ?? (tasks.isNotEmpty && completeness >= 1.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () =>
                ref.read(workFoldingProvider.notifier).setCollapsed(work.id, !collapsed),
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.expand_more_rounded,
                      size: 22, color: AppColors.inkDim),
                ),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(work.title, style: displayFont(size: 20, weight: FontWeight.w700)),
                ),
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
          if (collapsed)
            _FoldedSummary(
              tasks: tasks,
              entriesByTask: entriesByTask,
              filesByTask: filesByTask,
              membersById: membersById,
              now: now,
            )
          else ...[
            const SizedBox(height: 12),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child:
                    Text('No tasks yet', style: TextStyle(color: AppColors.inkDim, fontSize: 13)),
              ),
            for (final t in tasks)
              _TaskTile(
                task: t,
                entries: entriesByTask[t.id] ?? const [],
                files: filesByTask[t.id] ?? const [],
                membersById: membersById,
                meId: meId,
                now: now,
              ),
          ],
        ],
      ),
    );
  }
}

/// The one line a folded Work leaves behind. Folding is meant to remove
/// clutter, not information — what's left, how much time is banked, who touched
/// it and how many files it carries all survive the fold.
class _FoldedSummary extends StatelessWidget {
  final List<Task> tasks;
  final Map<String, List<TimeEntry>> entriesByTask;
  final Map<String, List<Attachment>> filesByTask;
  final Map<String, Member> membersById;
  final DateTime now;

  const _FoldedSummary({
    required this.tasks,
    required this.entriesByTask,
    required this.filesByTask,
    required this.membersById,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    var total = Duration.zero;
    var fileCount = 0;
    final touched = <String>{}; // insertion-ordered: first to log time comes first
    var live = false;

    for (final t in tasks) {
      for (final e in entriesByTask[t.id] ?? const <TimeEntry>[]) {
        total += e.durationAsOf(now);
        touched.add(e.memberId);
        if (e.isLive) live = true;
      }
      fileCount += (filesByTask[t.id] ?? const <Attachment>[]).length;
    }

    final remaining = tasks.where((t) => !t.isDone).length;
    final label = tasks.isEmpty
        ? 'empty'
        : remaining == 0
            ? 'all done'
            : '$remaining left';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text(label, style: monoFont(size: 10, color: AppColors.inkDim)),
          if (total > Duration.zero) ...[
            _dotSeparator,
            Text(fmtTotal(total),
                style: monoFont(size: 10, color: live ? AppColors.teal : AppColors.inkDim)),
          ],
          if (fileCount > 0) ...[
            _dotSeparator,
            const Icon(Icons.attach_file_rounded, size: 11, color: AppColors.inkDim),
            const SizedBox(width: 2),
            Text('$fileCount', style: monoFont(size: 10, color: AppColors.inkDim)),
          ],
          const Spacer(),
          for (final id in touched)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _Dot(
                color: hexToColor(membersById[id]?.color ?? '#00A896'),
                ring: false,
                faded: true,
              ),
            ),
        ],
      ),
    );
  }

  static const _dotSeparator = Padding(
    padding: EdgeInsets.symmetric(horizontal: 6),
    child: Text('·', style: TextStyle(color: AppColors.inkDim, fontSize: 11)),
  );
}

class _TaskTile extends ConsumerWidget {
  final Task task;
  final List<TimeEntry> entries;
  final List<Attachment> files;
  final Map<String, Member> membersById;
  final String meId;
  final DateTime now;

  const _TaskTile({
    required this.task,
    required this.entries,
    required this.files,
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
            _TaskMenu(task: task, color: fg, meId: meId),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          hot ? _HotGlow(child: tile) : tile,
          if (files.isNotEmpty)
            _AttachmentBlock(files: files, membersById: membersById, meId: meId),
        ],
      ),
    );
  }
}

/// A task's files, grouped one member per row.
///
/// Whose file it is matters as much as what it is — a screenshot from the
/// person who hit the bug reads differently from one from the person fixing
/// it. So authorship is the axis the block is built on, matching the coloured
/// dots that already say who spent time here.
class _AttachmentBlock extends StatelessWidget {
  final List<Attachment> files;
  final Map<String, Member> membersById;
  final String meId;

  const _AttachmentBlock({
    required this.files,
    required this.membersById,
    required this.meId,
  });

  @override
  Widget build(BuildContext context) {
    // Insertion-ordered: whoever attached something first gets the top row.
    final byMember = <String, List<Attachment>>{};
    for (final a in files) {
      (byMember[a.memberId] ??= []).add(a);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 14, top: 8, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in byMember.entries)
            _MemberFileRow(
              member: membersById[entry.key],
              files: entry.value,
              isMe: entry.key == meId,
            ),
        ],
      ),
    );
  }
}

class _MemberFileRow extends StatelessWidget {
  final Member? member;
  final List<Attachment> files;
  final bool isMe;

  const _MemberFileRow({required this.member, required this.files, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final color = hexToColor(member?.color ?? '#00A896');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Dot(color: color, ring: false),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      isMe ? 'You' : (member?.name ?? 'Someone'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.inkDim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Wrap, not a horizontal scroller: on a phone a fourth file pushed
          // off the edge is a file nobody knows exists.
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final a in files) _AttachmentTile(attachment: a, tint: color)],
            ),
          ),
        ],
      ),
    );
  }
}

/// One file: an image previews itself, anything else states its name.
class _AttachmentTile extends StatelessWidget {
  final Attachment attachment;
  final Color tint;

  const _AttachmentTile({required this.attachment, required this.tint});

  static const _size = 58.0;

  @override
  Widget build(BuildContext context) {
    final a = attachment;

    return Tooltip(
      message: a.prettySize.isEmpty ? a.name : '${a.name} · ${a.prettySize}',
      waitDuration: const Duration(milliseconds: 600),
      child: Opacity(
        opacity: a.uploading ? 0.55 : 1,
        child: InkWell(
          onTap: () => showAttachmentDialog(context, a),
          borderRadius: BorderRadius.circular(10),
          child: a.isImage ? _imagePreview(a) : _fileChip(a),
        ),
      ),
    );
  }

  Widget _imagePreview(Attachment a) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            attachmentImage(a, preferThumb: true),
            if (a.uploading)
              const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fileChip(Attachment a) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 168),
      height: _size,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (a.uploading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.teal),
            )
          else
            Icon(fileGlyph(a), size: 18, color: tint),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (a.prettySize.isNotEmpty)
                  Text(a.prettySize, style: monoFont(size: 9, color: AppColors.inkDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders an attachment's picture from whichever source exists — the bytes
/// still in memory during an upload, or the stored file once it has landed.
Widget attachmentImage(Attachment a, {bool preferThumb = false}) {
  final bytes = a.localBytes;
  if (bytes != null) return Image.memory(bytes, fit: BoxFit.cover);

  final url = preferThumb && a.thumbUrl.isNotEmpty ? a.thumbUrl : a.url;
  if (url.isEmpty) return const ColoredBox(color: AppColors.line);

  return Image.network(
    url,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => const Center(
      child: Icon(Icons.broken_image_outlined, size: 18, color: AppColors.inkDim),
    ),
  );
}

IconData fileGlyph(Attachment a) {
  switch (a.extension) {
    case 'pdf':
      return Icons.picture_as_pdf_rounded;
    case 'doc':
    case 'docx':
    case 'txt':
    case 'md':
    case 'rtf':
      return Icons.description_rounded;
    case 'xls':
    case 'xlsx':
    case 'csv':
      return Icons.table_chart_rounded;
    case 'zip':
    case 'rar':
    case '7z':
    case 'tar':
    case 'gz':
      return Icons.folder_zip_rounded;
    case 'mp3':
    case 'wav':
    case 'm4a':
    case 'ogg':
      return Icons.audiotrack_rounded;
    case 'mp4':
    case 'mov':
    case 'webm':
    case 'mkv':
      return Icons.movie_rounded;
    default:
      return Icons.insert_drive_file_rounded;
  }
}

/// The full view of one file: the picture at size (or a plain statement of what
/// it is), plus the two things you can do with it.
///
/// Every attachment opens the same dialog whether or not it's an image, so
/// "delete this" is never hidden behind a gesture someone has to guess at.
Future<void> showAttachmentDialog(BuildContext context, Attachment a) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final members = ref.watch(membersProvider).asData?.value ?? const <Member>[];
        Member? owner;
        for (final m in members) {
          if (m.id == a.memberId) owner = m;
        }

        return Dialog(
          backgroundColor: AppColors.card,
          insetPadding: const EdgeInsets.all(20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 140, maxHeight: 460),
                    decoration: const BoxDecoration(
                      color: AppColors.bg,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                      child: a.isImage
                          ? InteractiveViewer(
                              maxScale: 5,
                              child: Center(
                                child: a.localBytes != null
                                    ? Image.memory(a.localBytes!, fit: BoxFit.contain)
                                    : Image.network(
                                        a.url,
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, _, _) => const Padding(
                                          padding: EdgeInsets.all(32),
                                          child: Icon(Icons.broken_image_outlined,
                                              size: 36, color: AppColors.inkDim),
                                        ),
                                      ),
                              ),
                            )
                          : Center(
                              child: Icon(fileGlyph(a), size: 56, color: AppColors.inkDim),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.name,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _Dot(color: hexToColor(owner?.color ?? '#00A896'), ring: false),
                          const SizedBox(width: 6),
                          Text(
                            [
                              owner?.name ?? 'Someone',
                              if (a.prettySize.isNotEmpty) a.prettySize,
                              if (a.uploading) 'uploading…',
                            ].join(' · '),
                            style: monoFont(size: 10, color: AppColors.inkDim),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: a.uploading
                            ? null
                            : () async {
                                final ok = await confirmDialog(
                                  ctx,
                                  title: 'Delete file?',
                                  message:
                                      'Permanently removes "${a.name}" from this task. This cannot be undone.',
                                );
                                if (!ok) return;
                                await ref.read(repoProvider).deleteAttachment(a.id);
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFFE05555)),
                      ),
                      const Spacer(),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                      const SizedBox(width: 4),
                      FilledButton.icon(
                        onPressed: a.uploading
                            ? null
                            : () => launchUrl(Uri.parse(a.url),
                                mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('Open'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Pick one or more files and hang them off a task, credited to whoever is
/// signed in on this device.
Future<void> pickAndAttach(
  BuildContext context,
  WidgetRef ref, {
  required String taskId,
  required String memberId,
}) async {
  // withData forces bytes on every platform — web has no path to hand back.
  final picked = await FilePicker.pickFiles(withData: true, allowMultiple: true);
  if (picked == null) return;

  final repo = ref.read(repoProvider);
  final tooBig = <String>[];
  final uploads = <Future<void>>[];

  for (final f in picked.files) {
    final bytes = f.bytes;
    if (bytes == null) continue;
    if (bytes.length > kMaxAttachmentBytes) {
      tooBig.add(f.name);
      continue;
    }
    uploads.add(repo.addAttachment(
      taskId: taskId,
      memberId: memberId,
      filename: f.name,
      bytes: bytes,
    ));
  }

  // Say so before the uploads finish — the rejection is already decided, and
  // the accepted files are on screen anyway.
  if (tooBig.isNotEmpty && context.mounted) {
    final cap = kMaxAttachmentBytes ~/ (1024 * 1024);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.ink,
        behavior: SnackBarBehavior.floating,
        content: Text(
          tooBig.length == 1
              ? '"${tooBig.single}" is over the ${cap}MB limit — not attached.'
              : '${tooBig.length} files are over the ${cap}MB limit — not attached.',
        ),
      ),
    );
  }

  await Future.wait(uploads);
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
  final String meId;
  const _TaskMenu({required this.task, required this.color, required this.meId});

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
          case 'attach':
            await pickAndAttach(context, ref, taskId: task.id, memberId: meId);
          case 'archive':
            await repo.setTaskArchived(task.id, true);
          case 'delete':
            final ok = await confirmDialog(
              context,
              title: 'Delete task?',
              message:
                  'Permanently deletes "${task.title}", its tracked time and its files. This cannot be undone.',
            );
            if (ok) await repo.deleteTask(task.id);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'done', child: Text(task.isDone ? 'Mark not done' : 'Mark done')),
        PopupMenuItem(
            value: 'critical', child: Text(task.critical ? 'Unmark critical' : 'Mark critical')),
        const PopupMenuItem(value: 'note', child: Text('Edit note')),
        const PopupMenuItem(value: 'attach', child: Text('Attach file…')),
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
                'Permanently deletes "${work.title}" and everything inside it — all its tasks, their tracked time and their files. This cannot be undone.',
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
