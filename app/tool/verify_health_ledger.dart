/// 无 Flutter 环境下真跑一遍健康台账逻辑。
///
/// 为什么需要它：本机非提权进程跑 `flutter test` 必踩命名管道 231，
/// 而 `health_ledger.dart` 刻意不 import data 层、也不碰 Flutter 控件，
/// 所以整条链路是纯 Dart —— 可以用 dart 直接执行，把「配对 / 逾期 / 映射」
/// 三块判定拿在手里，而不是等用户跑完包才知道。
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_health_ledger.dart
///
/// 它**不替代** `test/health_ledger_test.dart`（那边才是正式用例），
/// 两者是同一批断言的两种跑法：这边是无 Flutter 时的兜底。
library;

import 'package:pet_app/domain/health_ledger.dart';

int _passed = 0;
int _failed = 0;

void check(bool ok, String what) {
  if (ok) {
    _passed++;
  } else {
    _failed++;
    print('FAIL  $what');
  }
}

CareFact fact(PlanItemType kind, DateTime at, [String? summary]) =>
    CareFact(kind: kind, at: at, summary: summary);

CareSchedule sched(
  PlanItemType kind,
  DateTime nextAt, {
  bool enabled = true,
  String? title,
}) =>
    CareSchedule(kind: kind, nextAt: nextAt, enabled: enabled, title: title);

