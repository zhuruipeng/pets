/// 建议排期生成 —— MVP 里唯一「有专业含量」的部分。
///
/// 用户在建档问卷里回答三件事（居住地 / 打过哪些疫苗 / 生日），
/// 系统据此算出疫苗、驱虫、体检的建议时间表。
/// 中国与海外的兽医规程不同，因此规则集按区域分。
///
/// 合规红线：对外文案一律用「建议 / 通常」，并附「以兽医意见为准」。
/// 禁止出现任何诊断性表述，否则会滑向互联网诊疗的监管范畴。
library;

import '../core/region.dart';
import '../core/species.dart';

export '../core/species.dart' show Species;

/// 计划项的类型，与 records.type 对齐。
enum PlanItemType { vaccine, dewormInternal, dewormExternal, checkup }

extension PlanItemTypeX on PlanItemType {
  String get wireName => switch (this) {
        PlanItemType.vaccine => 'vaccine',
        PlanItemType.dewormInternal => 'deworm_internal',
        PlanItemType.dewormExternal => 'deworm_external',
        PlanItemType.checkup => 'checkup',
      };
}

/// 生成出来的单个待办项。
class PlannedEvent {
  const PlannedEvent({
    required this.code,
    required this.type,
    required this.titleKey,
    required this.dueAt,
    required this.recurring,
  });

  /// 稳定标识，用于去重与匹配已有 reminders。
  final String code;
  final PlanItemType type;

  /// i18n key，不直接存中文，避免和国际化打架。
  final String titleKey;

  final DateTime dueAt;
  final bool recurring;
}

/// 内部规则描述。数据驱动，便于后续按地区微调而不改算法。
///
/// 公开是为了让规则集子类能声明自己的 specs；不对外导出使用。
class RuleSpec {
  const RuleSpec({
    required this.code,
    required this.type,
    required this.titleKey,
    required this.firstAtWeeks,
    this.intervalDays = 0,
    this.repeatCount = 1,
    this.annualAfterWeeks,
    this.annualIntervalDays = 365,
  });

  final String code;
  final PlanItemType type;
  final String titleKey;

  /// 首次应在出生后第几周。
  final int firstAtWeeks;

  /// 幼年期的重复间隔（天）。为 0 表示不重复。
  final int intervalDays;

  /// 幼年期重复次数。
  final int repeatCount;

  /// 达到该周龄后转为年度/周期重复。
  final int? annualAfterWeeks;

  /// 成年后的重复间隔（天）。
  final int annualIntervalDays;
}

/// 规则集契约。
abstract class ImmunizationRuleSet {
  const ImmunizationRuleSet();

  String get id;

  List<RuleSpec> specsFor(Species species);

