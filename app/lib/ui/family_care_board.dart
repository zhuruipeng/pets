import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/reminder_text.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/repositories/member_repository.dart';
import '../domain/family_care.dart';
import '../providers.dart';
import 'medication_courses.dart';
import 'reminder_sheet.dart';
import 'widgets.dart';

class FamilyCareBoard extends ConsumerStatefulWidget {
  const FamilyCareBoard(
      {super.key, required this.pet, this.showPending = true});
  final bool showPending;
  final Pet pet;

  @override
  ConsumerState<FamilyCareBoard> createState() => _FamilyCareBoardState();
}

class _FamilyCareBoardState extends ConsumerState<FamilyCareBoard> {
  Timer? _clock;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Local clock only: change the day without adding background network sync.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(now.year, now.month, now.day + 1);
    final events = ref.watch(
        careEventsProvider((widget.pet.id, today.millisecondsSinceEpoch)));
    final reminders =
        ref.watch(petRemindersProvider(widget.pet.id)).valueOrNull ?? [];
    final pending =
        reminders.where((r) => r.enabled && r.nextAt.isBefore(end)).toList();
    final role = ref.watch(petRoleProvider(widget.pet.id)).valueOrNull;
    final user = ref.watch(currentUserProvider).valueOrNull;
    final sync = ref.watch(syncControllerProvider);

    return Container(
      margin: const EdgeInsets.only(top: AppSpace.gapL),
      padding: const EdgeInsets.all(AppSpace.gapM),
      decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.cardBorder,
          border: Border.all(color: AppColors.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.diversity_1_outlined,
              size: 20, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  L.t(widget.showPending ? 'care.title' : 'care.historyTitle'),
                  style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(
              tooltip: L.t('care.refresh'),
              onPressed: sync.syncing ? null : _refresh,
              icon: sync.syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync_rounded, size: 20)),
        ]),
        Text(L.t('care.syncHint'),
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (sync.lastSyncAt != null)
          Text(
              L.tp(
                  'care.lastSync', {'time': compactDateTime(sync.lastSyncAt!)}),
              style:
                  const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        const SizedBox(height: 12),
        if (widget.showPending) ...[
          Text(L.t('care.pending'),
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          if (pending.isEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(L.t('care.noPending'))),
          for (final reminder in _expanded ? pending : pending.take(4))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.radio_button_unchecked,
                  color: AppColors.primary, size: 20),
              title: Text(reminderTitle(reminder)),
              subtitle: Text(compactDateTime(reminder.nextAt)),
              trailing: role?.canWrite == true
                  ? TextButton(
                      onPressed: () => showReminderDueSheet(context,
                          reminderId: reminder.id),
                      child: Text(L.t('today.done')),
                    )
                  : null,
            ),
          if (pending.length > 4 && !_expanded)
            TextButton(
                onPressed: () => setState(() => _expanded = true),
                child: Text(L.tp('care.showAll', {'count': pending.length}))),
          const Divider(),
        ],
        Text(L.t('care.completed'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        events.when(
          loading: () => const Padding(
              padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
          error: (e, _) => Text(L.error(e)),
          data: (items) => Column(children: [
            if (items.isEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(L.t('care.empty'))),
            for (final event in _expanded ? items : items.take(3))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.check_circle_outline,
                    color: AppColors.primary, size: 20),
                title: Text(event.type == null
                    ? (event.title == null
                        ? L.t('care.completed')
                        : reminderTitleFrom(event.title!, ''))
                    : recordTypeLabel(event.type!)),
                subtitle: Text([
                  _actor(event, user?.id),
                  if ((event.detail ?? '').isNotEmpty) event.detail!
                ].join(' · ')),
                trailing: Text(
                    '${event.at.hour.toString().padLeft(2, '0')}:${event.at.minute.toString().padLeft(2, '0')}'),
              ),
            if (items.length > 3)
              TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded
                      ? L.t('care.collapse')
                      : L.tp('care.showAll', {'count': '${items.length}'}))),
          ]),
        ),
        if (widget.showPending)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: () =>
                      showMedicationCourses(context, pet: widget.pet),
                  icon: const Icon(Icons.medication_outlined),
                  label: Text(L.t('med.title')))),
      ]),
    );
  }

  String _actor(CareEvent event, String? currentId) {
    if (event.actorId != null && event.actorId == currentId) {
      return L.t('care.me');
    }
    if ((event.actorName ?? '').trim().isNotEmpty) return event.actorName!;
    return L.t(event.actorId == null ? 'care.unknown' : 'care.other');
  }

  Future<void> _refresh() async {
    try {
      await ref.read(syncControllerProvider.notifier).runSync();
      ref.invalidate(petRecordsProvider(widget.pet.id));
      ref.invalidate(petRemindersProvider(widget.pet.id));
      ref.invalidate(careLogsProvider(widget.pet.id));
      final status = ref.read(syncControllerProvider);
      if (mounted && status.message != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(status.message!)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L.error(e))));
      }
    }
  }
}
