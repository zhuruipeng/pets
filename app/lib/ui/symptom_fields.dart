import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../data/models.dart';
import '../domain/symptom_observation.dart';
import '../domain/medication_course.dart';
import '../providers.dart';

class SymptomFields extends ConsumerStatefulWidget {
  const SymptomFields(
      {super.key,
      required this.petId,
      required this.onChanged,
      this.initial = const SymptomObservation()});
  final String petId;
  final SymptomObservation initial;
  final ValueChanged<SymptomObservation> onChanged;
  @override
  ConsumerState<SymptomFields> createState() => _SymptomFieldsState();
}

class _SymptomFieldsState extends ConsumerState<SymptomFields> {
  String _symptom = 'vomiting',
      _appetite = 'unobserved',
      _energy = 'unobserved',
      _stool = 'unobserved';
  int? _count;
  String? _medical, _course;
  late final TextEditingController _countController;
  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    _symptom = value.symptom;
    _count = value.count;
    _appetite = value.appetite;
    _energy = value.energy;
    _stool = value.stool;
    _medical = value.medicalRecordId;
    _course = value.courseReminderId;
    _countController = TextEditingController(text: _count?.toString() ?? '');
  }

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  void _changed() => widget.onChanged(SymptomObservation(
      symptom: _symptom,
      count: _count,
      appetite: _appetite,
      energy: _energy,
      stool: _stool,
      medicalRecordId: _medical,
      courseReminderId: _course));
  Widget _choice(String label, String value, List<String> values,
      ValueChanged<String> update,
      {bool symptom = false}) {
    void select(String next) {
      setState(() => update(next));
      _changed();
    }

    if (symptom) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(
              labelText: L.t(label), border: const OutlineInputBorder()),
          items: [
            for (final code in values)
              DropdownMenuItem(
                  value: code, child: Text(L.t('observation.symptom.$code')))
          ],
          onChanged: (next) {
            if (next != null) select(next);
          },
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(L.t(label), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final code in values)
            ChoiceChip(
              key: ValueKey('$label-$code'),
              label: Text(L.t('observation.state.$code')),
              selected: value == code,
              onSelected: (_) => select(code),
            ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records =
        ref.watch(petRecordsProvider(widget.petId)).valueOrNull ?? [];
    final reminders =
        ref.watch(petRemindersProvider(widget.petId)).valueOrNull ?? [];
    final visits = records
        .where((r) => r.type == RecordType.medical && r.deletedAt == null)
        .toList();
    final courses = reminders
        .where((r) =>
            r.deletedAt == null && MedicationCourse.fromReminder(r) != null)
        .toList();
    final selectedVisit = visits.any((r) => r.id == _medical) ? _medical! : '';
    final selectedCourse = courses.any((r) => r.id == _course) ? _course! : '';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(L.t('observation.help')),
      const SizedBox(height: 12),
      _choice('observation.symptom', _symptom, SymptomObservation.symptoms,
          (v) => _symptom = v,
          symptom: true),
      TextField(
          key: const ValueKey('symptom-count'),
          controller: _countController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: L.t('observation.count'),
              border: const OutlineInputBorder()),
          onChanged: (v) {
            _count = v.trim().isEmpty ? null : int.tryParse(v.trim()) ?? -1;
            _changed();
          }),
      const SizedBox(height: 12),
      _choice('observation.appetite', _appetite, SymptomObservation.appetites,
          (v) => _appetite = v),
      _choice('observation.energy', _energy, SymptomObservation.energies,
          (v) => _energy = v),
      _choice('observation.stool', _stool, SymptomObservation.stools,
          (v) => _stool = v),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        maintainState: true,
        initiallyExpanded: _medical != null || _course != null,
        title: Text(L.t('observation.extra')),
        subtitle: Text(L.t('observation.extraHint')),
        children: [
          DropdownButtonFormField<String>(
              key: ValueKey('observation-visit-$selectedVisit'),
              initialValue: selectedVisit,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: L.t('observation.medical'),
                  border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(
                    value: '', child: Text(L.t('observation.none'))),
                for (final record in visits)
                  DropdownMenuItem(
                      value: record.id,
                      child: Text(
                          '${record.recordedAt.month}/${record.recordedAt.day} ${record.valueText ?? ''}',
                          overflow: TextOverflow.ellipsis))
              ],
              onChanged: (v) {
                setState(() => _medical = v == '' ? null : v);
                _changed();
              }),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
              key: ValueKey('observation-course-$selectedCourse'),
              initialValue: selectedCourse,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: L.t('observation.course'),
                  border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(
                    value: '', child: Text(L.t('observation.none'))),
                for (final reminder in courses)
                  DropdownMenuItem(
                      value: reminder.id,
                      child:
                          Text(reminder.title, overflow: TextOverflow.ellipsis))
              ],
              onChanged: (v) {
                setState(() => _course = v == '' ? null : v);
                _changed();
              }),
        ],
      ),
    ]);
  }
}