  /// 生成从今天起的 [horizonDays] 天内的计划。
  ///
  /// [skipCodes] 用于建档问卷：用户勾了「已经打过」的疫苗，对应的 code
  /// 就不该再出现在建议排期里。粒度到 code（vaccine_core / vaccine_rabies），
  /// 比按 PlanItemType 过滤更准 —— 打过联苗不等于打过狂犬。
  ///
  /// 算法：
  /// 1. 幼年期项：按 firstAtWeeks + n × intervalDays 展开，取仍在未来的
  /// 2. 成年后项：从 annualAfterWeeks 起，按 annualIntervalDays 递推，
  ///    落在 horizon 内的产出
  List<PlannedEvent> buildPlan({
    required Species species,
    required DateTime birthday,
    required DateTime now,
    int horizonDays = 365,
    Set<String> skipCodes = const <String>{},
  }) {
    final specs = specsFor(species).where((s) => !skipCodes.contains(s.code));
    final horizon = now.add(Duration(days: horizonDays));
    final result = <PlannedEvent>[];

    for (final spec in specs) {
      final firstAt = birthday.add(Duration(days: spec.firstAtWeeks * 7));

      // 幼年期重复序列
      for (var i = 0; i < spec.repeatCount; i++) {
        final dueAt = firstAt.add(Duration(days: spec.intervalDays * i));
        if (dueAt.isAfter(now) && !dueAt.isAfter(horizon)) {
          result.add(PlannedEvent(
            code: spec.code,
            type: spec.type,
            titleKey: spec.titleKey,
            dueAt: dueAt,
            recurring: false,
          ));
        }
      }

      // 成年后的周期性重复
      final annualAfterWeeks = spec.annualAfterWeeks;
      if (annualAfterWeeks == null) continue;

      var dueAt = birthday.add(Duration(days: annualAfterWeeks * 7));
      if (spec.intervalDays > 0 && spec.repeatCount > 1) {
        dueAt = dueAt
            .add(Duration(days: spec.intervalDays * (spec.repeatCount - 1)));
      }
      if (dueAt.isBefore(now)) {
        dueAt = now;
      }

      var guard = 0;
      while (!dueAt.isAfter(horizon) && guard < 64) {
        dueAt = dueAt.add(Duration(days: spec.annualIntervalDays));
        if (dueAt.isAfter(now) && !dueAt.isAfter(horizon)) {
          result.add(PlannedEvent(
            code: spec.code,
            type: spec.type,
            titleKey: spec.titleKey,
            dueAt: dueAt,
            recurring: true,
          ));
        }
        guard++;
      }
    }

    result.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return result;
  }
}

/// 中国大陆常见规程。
class CnRuleSet extends ImmunizationRuleSet {
  const CnRuleSet();

  @override
  String get id => 'cn';

  @override
  List<RuleSpec> specsFor(Species species) => switch (species) {
        Species.dog => const [
            RuleSpec(
              code: 'vaccine_core',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.core',
              firstAtWeeks: 7,
              intervalDays: 21,
              repeatCount: 3,
              annualAfterWeeks: 78,
            ),
            RuleSpec(
              code: 'vaccine_rabies',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.rabies',
              firstAtWeeks: 16,
              annualAfterWeeks: 78,
            ),
            RuleSpec(
              code: 'deworm_internal',
              type: PlanItemType.dewormInternal,
              titleKey: 'plan.deworm.internal',
              firstAtWeeks: 4,
              intervalDays: 30,
              repeatCount: 6,
              annualAfterWeeks: 52,
              annualIntervalDays: 90,
            ),
            RuleSpec(
              code: 'deworm_external',
              type: PlanItemType.dewormExternal,
              titleKey: 'plan.deworm.external',
              firstAtWeeks: 8,
              annualAfterWeeks: 26,
              annualIntervalDays: 30,
            ),
            RuleSpec(
              code: 'checkup',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.annual',
              firstAtWeeks: 52,
              annualAfterWeeks: 52,
            ),
            RuleSpec(
              code: 'checkup_senior',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.senior',
              firstAtWeeks: 364,
              annualAfterWeeks: 364,
              annualIntervalDays: 182,
            ),
          ],
        Species.cat => const [
            RuleSpec(
              code: 'vaccine_core',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.core',
              firstAtWeeks: 9,
              intervalDays: 21,
              repeatCount: 3,
              annualAfterWeeks: 78,
            ),
            RuleSpec(
              code: 'vaccine_rabies',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.rabies',
              firstAtWeeks: 14,
              annualAfterWeeks: 78,
            ),
            RuleSpec(
              code: 'deworm_internal',
              type: PlanItemType.dewormInternal,
              titleKey: 'plan.deworm.internal',
              firstAtWeeks: 4,
              intervalDays: 30,
              repeatCount: 6,
              annualAfterWeeks: 52,
              annualIntervalDays: 90,
            ),
            RuleSpec(
              code: 'deworm_external',
              type: PlanItemType.dewormExternal,
              titleKey: 'plan.deworm.external',
              firstAtWeeks: 8,
              annualAfterWeeks: 26,
              annualIntervalDays: 30,
            ),
            RuleSpec(
              code: 'checkup',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.annual',
              firstAtWeeks: 52,
              annualAfterWeeks: 52,
            ),
            RuleSpec(
              code: 'checkup_senior',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.senior',
              firstAtWeeks: 364,
              annualAfterWeeks: 364,
              annualIntervalDays: 182,
            ),
          ],
        Species.other => const [
            RuleSpec(
              code: 'checkup',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.annual',
              firstAtWeeks: 52,
              annualAfterWeeks: 52,
            ),
          ],
      };
}

