import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../providers.dart';
import 'reminder_sheet.dart';
import 'widgets.dart';

/// All enabled reminders for accessible active pets, including dates beyond the
/// home page's seven-day preview. This refreshes local data, never network sync.
final allEnabledRemindersProvider = FutureProvider<List<Reminder>>((ref) async {
  final pets = await ref.watch(petsProvider.future);
  final result = <Reminder>[];
  for (final pet
      in pets.where((p) => p.deletedAt == null && p.archivedAt == null)) {
    result.addAll(await ref.watch(petRemindersProvider(pet.id).future));
  }
  return result.where((r) => r.enabled && r.deletedAt == null).toList()
    ..sort((a, b) => a.nextAt.compareTo(b.nextAt));
});

class RemindersOverviewPage extends ConsumerWidget {
  const RemindersOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pets = ref.watch(petsProvider).valueOrNull ?? const <Pet>[];
    final names = {for (final pet in pets) pet.id: pet.name};
    final state = ref.watch(allEnabledRemindersProvider);
    void refresh() {
      for (final pet in pets) {
        ref.invalidate(petRemindersProvider(pet.id));
      }
      ref.invalidate(allEnabledRemindersProvider);
    }

    return Scaffold(
      appBar: AppBar(title: Text(L.t('home.reminders.title')), actions: [
        IconButton(
            tooltip: L.t('home.reminders.refresh'),
            onPressed: refresh,
            icon: const Icon(Icons.refresh)),
      ]),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: L.error(e),
            action: TextButton(
                onPressed: refresh, child: Text(L.t('action.retry')))),
        data: (all) {
          if (all.isEmpty) {
            return EmptyState(
                icon: Icons.check_circle_outline,
                title: L.t('care.noPending'),
                hint: L.t('home.reminders.empty'));
          }
          final now = DateTime.now();
          final end = DateTime(now.year, now.month, now.day + 1);
          final groups = {
            'home.reminders.overdue':
                all.where((r) => r.nextAt.isBefore(now)).toList(),
            'home.reminders.today': all
                .where((r) => !r.nextAt.isBefore(now) && r.nextAt.isBefore(end))
                .toList(),
            'home.reminders.later':
                all.where((r) => !r.nextAt.isBefore(end)).toList(),
          };
          return ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                Text(L.t('home.reminders.hint'),
                    style: const TextStyle(color: AppColors.textSecondary)),
                for (final group in groups.entries)
                  if (group.value.isNotEmpty) ...[
                    SectionHeader('${L.t(group.key)} · ${group.value.length}'),
                    Card(
                        child: Column(children: [
                      for (final reminder in group.value)
                        ListTile(
                          key: ValueKey(reminder.id),
                          leading: Icon(reminderTypeIcon(reminder.type),
                              color: reminder.nextAt.isBefore(now)
                                  ? AppColors.warning
                                  : AppColors.primary),
                          title: Text(reminderTitle(reminder)),
                          subtitle: Text(
                              '${names[reminder.petId] ?? ''} · ${compactDateTime(reminder.nextAt)}'),
                          trailing: reminder.nextAt.isBefore(end)
                              ? const Icon(Icons.chevron_right)
                              : null,
                          onTap: reminder.nextAt.isBefore(end)
                              ? () => showReminderDueSheet(context,
                                  reminderId: reminder.id)
                              : null,
                        ),
                    ])),
                  ],
              ]);
        },
      ),
    );
  }
}
