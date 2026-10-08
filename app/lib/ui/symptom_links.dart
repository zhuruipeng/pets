import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../domain/symptom_observation.dart';
import '../providers.dart';
import 'medication_courses.dart';
import 'record_detail.dart';

class SymptomLinks extends ConsumerWidget {
  const SymptomLinks({super.key, required this.record});
  final PetRecord record;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final observation = SymptomObservation.fromRecord(record);
    if (observation == null) return const SizedBox.shrink();
    final records =
        ref.watch(petRecordsProvider(record.petId)).valueOrNull ?? [];
    final reminders =
        ref.watch(petRemindersProvider(record.petId)).valueOrNull ?? [];
    final visit = records
        .where((r) =>
            r.id == observation.medicalRecordId && r.type == RecordType.medical)
        .firstOrNull;
    final course = reminders
        .where((r) =>
            r.id == observation.courseReminderId &&
            r.rule['mode'] == 'medication')
        .firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (observation.medicalRecordId != null)
        TextButton.icon(
            icon: const Icon(Icons.local_hospital_outlined),
            label: Text(visit?.valueText ?? L.t('observation.linkUnavailable')),
            onPressed: visit == null
                ? null
                : () => showRecordDetailSheet(context, ref, record: visit)),
      if (observation.courseReminderId != null)
        TextButton.icon(
            icon: const Icon(Icons.medication_outlined),
            label: Text(course?.title ?? L.t('observation.linkUnavailable')),
            onPressed: course == null
                ? null
                : () async {
                    final pet = await ref
                        .read(petRepositoryProvider)
                        .findById(record.petId);
                    if (pet != null && context.mounted) {
                      await showMedicationCourses(context, pet: pet);
                    }
                  }),
    ]);
  }
}