/// 海外规程（参考 AAHA / WSAVA 指南的常见做法）。
///
/// 主要差异：
/// - 犬首针更早（6 周），狂犬按多数地区法规在 12 周
/// - 强调心丝虫按月预防
/// - 成年加强间隔通常 1–3 年，这里保守取 1 年
class IntlRuleSet extends ImmunizationRuleSet {
  const IntlRuleSet();

  @override
  String get id => 'intl';

  @override
  List<RuleSpec> specsFor(Species species) => switch (species) {
        Species.dog => const [
            RuleSpec(
              code: 'vaccine_core',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.core',
              firstAtWeeks: 6,
              intervalDays: 21,
              repeatCount: 3,
              annualAfterWeeks: 78,
            ),
            RuleSpec(
              code: 'vaccine_rabies',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.rabies',
              firstAtWeeks: 12,
              annualAfterWeeks: 64,
              annualIntervalDays: 365,
            ),
            RuleSpec(
              code: 'deworm_internal',
              type: PlanItemType.dewormInternal,
              titleKey: 'plan.deworm.internal',
              firstAtWeeks: 2,
              intervalDays: 14,
              repeatCount: 8,
              annualAfterWeeks: 26,
              annualIntervalDays: 30,
            ),
            RuleSpec(
              code: 'deworm_external',
              type: PlanItemType.dewormExternal,
              titleKey: 'plan.deworm.external',
              firstAtWeeks: 8,
              annualAfterWeeks: 12,
              annualIntervalDays: 30,
            ),
            RuleSpec(
              code: 'checkup',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.annual',
              firstAtWeeks: 52,
              annualAfterWeeks: 52,
            ),
            RuleSpec(
              code: 'checkup_senior',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.senior',
              firstAtWeeks: 364,
              annualAfterWeeks: 364,
              annualIntervalDays: 182,
            ),
          ],
        Species.cat => const [
            RuleSpec(
              code: 'vaccine_core',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.core',
              firstAtWeeks: 6,
              intervalDays: 21,
              repeatCount: 3,
              annualAfterWeeks: 78,
            ),
            RuleSpec(
              code: 'vaccine_rabies',
              type: PlanItemType.vaccine,
              titleKey: 'plan.vaccine.rabies',
              firstAtWeeks: 12,
              annualAfterWeeks: 64,
            ),
            RuleSpec(
              code: 'deworm_internal',
              type: PlanItemType.dewormInternal,
              titleKey: 'plan.deworm.internal',
              firstAtWeeks: 3,
              intervalDays: 14,
              repeatCount: 6,
              annualAfterWeeks: 26,
              annualIntervalDays: 30,
            ),
            RuleSpec(
              code: 'deworm_external',
              type: PlanItemType.dewormExternal,
              titleKey: 'plan.deworm.external',
              firstAtWeeks: 8,
              annualAfterWeeks: 12,
              annualIntervalDays: 30,
            ),
            RuleSpec(
              code: 'checkup',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.annual',
              firstAtWeeks: 52,
              annualAfterWeeks: 52,
            ),
          ],
        Species.other => const [
            RuleSpec(
              code: 'checkup',
              type: PlanItemType.checkup,
              titleKey: 'plan.checkup.annual',
              firstAtWeeks: 52,
              annualAfterWeeks: 52,
            ),
          ],
      };
}

/// 工厂：按区域返回规则集。
ImmunizationRuleSet ruleSetFor([Region? region]) {
  final r = region ?? AppRegion.current;
  return switch (r) {
    Region.cn => const CnRuleSet(),
    Region.intl => const IntlRuleSet(),
  };
}
