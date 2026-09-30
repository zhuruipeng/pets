/// 预防保健台账测试。
///
/// 这块逻辑的价值全在「配对」上：把 records 和 reminders 里散落的两类数据
/// 对成一行。配错的表现是「明明打过疫苗，台账还说没记录」——
/// 用户不会报 bug，他只会不再信任这一页。所以每个分支都守一条。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/domain/health_ledger.dart';

void main() {
  final now = DateTime(2026, 9, 30, 20, 0);

  CareFact fact(PlanItemType kind, DateTime at, [String? summary]) =>
      CareFact(kind: kind, at: at, summary: summary);

  CareSchedule sched(
    PlanItemType kind,
    DateTime nextAt, {
    bool enabled = true,
    String? title,
  }) =>
      CareSchedule(
        kind: kind,
        nextAt: nextAt,
        enabled: enabled,
        title: title,
      );

  group('空输入', () {
    test('四类都产出一行，且都标记为空', () {
      final rows = buildCareLedger(facts: const [], schedules: const []);

      expect(rows.map((r) => r.kind), PlanItemType.values);
      expect(rows.every((r) => r.isEmpty), isTrue);
      expect(rows.every((r) => r.lastDoneAt == null), isTrue);
      expect(rows.every((r) => r.nextDueAt == null), isTrue);
    });

    test('kinds 可以裁剪要显示的行', () {
      final rows = buildCareLedger(
        facts: const [],
        schedules: const [],
        kinds: const [PlanItemType.vaccine, PlanItemType.checkup],
      );

      expect(rows.length, 2);
      expect(rows.map((r) => r.kind), [PlanItemType.vaccine, PlanItemType.checkup]);
    });
  });

  group('事实侧', () {
    test('同类多次记录只取最近一次', () {
      final rows = buildCareLedger(
        facts: [
          fact(PlanItemType.vaccine, DateTime(2026, 3, 1), '第一针'),
          fact(PlanItemType.vaccine, DateTime(2026, 6, 20), '第二针'),
          fact(PlanItemType.vaccine, DateTime(2025, 12, 1), '更早的一针'),
        ],
        schedules: const [],
      );

      final v = rows.firstWhere((r) => r.kind == PlanItemType.vaccine);
      expect(v.lastDoneAt, DateTime(2026, 6, 20));
      expect(v.lastSummary, '第二针');
    });

    test('只有事实、没有排期时，仍然记下上次时间', () {
      final rows = buildCareLedger(
        facts: [fact(PlanItemType.dewormExternal, DateTime(2026, 9, 1))],
        schedules: const [],
      );

      final d = rows.firstWhere((r) => r.kind == PlanItemType.dewormExternal);
      expect(d.lastDoneAt, DateTime(2026, 9, 1));
      expect(d.hasSchedule, isFalse);
      expect(d.isEmpty, isFalse); // 有事实就不算空
    });

    test('不相关的事实不会串到别的分类', () {
      final rows = buildCareLedger(
        facts: [fact(PlanItemType.checkup, DateTime(2026, 1, 1))],
        schedules: const [],
      );

      final v = rows.firstWhere((r) => r.kind == PlanItemType.vaccine);
      expect(v.lastDoneAt, isNull);
    });
  });

  group('排期侧', () {
    test('同类多条排期时取最早的那条', () {
      final rows = buildCareLedger(
        facts: const [],
        schedules: [
          sched(PlanItemType.dewormInternal, DateTime(2026, 12, 1)),
          sched(PlanItemType.dewormInternal, DateTime(2026, 10, 15)),
        ],
      );

      final d = rows.firstWhere((r) => r.kind == PlanItemType.dewormInternal);
      expect(d.nextDueAt, DateTime(2026, 10, 15));
    });

    test('启用中的排期优先于已关闭的，哪怕后者更早', () {
      final rows = buildCareLedger(
        facts: const [],
        schedules: [
          sched(PlanItemType.vaccine, DateTime(2026, 10, 1), enabled: false),
          sched(PlanItemType.vaccine, DateTime(2026, 11, 1), enabled: true),
        ],
      );

      final v = rows.firstWhere((r) => r.kind == PlanItemType.vaccine);
      expect(v.nextDueAt, DateTime(2026, 11, 1));
      expect(v.scheduleEnabled, isTrue);
    });

    test('只有已关闭的排期时，照样进台账并标记未启用', () {
      final rows = buildCareLedger(
        facts: const [],
        schedules: [
          sched(PlanItemType.vaccine, DateTime(2026, 10, 1), enabled: false),
        ],
      );

      final v = rows.firstWhere((r) => r.kind == PlanItemType.vaccine);
      // 「关了提醒」不等于「不用做」—— 行还在，只是界面要标明。
      expect(v.hasSchedule, isTrue);
      expect(v.scheduleEnabled, isFalse);
      expect(v.isEmpty, isFalse);
    });
  });

  group('事实与排期配对', () {
    test('同一类能同时给出上次与下次', () {
      final rows = buildCareLedger(
        facts: [fact(PlanItemType.vaccine, DateTime(2026, 3, 12), '狂犬')],
        schedules: [
          sched(PlanItemType.vaccine, DateTime(2027, 3, 12), title: 'plan.vaccine.rabies'),
        ],
      );

      final v = rows.firstWhere((r) => r.kind == PlanItemType.vaccine);
      expect(v.lastDoneAt, DateTime(2026, 3, 12));
      expect(v.lastSummary, '狂犬');
      expect(v.nextDueAt, DateTime(2027, 3, 12));
      expect(v.scheduleTitle, 'plan.vaccine.rabies');
    });

    test('排期不会串类：疫苗的排期不会落到驱虫那行', () {
      final rows = buildCareLedger(
        facts: const [],
        schedules: [sched(PlanItemType.vaccine, DateTime(2027, 1, 1))],
      );

      for (final r in rows.where((r) => r.kind != PlanItemType.vaccine)) {
        expect(r.nextDueAt, isNull, reason: '${r.kind} 不该拿到疫苗的排期');
      }
    });
  });

  group('逾期判定', () {
    test('同一天不算逾期，哪怕已过了时刻', () {
      final row = buildCareLedger(
        facts: const [],
        schedules: [sched(PlanItemType.vaccine, DateTime(2026, 9, 30, 8, 0))],
      ).firstWhere((r) => r.kind == PlanItemType.vaccine);

      expect(row.isOverdue(now), isFalse);
      expect(row.daysUntil(now), 0);
    });

    test('差一天才算逾期，且天数是负数', () {
      final row = buildCareLedger(
        facts: const [],
        schedules: [sched(PlanItemType.vaccine, DateTime(2026, 9, 29, 23, 0))],
      ).firstWhere((r) => r.kind == PlanItemType.vaccine);

      expect(row.isOverdue(now), isTrue);
      expect(row.daysUntil(now), -1);
    });

    test('未来的排期给出正的天数', () {
      final row = buildCareLedger(
        facts: const [],
        schedules: [sched(PlanItemType.checkup, DateTime(2026, 10, 10))],
      ).firstWhere((r) => r.kind == PlanItemType.checkup);

      expect(row.isOverdue(now), isFalse);
      expect(row.daysUntil(now), 10);
    });

    test('没有排期时不该说逾期', () {
      final rows = buildCareLedger(facts: const [], schedules: const []);
      expect(rows.every((r) => r.isOverdue(now)), isFalse);
      expect(rows.every((r) => r.daysUntil(now) == null), isTrue);
    });
  });

  group('wire 名映射', () {
    test('记录类型：只有预防类进台账', () {
      expect(careKindFromRecordWire('vaccine'), PlanItemType.vaccine);
      expect(careKindFromRecordWire('deworm_internal'), PlanItemType.dewormInternal);
      expect(careKindFromRecordWire('deworm_external'), PlanItemType.dewormExternal);
      expect(careKindFromRecordWire('medical'), PlanItemType.checkup);

      // 日常记录不该挤进预防台账
      expect(careKindFromRecordWire('weight'), isNull);
      expect(careKindFromRecordWire('medication'), isNull);
      expect(careKindFromRecordWire('feeding'), isNull);
      expect(careKindFromRecordWire('toilet'), isNull);
      expect(careKindFromRecordWire('note'), isNull);
    });

    test('提醒类型：下划线与驼峰两种历史写法都要认', () {
      expect(careKindFromReminderType('vaccine'), PlanItemType.vaccine);
      expect(careKindFromReminderType('deworm_internal'), PlanItemType.dewormInternal);
      expect(careKindFromReminderType('dewormInternal'), PlanItemType.dewormInternal);
      expect(careKindFromReminderType('deworm_external'), PlanItemType.dewormExternal);
      expect(careKindFromReminderType('dewormExternal'), PlanItemType.dewormExternal);
      expect(careKindFromReminderType('checkup'), PlanItemType.checkup);
    });

    test('用户自建的其它类型不进球', () {
      expect(careKindFromReminderType('medication'), isNull);
      expect(careKindFromReminderType('other'), isNull);
      expect(careKindFromReminderType(''), isNull);
    });
  });
}
