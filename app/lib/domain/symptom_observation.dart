import '../core/l10n.dart';
import '../data/models.dart';

/// Owner observations, stored as records so attachments and sync remain shared.
class SymptomObservation {
  const SymptomObservation(
      {this.symptom = 'vomiting',
      this.count,
      this.appetite = 'unobserved',
      this.energy = 'unobserved',
      this.stool = 'unobserved',
      this.medicalRecordId,
      this.courseReminderId});

  static const symptoms = [
    'vomiting',
    'loose_stool',
    'cough',
    'itch',
    'appetite',
    'energy',
    'other'
  ];
  static const appetites = ['unobserved', 'normal', 'reduced', 'increased'];
  static const energies = ['unobserved', 'normal', 'low', 'restless'];
  static const stools = ['unobserved', 'normal', 'soft', 'liquid', 'hard'];
  final String symptom, appetite, energy, stool;
  final int? count;
  final String? medicalRecordId, courseReminderId;

  void validate() {
    if (!symptoms.contains(symptom) ||
        !appetites.contains(appetite) ||
        !energies.contains(energy) ||
        !stools.contains(stool) ||
        (count != null && (count! < 1 || count! > 1000))) {
      throw ArgumentError('observation.invalid');
    }
  }

  Map<String, dynamic> toPayload() {
    validate();
    return {
      'symptom': symptom,
      if (count != null) 'count': count,
      'appetite': appetite,
      'energy': energy,
      'stool': stool,
      if (medicalRecordId != null) 'medical_record_id': medicalRecordId,
      if (courseReminderId != null) 'course_reminder_id': courseReminderId
    };
  }

  static SymptomObservation? fromRecord(PetRecord record) {
    if (record.type != RecordType.symptom) return null;
    return fromPayload(record.payload);
  }

  static SymptomObservation? fromPayload(Map<String, dynamic> p) {
    try {
      final result = SymptomObservation(
          symptom: p['symptom'] as String,
          count: p['count'] as int?,
          appetite: p['appetite'] as String? ?? 'unobserved',
          energy: p['energy'] as String? ?? 'unobserved',
          stool: p['stool'] as String? ?? 'unobserved',
          medicalRecordId: p['medical_record_id'] as String?,
          courseReminderId: p['course_reminder_id'] as String?);
      result.validate();
      return result;
    } catch (_) {
      return null;
    }
  }

  String get title => L.t('observation.symptom.$symptom');
  String get summary => [
        if (count != null) L.tp('observation.countValue', {'count': count}),
        if (appetite != 'unobserved')
          '${L.t('observation.appetite')}: ${L.t('observation.state.$appetite')}',
        if (energy != 'unobserved')
          '${L.t('observation.energy')}: ${L.t('observation.state.$energy')}',
        if (stool != 'unobserved')
          '${L.t('observation.stool')}: ${L.t('observation.state.$stool')}',
      ].join(' · ');
}
