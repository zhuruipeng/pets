import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../data/models.dart';
import '../data/repositories/member_repository.dart';
import '../domain/symptom_observation.dart';
import '../providers.dart';
import 'record_detail.dart';
import 'sheets.dart';
import 'widgets.dart';

class SymptomObservationsPage extends ConsumerWidget {
  const SymptomObservationsPage({super.key, required this.pet});
  final Pet pet;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canWrite =
        ref.watch(petRoleProvider(pet.id)).valueOrNull?.canWrite == true;
    return Scaffold(
        appBar:
            AppBar(title: Text('${pet.name} · ${L.t('observation.title')}')),
        floatingActionButton: canWrite
            ? FloatingActionButton.extended(
                onPressed: () => showAddRecordSheet(context, ref,
                    petId: pet.id, initialType: RecordType.symptom),
                icon: const Icon(Icons.add),
                label: Text(L.t('observation.add')))
            : null,
        body: ref.watch(petRecordsProvider(pet.id)).when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(L.error(e))),
            data: (all) {
              final observations = all
                  .where((r) =>
                      r.type == RecordType.symptom && r.deletedAt == null)
                  .toList()
                ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
              final now = DateTime.now();
              final recent = observations
                  .where((r) =>
                      !r.recordedAt.isBefore(
                          DateTime(now.year, now.month, now.day - 6)) &&
                      !r.recordedAt.isAfter(now))
                  .toList();
              return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  children: [
                    Text(L.t('observation.help')),
                    const SizedBox(height: 12),
                    Text(L.tp('observation.week', {'count': recent.length})),
                    for (final code in SymptomObservation.symptoms)
                      if (recent.any((r) => r.payload['symptom'] == code))
                        Text(
                            '${L.t('observation.symptom.$code')}: ${recent.where((r) => r.payload['symptom'] == code).length}'),
                    const Divider(),
                    if (observations.isEmpty) Text(L.t('observation.empty')),
                    for (final record in observations)
                      Card(
                          child: ListTile(
                              leading:
                                  const Icon(Icons.health_and_safety_outlined),
                              title: Text(SymptomObservation.fromRecord(record)
                                      ?.title ??
                                  record.valueText ??
                                  L.t('observation.title')),
                              subtitle: Text(
                                  '${compactDateTime(record.recordedAt)}\n${recordPayloadSummary(record)}${record.note == null ? '' : '\n${record.note}'}'),
                              isThreeLine: true,
                              onTap: () => showRecordDetailSheet(context, ref,
                                  record: record))),
                  ]);
            }));
  }
}
