/// 「健康报告」的内容模型与组装 —— **纯数据，不含任何绘制**。
///
/// 为什么把组装单独分出来：导出报告最容易出错的不是画得好不好看，而是
/// 「哪些记录该进报告、日期怎么摆、空数据怎么表达」。这些是纯逻辑，
/// 放在这里就能用 dart 直接跑（本机跑不了 flutter test，见
/// docs/环境阻塞-flutter管道问题.md），绘制另见 services/report_renderer.dart。
library;

import '../core/l10n.dart';
import '../core/species.dart';
import '../core/units.dart';
import '../data/models.dart';
import 'health_ledger.dart';
import 'labels.dart';

/// 报告开头的「档案要点」一行。
class ReportFact {
  const ReportFact(this.label, this.value);
  final String label;
  final String value;
}

/// 报告里的台账一行。
class ReportCareRow {
  const ReportCareRow({
    required this.label,
    required this.lastText,
    required this.nextText,
    required this.hasLast,
    required this.hasNext,
  });

  final String label;
  final String lastText;
  final String nextText;

  /// 原始数据有没有值。**不要拿 lastText 去和「还没有记录」比较** ——
  /// 那是靠文案相等判断，改一个字就静默失效。
  final bool hasLast;
  final bool hasNext;

  /// 上次和下次都没有 —— 这一行不用印。
  bool get isEmpty => !hasLast && !hasNext;
}

/// 报告里的一条记录。
class ReportRecord {
  const ReportRecord({
    required this.typeLabel,
    required this.when,
    this.value,
    this.detail,
    this.note,
  });

  final String typeLabel;
  final DateTime when;

  /// 数值（体重已按区域换算）。空表示这条记录没有数值。
  final String? value;

  /// payload 摘要（「1 片 · 口服」）。空表示没有可补充的。
  final String? detail;

  final String? note;
}

/// 一份报告的全部内容。绘制层只认这个结构，不再碰数据库。
class PetReport {
  const PetReport({
    required this.petName,
    required this.subtitle,
    required this.facts,
    required this.careRows,
    required this.weightPoints,
    required this.records,
    required this.generatedAt,
    required this.weightUnit,
  });

  final String petName;

  /// 「狗 · 金毛 · 3岁2个月」这类一行简介。
  final String subtitle;

  final List<ReportFact> facts;
  final List<ReportCareRow> careRows;

  /// 体重趋势点，**按时间升序**（画折线用）。单位是公制 kg ——
  /// 换算由绘制层按 [weightUnit] 做，存储层不碰展示单位。
  final List<({DateTime at, double kg})> weightPoints;

  /// 最近的记录，**按时间倒序**（最新的在最上面）。
  final List<ReportRecord> records;

  final DateTime generatedAt;

  /// 体重展示单位。
  ///
  /// ⚠️ 这个字段以前**根本不存在**，于是绘制层拿不到单位，只能拿 `weightPoints`
  /// 里的 kg 直接画 —— 结果海外版报告出现「Y 轴标公斤、旁边数字标磅」的
  /// 同一张图两种单位。给医生看时会被读错 2.2 倍。
  /// 单位必须**跟着报告一起传下去**，绘制层才有得换算。
  final WeightUnit weightUnit;

  /// 台账里真正有内容的行。
  List<ReportCareRow> get filledCareRows =>
      careRows.where((r) => !r.isEmpty).toList();

  /// 一条记录都没有 —— 绘制层据此走「还没有记录」的说明，别印一张空表。
  bool get hasNothing => records.isEmpty && weightPoints.isEmpty;
}

String _p2(int v) => v.toString().padLeft(2, '0');

/// 报告里的日期一律 `2026-10-01`。
///
/// 不用「3 天前」这类相对时间：报告是拿去给兽医看的、还可能被打印或转发，
/// 相对时间在别的日期读就失去意义。也不做本地化 —— 数值日期最不容易误读。
String reportDate(DateTime d) => '${d.year}-${_p2(d.month)}-${_p2(d.day)}';

/// 组装一份报告。纯函数：给定同样的输入必得同样的输出。
PetReport buildPetReport({
  required Pet pet,
  required List<CareLedgerRow> ledger,
  required List<({DateTime at, double kg})> weightSeries,
  required List<PetRecord> records,
  required DateTime now,
  required WeightUnit weightUnit,
  int maxRecords = 12,
  int maxWeights = 12,
}) {
  // 简介：物种 · 品种 · 年龄。品种和年龄都可能缺，缺的就跳过。
  final subtitleParts = <String>[
    switch (pet.species) {
      Species.dog => L.t('addPet.species.dog'),
      Species.cat => L.t('addPet.species.cat'),
      Species.other => L.t('addPet.species.other'),
    },
    if ((pet.breed ?? '').trim().isNotEmpty) pet.breed!.trim(),
    if (petAgeLabel(pet.birthday, now) != null)
      petAgeLabel(pet.birthday, now)!,
  ];

  // 档案要点：只放填过的，空字段不占位置。
  final facts = <ReportFact>[
    if (pet.weightBaseline != null)
      ReportFact(
        L.t('editPet.weightBaseline'),
        Units.formatWeight(pet.weightBaseline!, weightUnit),
      ),
    if (pet.neutered) ReportFact(L.t('editPet.neutered'), L.t('common.yes')),
    if ((pet.chipNo ?? '').trim().isNotEmpty)
      ReportFact(L.t('editPet.chipNo'), pet.chipNo!.trim()),
    if ((pet.allergy ?? '').trim().isNotEmpty)
      ReportFact(L.t('editPet.allergy'), pet.allergy!.trim()),
  ];

  final careRows = [
    for (final row in ledger)
      ReportCareRow(
        label: careKindLabel(row.kind),
        lastText: row.lastDoneAt == null
            ? L.t('profile.care.lastNone')
            : reportDate(row.lastDoneAt!),
        nextText: row.nextDueAt == null
            ? L.t('profile.care.unscheduled')
            : reportDate(row.nextDueAt!),
        hasLast: row.lastDoneAt != null,
        hasNext: row.nextDueAt != null,
      ),
  ];

  // 体重只取最近 maxWeights 个，且升序（画折线从左到右）。
  final weights = weightSeries.length <= maxWeights
      ? [...weightSeries]
      : weightSeries.sublist(weightSeries.length - maxWeights);

  // 记录按发生时间倒序，取最近 maxRecords 条。
  final sorted = [...records]
    ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
  final recent = sorted.take(maxRecords).toList();

  final reportRecords = [
    for (final r in recent)
      ReportRecord(
        typeLabel: recordTypeLabel(r.type),
        when: r.recordedAt,
        value: recordValueLine(r, weightUnit),
        detail: _orNull(recordPayloadSummary(r)),
        note: _orNull(r.note),
      ),
  ];

  return PetReport(
    petName: pet.name,
    subtitle: subtitleParts.join(' · '),
    facts: facts,
    careRows: careRows,
    weightPoints: weights,
    records: reportRecords,
    generatedAt: now,
    weightUnit: weightUnit,
  );
}

/// 空串归一成 null —— 绘制层只需判 null，不必再判空串。
String? _orNull(String? s) {
  final t = (s ?? '').trim();
  return t.isEmpty ? null : t;
}