void main() {
  final now = DateTime(2026, 9, 30, 20, 0);

  // ---- 空输入 ----
  final empty = buildCareLedger(facts: const [], schedules: const []);
  check(empty.length == 4, '空输入应产出 4 行，实际 ${empty.length}');
  check(empty.every((r) => r.isEmpty), '空输入每行都该是 isEmpty');
  check(empty.every((r) => r.nextDueAt == null), '空输入没有排期');
  check(empty.every((r) => !r.isOverdue(now)), '空输入不该说逾期');

  final cut = buildCareLedger(
    facts: const [],
    schedules: const [],
    kinds: const [PlanItemType.vaccine, PlanItemType.checkup],
  );
  check(cut.length == 2, 'kinds 裁剪应剩 2 行，实际 ${cut.length}');

  // ---- 事实侧 ----
  final multi = buildCareLedger(
    facts: [
      fact(PlanItemType.vaccine, DateTime(2026, 3, 1), '第一针'),
      fact(PlanItemType.vaccine, DateTime(2026, 6, 20), '第二针'),
      fact(PlanItemType.vaccine, DateTime(2025, 12, 1), '更早'),
    ],
    schedules: const [],
  );
  final v = multi.firstWhere((r) => r.kind == PlanItemType.vaccine);
  check(v.lastDoneAt == DateTime(2026, 6, 20), '同类多事实应取最近一次');
  check(v.lastSummary == '第二针', '摘要应跟着最近那次走');
  check(!v.isEmpty, '有事实就不算空');

  final orphan = buildCareLedger(
    facts: [fact(PlanItemType.checkup, DateTime(2026, 1, 1))],
    schedules: const [],
  );
  check(
    orphan.firstWhere((r) => r.kind == PlanItemType.vaccine).lastDoneAt == null,
    '事实不该串到别的分类',
  );

  // ---- 排期侧 ----
  final earliest = buildCareLedger(
    facts: const [],
    schedules: [
      sched(PlanItemType.dewormInternal, DateTime(2026, 12, 1)),
      sched(PlanItemType.dewormInternal, DateTime(2026, 10, 15)),
    ],
  );
  check(
    earliest
            .firstWhere((r) => r.kind == PlanItemType.dewormInternal)
            .nextDueAt ==
        DateTime(2026, 10, 15),
    '同类多排期应取最早',
  );

  final preferOn = buildCareLedger(
    facts: const [],
    schedules: [
      sched(PlanItemType.vaccine, DateTime(2026, 10, 1), enabled: false),
      sched(PlanItemType.vaccine, DateTime(2026, 11, 1), enabled: true),
    ],
  ).firstWhere((r) => r.kind == PlanItemType.vaccine);
  check(preferOn.nextDueAt == DateTime(2026, 11, 1), '启用中的排期该优先');
  check(preferOn.scheduleEnabled, '应标记为启用');

  final offOnly = buildCareLedger(
    facts: const [],
    schedules: [
      sched(PlanItemType.vaccine, DateTime(2026, 10, 1), enabled: false),
    ],
  ).firstWhere((r) => r.kind == PlanItemType.vaccine);
  check(offOnly.hasSchedule, '关掉的排期仍该进台账');
  check(!offOnly.scheduleEnabled, '应标记为未启用');
  check(!offOnly.isEmpty, '有排期就不算空');

  // ---- 配对 ----
  final paired = buildCareLedger(
    facts: [fact(PlanItemType.vaccine, DateTime(2026, 3, 12), '狂犬')],
    schedules: [
      sched(
        PlanItemType.vaccine,
        DateTime(2027, 3, 12),
        title: 'plan.vaccine.rabies',
      ),
    ],
  ).firstWhere((r) => r.kind == PlanItemType.vaccine);
  check(paired.lastDoneAt == DateTime(2026, 3, 12), '上次该是 3-12');
  check(paired.nextDueAt == DateTime(2027, 3, 12), '下次该是 2027-3-12');
  check(paired.scheduleTitle == 'plan.vaccine.rabies', '标题该透传');

  // ---- 逾期按天 ----
  final sameDay = buildCareLedger(
    facts: const [],
    schedules: [sched(PlanItemType.vaccine, DateTime(2026, 9, 30, 8, 0))],
  ).firstWhere((r) => r.kind == PlanItemType.vaccine);
  check(!sameDay.isOverdue(now), '同一天不算逾期');
  check(sameDay.daysUntil(now) == 0, '同一天天数应为 0');

  final yesterday = buildCareLedger(
    facts: const [],
    schedules: [sched(PlanItemType.vaccine, DateTime(2026, 9, 29, 23, 0))],
  ).firstWhere((r) => r.kind == PlanItemType.vaccine);
  check(yesterday.isOverdue(now), '差一天该判逾期');
  check(yesterday.daysUntil(now) == -1, '逾期天数应为 -1');

  final future = buildCareLedger(
    facts: const [],
    schedules: [sched(PlanItemType.checkup, DateTime(2026, 10, 10))],
  ).firstWhere((r) => r.kind == PlanItemType.checkup);
  check(!future.isOverdue(now), '未来不该逾期');
  check(future.daysUntil(now) == 10, '应还有 10 天');

  // ---- wire 名映射 ----
  check(careKindFromRecordWire('vaccine') == PlanItemType.vaccine, 'record vaccine');
  check(
    careKindFromRecordWire('deworm_internal') == PlanItemType.dewormInternal,
    'record deworm_internal',
  );
  check(
    careKindFromRecordWire('deworm_external') == PlanItemType.dewormExternal,
    'record deworm_external',
  );
  check(careKindFromRecordWire('medical') == PlanItemType.checkup, 'record medical→checkup');
  for (final daily in ['weight', 'medication', 'feeding', 'toilet', 'note']) {
    check(careKindFromRecordWire(daily) == null, 'record $daily 不该进台账');
  }

  check(careKindFromReminderType('vaccine') == PlanItemType.vaccine, 'remind vaccine');
  check(
    careKindFromReminderType('deworm_internal') == PlanItemType.dewormInternal,
    'remind 下划线驱虫',
  );
  check(
    careKindFromReminderType('dewormInternal') == PlanItemType.dewormInternal,
    'remind 驼峰驱虫（历史数据）',
  );
  check(
    careKindFromReminderType('dewormExternal') == PlanItemType.dewormExternal,
    'remind 驼峰体外驱虫',
  );
  check(careKindFromReminderType('checkup') == PlanItemType.checkup, 'remind checkup');
  check(careKindFromReminderType('other') == null, 'remind other 不该进台账');
  check(careKindFromReminderType('') == null, 'remind 空串不该进台账');

  print('');
  print('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) throw StateError('健康台账校验失败 $_failed 项');
}
