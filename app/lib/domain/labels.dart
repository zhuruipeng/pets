/// 类型 → 展示文案的**纯映射**（不含任何 Widget）。
///
/// 为什么单独成文件：这几个映射原先和一堆 UI 组件挤在 `ui/widgets.dart` 里，
/// 而那个文件引了 `package:flutter/material.dart` —— 于是任何「只想拿个名字」
/// 的纯逻辑层（例如导出报告的内容组装）都没法复用，只能再抄一份，
/// 迟早两份漂移。挪到这里之后 `widgets.dart` 只负责转发，谁都能用。
///
/// ⚠️ 这里**只放纯字符串映射**。带 IconData 的（`recordTypeIcon` /
/// `reminderTypeIcon`）必须留在 UI 层，它们依赖 Flutter 的类型。
library;

import '../core/l10n.dart';
import '../core/units.dart';
import '../data/models.dart';
import 'immunization.dart' show PlanItemType;

/// 记录类型 → 展示名。
String recordTypeLabel(RecordType type) => switch (type) {
      RecordType.weight => L.t('addRecord.type.weight'),
      RecordType.vaccine => L.t('plan.vaccine.core'),
      RecordType.dewormInternal => L.t('plan.deworm.internal'),
      RecordType.dewormExternal => L.t('plan.deworm.external'),
      RecordType.medication => L.t('addRecord.type.medication'),
      RecordType.medical => L.t('addRecord.type.medical'),
      RecordType.grooming => L.t('addRecord.type.grooming'),
      RecordType.feeding => L.t('addRecord.type.feeding'),
      RecordType.toilet => L.t('addRecord.type.toilet'),
      RecordType.note => L.t('addRecord.type.note'),
    };

/// 计划项类型 → 展示名（规则集里的**细分名**）。
String planTypeLabel(PlanItemType type) => switch (type) {
      PlanItemType.vaccine => L.t('plan.vaccine.core'),
      PlanItemType.dewormInternal => L.t('plan.deworm.internal'),
      PlanItemType.dewormExternal => L.t('plan.deworm.external'),
      PlanItemType.checkup => L.t('plan.checkup.annual'),
      PlanItemType.grooming => L.t('plan.grooming'),
    };

/// 台账分类 → 展示名。
///
/// 与 [planTypeLabel] 刻意分开：那一套是规则集里的细分名（「核心疫苗」
/// 「年度体检」），而台账把同类合并成一行 —— 疫苗那行同时含联苗和狂犬，
/// 还叫「核心疫苗」会让人以为狂犬不在里面。
String careKindLabel(PlanItemType kind) => switch (kind) {
      PlanItemType.vaccine => L.t('profile.care.vaccine'),
      PlanItemType.dewormInternal => L.t('profile.care.dewormInternal'),
      PlanItemType.dewormExternal => L.t('profile.care.dewormExternal'),
      PlanItemType.checkup => L.t('profile.care.checkup'),
      PlanItemType.grooming => L.t('profile.care.grooming'),
    };

/// 宠物年龄，紧凑写法（「3岁2个月」/「3y 2mo」）。
///
/// 生日未知返回 null —— 空值怎么表达交给调用方（页面头部用「年龄未知」，
/// 信息卡用「--」），别在这里固定成一种。
///
/// 为什么不直接用 `Pet.ageInMonths`：那个属性只看年月不看日，月末会多算
/// 一个月；而且它内部取 `DateTime.now()`，没法在测试里固定时间。
/// 这里让 now 从外面传，导出报告与离线验证才能构造确定的时间点。
String? petAgeLabel(DateTime? birthday, DateTime now) {
  if (birthday == null) return null;
  var months = (now.year - birthday.year) * 12 + (now.month - birthday.month);
  if (now.day < birthday.day) months -= 1;
  if (months < 0) months = 0;
  final y = months ~/ 12;
  final m = months % 12;
  if (y == 0) return L.isZh ? '$m个月' : '${m}mo';
  if (m == 0) return L.isZh ? '$y岁' : '${y}y';
  return L.isZh ? '$y岁$m个月' : '${y}y ${m}mo';
}

/// 给药方式 code → 展示名。库里存 code，展示时才翻。
String medRouteLabel(String code) => switch (code) {
      'topical' => L.t('addRecord.med.route.topical'),
      'injection' => L.t('addRecord.med.route.injection'),
      _ => L.t('addRecord.med.route.oral'),
    };

/// 喂食类型 code → 展示名。
String feedKindLabel(String code) => switch (code) {
      'wet' => L.t('addRecord.feed.kind.wet'),
      'treat' => L.t('addRecord.feed.kind.treat'),
      _ => L.t('addRecord.feed.kind.dry'),
    };

/// 记录行的数值文本。
///
/// 体重走单位换算；喂食带自己存的 unit（g）；都没有就落回 valueText。
/// 算不出来返回 null，调用方不显示这一行 —— 不拿占位符糊弄。
String? recordValueLine(PetRecord r, WeightUnit unit) {
  final v = r.valueNum;
  if (v != null) {
    if (r.type == RecordType.weight) return Units.formatWeight(v, unit);
    final u = r.unit;
    if (u == null) return v.toStringAsFixed(1);
    return '${v.toStringAsFixed(u == 'g' ? 0 : 1)} $u';
  }
  final t = (r.valueText ?? '').trim();
  return t.isEmpty ? null : t;
}

/// payload 里的结构化字段拼成一行副文本（「1 片 · 口服」）。
///
/// 单个数值塞进 value_num 就够，但剂量、给药方式、品牌这类字段没有专属列，
/// 统一走 payload。空字符串表示「没有可补充的」，调用方别渲染。
String recordPayloadSummary(PetRecord r) {
  final p = r.payload;
  final parts = <String>[];
  switch (r.type) {
    case RecordType.medication:
      final dose = (p['dose'] as String?)?.trim() ?? '';
      final route = (p['route'] as String?) ?? '';
      if (dose.isNotEmpty) parts.add(dose);
      if (route.isNotEmpty) parts.add(medRouteLabel(route));
      break;
    case RecordType.feeding:
      final kind = (p['kind'] as String?) ?? '';
      if (kind.isNotEmpty) parts.add(feedKindLabel(kind));
      final brand = (p['brand'] as String?)?.trim() ?? '';
      if (brand.isNotEmpty) parts.add(brand);
      break;
    case RecordType.note:
      // 从「回忆」相册加的照片，库里是一条 note + payload.kind=photo。
      // 翻译在展示层做 —— 库里存 i18n 文本，切区或改文案就成历史脏数据。
      if ((p['kind'] as String?) == 'photo') parts.add(L.t('record.kind.photo'));
      break;
    default:
      break;
  }
  return parts.join(' · ');
}
