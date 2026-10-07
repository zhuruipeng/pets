import '../core/l10n.dart';
import '../core/region.dart';
import '../core/units.dart';
import '../data/models.dart';
import 'labels.dart';
import 'medication_course.dart';
import 'pet_report.dart';

/// A snapshot for a sitter, deliberately containing care instructions only.
PetReport buildCareHandoff(
    {required Pet pet,
    required List<PetRecord> records,
    required List<Reminder> reminders,
    required DateTime from,
    required DateTime to,
    required DateTime now,
    String instructions = '',
    String contact = ''}) {
  if (MedicationCourse.day(to).isBefore(MedicationCourse.day(from))) {
    throw ArgumentError('handoff.invalidDates');
  }
  final facts = <ReportFact>[
    ReportFact(L.t('handoff.period'),
        '${MedicationCourse.date(from)} — ${MedicationCourse.date(to)}'),
    if ((pet.allergy ?? '').trim().isNotEmpty)
      ReportFact(L.t('profile.field.allergy'), pet.allergy!),
    if (instructions.trim().isNotEmpty)
      ReportFact(L.t('handoff.instructions'), instructions.trim()),
    if (contact.trim().isNotEmpty)
      ReportFact(L.t('handoff.contact'), contact.trim()),
  ];
  final feeds = records
      .where((r) =>
          r.petId == pet.id &&
          r.deletedAt == null &&
          r.type == RecordType.feeding &&
          !r.recordedAt.isAfter(now))
      .toList()
    ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  if (feeds.isNotEmpty) {
    final latest = feeds.first;
    facts.add(ReportFact(
        L.t('handoff.latestFood'),
        [
          recordValueLine(latest, Units.defaultWeightUnit(AppRegion.current)),
          recordPayloadSummary(latest),
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · ')));
  }
  final tasks = <ReportRecord>[];
  final end = DateTime(to.year, to.month, to.day + 1);
  final sorted = [...reminders]..sort((a, b) => a.nextAt.compareTo(b.nextAt));
  for (final reminder in sorted) {
    if (reminder.petId != pet.id ||
        !reminder.enabled ||
        reminder.deletedAt != null) {
      continue;
    }
    final course = MedicationCourse.fromReminder(reminder);
    if (reminder.rule['mode'] == 'medication' && course == null) continue;
    if (course != null) {
      final slot = course.nextAt(MedicationCourse.day(from));
      if (slot == null || !slot.isBefore(end)) continue;
      final times = [...course.times]..sort();
      tasks.add(ReportRecord(
          typeLabel: L.t('med.title'),
          when: slot,
          value: course.name,
          detail: '${course.dose} · ${medRouteLabel(course.route)}\n'
              '${times.map((m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}').join(' / ')}\n'
              '${MedicationCourse.date(course.start)} — ${MedicationCourse.date(course.end)}'));
    } else if (reminder.nextAt.isBefore(end)) {
      tasks.add(ReportRecord(
          typeLabel: L.t('handoff.reminder'),
          when: reminder.nextAt,
          value: L.t(reminder.title)));
    }
  }
  return PetReport(
      petName: pet.name,
      subtitle: L.t('handoff.title'),
      facts: facts,
      careRows: const [],
      weightPoints: const [],
      records: tasks,
      generatedAt: now,
      weightUnit: Units.defaultWeightUnit(AppRegion.current),
      recordsSectionKey: 'handoff.tasks',
      footerKey: 'handoff.footer');
}
