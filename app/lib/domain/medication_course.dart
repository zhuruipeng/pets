/// User-entered medication schedules. This module does not suggest treatments.
library;

import '../data/models.dart';

class MedicationCourse {
  const MedicationCourse({
    required this.name,
    required this.dose,
    required this.start,
    required this.end,
    required this.times,
    this.route = 'oral',
    this.stock,
    this.unitsPerDose = 1,
  });

  final String name;
  final String dose;
  final String route;
  final DateTime start;
  final DateTime end;

  /// Minutes after midnight, in local wall-clock time.
  final List<int> times;
  final double? stock;
  final double unitsPerDose;

  void validate() {
    if (name.trim().isEmpty || dose.trim().isEmpty) {
      throw ArgumentError('med.error.required');
    }
    if (day(end).isBefore(day(start))) {
      throw ArgumentError('med.error.dates');
    }
    if (times.isEmpty ||
        times.length > 8 ||
        times.toSet().length != times.length ||
        times.any((v) => v < 0 || v >= 1440)) {
      throw ArgumentError('med.error.times');
    }
    if (!unitsPerDose.isFinite ||
        unitsPerDose <= 0 ||
        (stock != null && (!stock!.isFinite || stock! < 0))) {
      throw ArgumentError('med.error.stock');
    }
  }

  Map<String, dynamic> toRule() {
    validate();
    return {
      'mode': 'medication',
      'dose': dose.trim(),
      'route': route,
      'start_date': date(start),
      'end_date': date(end),
      'times': [...times]..sort(),
      if (stock != null) 'stock': stock,
      'units_per_dose': unitsPerDose,
    };
  }

  static MedicationCourse? fromReminder(Reminder reminder) {
    if (reminder.rule['mode'] != 'medication') return null;
    try {
      final r = reminder.rule;
      final course = MedicationCourse(
        name: reminder.title,
        dose: r['dose'] as String,
        route: r['route'] as String? ?? 'oral',
        start: DateTime.parse(r['start_date'] as String),
        end: DateTime.parse(r['end_date'] as String),
        times: (r['times'] as List).map((v) => (v as num).toInt()).toList(),
        stock: (r['stock'] as num?)?.toDouble(),
        unitsPerDose: (r['units_per_dose'] as num?)?.toDouble() ?? 1,
      );
      course.validate();
      return course;
    } catch (_) {
      return null;
    }
  }

  /// First slot on/after [at], or strictly after it when [inclusive] is false.
  DateTime? nextAt(DateTime at, {bool inclusive = true}) {
    final sorted = [...times]..sort();
    var current = day(at).isBefore(day(start)) ? day(start) : day(at);
    while (!current.isAfter(day(end))) {
      for (final minute in sorted) {
        // Construct by calendar components; adding 24h drifts across DST.
        final candidate = DateTime(current.year, current.month, current.day,
            minute ~/ 60, minute % 60);
        if (candidate.isAfter(at) ||
            (inclusive && candidate.isAtSameMomentAs(at))) {
          return candidate;
        }
      }
      current = DateTime(current.year, current.month, current.day + 1);
    }
    return null;
  }

  double? remaining(num stockUsed) => stock == null
      ? null
      : (stock! - stockUsed).clamp(0, double.infinity).toDouble();

  List<DateTime> upcomingSlots(DateTime at, {int limit = 32}) {
    final slots = <DateTime>[];
    var next = nextAt(at);
    while (next != null && slots.length < limit) {
      slots.add(next);
      next = nextAt(next, inclusive: false);
    }
    return slots;
  }

  static DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  static String date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
