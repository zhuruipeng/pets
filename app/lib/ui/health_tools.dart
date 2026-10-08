import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../domain/medication_course.dart';
import '../providers.dart';
import 'care_handoff.dart';
import 'medication_courses.dart';
import 'symptom_observations.dart';
import 'widgets.dart';

class HealthToolsCard extends ConsumerWidget {
  const HealthToolsCard({super.key, required this.pet});
  final Pet pet;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(petRemindersProvider(pet.id));
    final records = ref.watch(petRecordsProvider(pet.id));
    final courses = reminders.valueOrNull
        ?.where((r) =>
            r.enabled &&
            r.deletedAt == null &&
            MedicationCourse.fromReminder(r) != null)
        .length;
    final since = DateTime.now().subtract(const Duration(days: 7));
    final symptoms = records.valueOrNull
        ?.where((r) =>
            r.deletedAt == null &&
            r.type == RecordType.symptom &&
            !r.recordedAt.isBefore(since))
        .length;
    Widget row(IconData icon, String title, String hint, Widget page) =>
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Icon(icon, color: AppColors.primary),
          title: Text(L.t(title),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(hint),
          trailing:
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => page)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(L.t('health.tools')),
      Card(
          margin: EdgeInsets.zero,
          child: Column(children: [
            row(
                Icons.medication_outlined,
                'med.title',
                courses == null
                    ? L.t('health.coursesHint')
                    : L.tp('health.coursesCount', {'count': courses}),
                MedicationCoursesPage(pet: pet)),
            const Divider(height: 1, indent: 16, endIndent: 16),
            row(
                Icons.health_and_safety_outlined,
                'observation.title',
                symptoms == null
                    ? L.t('observation.help')
                    : L.tp('health.symptomsCount', {'count': symptoms}),
                SymptomObservationsPage(pet: pet)),
            const Divider(height: 1, indent: 16, endIndent: 16),
            row(Icons.assignment_outlined, 'handoff.title',
                L.t('health.handoffHint'), CareHandoffPage(pet: pet)),
          ])),
    ]);
  }
}
