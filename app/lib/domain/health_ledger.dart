/// 预防保健台账 —— 把「计划」与「实际」对到一起。
///
/// 健康页原来只摆提醒列表（= 计划），结果用户最想问的那句话没人回答：
/// **「这针到底打了没？上次是什么时候？」**
///
/// 台账把两类数据合起来：一边是**已经发生的事实**（records 里的
/// 接种 / 驱虫 / 就诊），另一边是**还欠着的排期**（reminders）。
/// 同一行读完就知道差在哪，不用在记录页和提醒列表之间来回翻。
///
/// 本文件刻意不 import data 层：入参是已经拍平的 [CareFact] / [CareSchedule]，
/// 由调用方（手里有完整模型）做映射。好处是这块判断逻辑可以纯 Dart 测 ——
/// 不用建库、不用造 PetRecord。`test/health_ledger_test.dart` 就是这么做。
///
/// 分类直接复用 [PlanItemType]：台账的「一行」就是规则集的「一类产出」，
/// 两套枚举同构地各写一份，迟早会在加疫苗种类时只改一边。
///
/// 合规红线：台账只陈述「上次什么时候 / 下次什么时候」，
/// **不给健康评分、不给诊断**。这与首页删掉「状态：良好」是同一条纪律。
library;

import 'immunization.dart' show PlanItemType;

// 分类就是 PlanItemType，调用方（含测试）不该为了写台账再去 import 一遍免疫模块。
export 'immunization.dart' show PlanItemType;

/// 已经发生的一次预防动作（来自一条 record）。
class CareFact {
  const CareFact({required this.kind, required this.at, this.summary});

  final PlanItemType kind;

  /// 事件发生时间。用 `recordedAt` 而不是 `createdAt` ——
  /// 补录去年的疫苗本，发生时间才是真的。
  final DateTime at;

  /// 行内副文本，例如「狂犬 · 康泰动物医院」。没有就不显示。
  final String? summary;
}

/// 一条排期（来自一条 reminder）。
class CareSchedule {
  const CareSchedule({
    required this.kind,
    required this.nextAt,
    required this.enabled,
    this.title,
  });

  final PlanItemType kind;
  final DateTime nextAt;

  /// 用户关掉了这条提醒。「已关闭」不等于「不用做」，
  /// 所以仍然进台账，只是界面上要标出来。
  final bool enabled;

  /// 提醒标题（可能是 i18n key，交给界面翻）。
  final String? title;
}

/// 台账的一行：一类事项的「上次」与「下次」。
class CareLedgerRow {
  const CareLedgerRow({
    required this.kind,
    this.lastDoneAt,
    this.lastSummary,
    this.nextDueAt,
    this.scheduleTitle,
    this.scheduleEnabled = false,
    this.hasSchedule = false,
  });

  final PlanItemType kind;

  /// 最近一次实际发生的日期。null = 这一类从来没记过。
  final DateTime? lastDoneAt;
  final String? lastSummary;

  /// 最近一条排期的到期日。null = 没有排期。
  final DateTime? nextDueAt;
  final String? scheduleTitle;
  final bool scheduleEnabled;
  final bool hasSchedule;

  /// 有没有任何信息可摆。全空时界面走空态，不留一行骨架。
  bool get isEmpty => lastDoneAt == null && !hasSchedule;

  /// 是否已逾期。只比到「天」，与 `dueLabel` 的口径一致 ——
  /// 差 3 小时不该让整行变红。
  bool isOverdue(DateTime now) {
    final due = nextDueAt;
    if (due == null) return false;
    return _dayStart(due).isBefore(_dayStart(now));
  }

  /// 距到期还有几天。负数是逾期天数。没有排期返回 null。
  int? daysUntil(DateTime now) {
    final due = nextDueAt;
    if (due == null) return null;
    return _dayStart(due).difference(_dayStart(now)).inDays;
  }
}

/// 记录类型 wire 名 → 台账分类。
///
/// 体重 / 用药 / 喂食 / 排便这些属于「日常记录」，不进预防台账 ——
/// 台账上摆一条「今天称了体重」，只会把真正要紧的几行挤下去。
PlanItemType? careKindFromRecordWire(String wire) => switch (wire) {
      'vaccine' => PlanItemType.vaccine,
      'deworm_internal' => PlanItemType.dewormInternal,
      'deworm_external' => PlanItemType.dewormExternal,
      // 体检的实际发生就是一次就诊记录。规则集里的 checkup 排期
      // 和这里的 medical 记录是同一件事的两面。
      'medical' => PlanItemType.checkup,
      'grooming' => PlanItemType.grooming,
      _ => null,
    };

/// 提醒类型 → 台账分类。
///
/// 认两种写法：库里存下划线式（`deworm_internal`，来自 [PlanItemType.wireName]），
/// 但早年有驼峰式的历史数据。`reminderTypeIcon` 已经踩过这个坑
/// （驱虫和体检一直显示成默认小铃铛），这里别再踩一次。
PlanItemType? careKindFromReminderType(String type) => switch (type) {
      'vaccine' => PlanItemType.vaccine,
      'deworm_internal' || 'dewormInternal' => PlanItemType.dewormInternal,
      'deworm_external' || 'dewormExternal' => PlanItemType.dewormExternal,
      'checkup' => PlanItemType.checkup,
      'grooming' => PlanItemType.grooming,
      _ => null,
    };

/// 合并事实与排期，产出台账。
///
/// - 每条事实只取**最近一次**（同一类记了 5 针疫苗，台账只摆最后一针）
/// - 每条排期优先取**启用中且最早**的那条：用户手工加过一条「下月驱虫」，
///   自动排期却排到三个月后，先到的那个才是该响的
/// - 即使某一类两边都没有，也照样产出一行（[kinds] 决定有哪些行），
///   界面拿 [CareLedgerRow.isEmpty] 决定显示空态 —— 让「这一类还没开始管」
///   可见，比整块消失更接近事实
List<CareLedgerRow> buildCareLedger({
  required List<CareFact> facts,
  required List<CareSchedule> schedules,
  List<PlanItemType> kinds = PlanItemType.values,
}) {
  return [
    for (final kind in kinds) _rowFor(kind, facts, schedules),
  ];
}

CareLedgerRow _rowFor(
  PlanItemType kind,
  List<CareFact> facts,
  List<CareSchedule> schedules,
) {
  final latest = _pickLatestFact(facts, kind);
  final picked = _pickSchedule(schedules, kind);

  return CareLedgerRow(
    kind: kind,
    lastDoneAt: latest?.at,
    lastSummary: latest?.summary,
    nextDueAt: picked?.nextAt,
    scheduleTitle: picked?.title,
    scheduleEnabled: picked?.enabled ?? false,
    hasSchedule: picked != null,
  );
}

CareFact? _pickLatestFact(List<CareFact> facts, PlanItemType kind) {
  CareFact? best;
  for (final f in facts) {
    if (f.kind != kind) continue;
    final current = best;
    if (current == null || f.at.isAfter(current.at)) best = f;
  }
  return best;
}

CareSchedule? _pickSchedule(List<CareSchedule> schedules, PlanItemType kind) {
  CareSchedule? best;
  for (final s in schedules) {
    if (s.kind != kind) continue;
    final current = best;
    if (current == null || _preferOver(s, current)) best = s;
  }
  return best;
}

/// 候选是否比当前更该被选中。启用优先，其次更早。
bool _preferOver(CareSchedule candidate, CareSchedule current) {
  if (candidate.enabled != current.enabled) return candidate.enabled;
  return candidate.nextAt.isBefore(current.nextAt);
}

DateTime _dayStart(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
