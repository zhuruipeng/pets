library;

import '../data/models.dart';

class CareEvent {
  const CareEvent(
      {required this.at,
      this.type,
      this.title,
      this.detail,
      this.actorId,
      this.actorName,
      this.recordId});
  final DateTime at;
  final RecordType? type;
  final String? title;
  final String? detail;
  final String? actorId;
  final String? actorName;
  final String? recordId;
}

List<CareEvent> buildCareEvents({
  required List<PetRecord> records,
  required List<Map<String, Object?>> logs,
  required List<Reminder> reminders,
  required DateTime day,
}) {
  final start = DateTime(day.year, day.month, day.day);
  final end = DateTime(day.year, day.month, day.day + 1);
  bool today(DateTime at) => !at.isBefore(start) && at.isBefore(end);
  final events = <CareEvent>[
    for (final r in records)
      if (r.deletedAt == null && today(r.recordedAt))
        CareEvent(
            at: r.recordedAt,
            type: r.type,
            actorId: r.createdBy,
            detail: [
              if (r.valueText != null) r.valueText!,
              if (r.payload['dose'] is String) r.payload['dose'] as String,
              if (r.valueNum != null) '${r.valueNum} ${r.unit ?? ''}'
            ].join(' · '),
            actorName: r.payload['actor_name'] as String?,
            recordId: r.id),
  ];
  final recordIds =
      records.where((r) => r.deletedAt == null).map((r) => r.id).toSet();
  final byId = {for (final r in reminders) r.id: r};
  for (final log in logs) {
    if (log['done_at'] == null ||
        log['deleted_at'] != null ||
        log['action'] != 'done' ||
        recordIds.contains(log['record_id'])) {
      continue;
    }
    final at =
        DateTime.fromMillisecondsSinceEpoch((log['done_at'] as num).toInt());
    if (!today(at)) continue;
    final reminder = byId[log['reminder_id']];
    events.add(CareEvent(
        at: at,
        title: reminder?.title ?? log['title'] as String?,
        actorId: log['created_by'] as String?,
        actorName: log['actor_name'] as String?));
  }
  return events..sort((a, b) => b.at.compareTo(a.at));
}
