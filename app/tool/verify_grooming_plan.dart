// ignore_for_file: avoid_print
/// 离线真跑「洗澡美容」排期。
///
/// 为什么需要它：`immunization.dart` 只依赖 core（region / species），是纯
/// Dart —— 本机跑不了 `flutter test`（非提权必踩命名管道 231），所以用 dart
/// 直接执行，把「排期算得对不对」拿在手里，而不是等装到手机上才看。
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_grooming_plan.dart
///
/// 它**不替代**正式用例；这是无 Flutter 环境下的兜底跑法。
library;

import 'package:pet_app/domain/immunization.dart';

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

List<PlannedEvent> _grooming(List<PlannedEvent> all) =>
    all.where((e) => e.type == PlanItemType.grooming).toList();

void main() {
  final now = DateTime(2026, 10, 1, 9, 0);
  final threeYearsAgo = now.subtract(const Duration(days: 365 * 3));

  // ---- 1) 成年犬：应排在约 30 天后，一年约 12 次 ----
  final dogPlan = const CnRuleSet()
      .buildPlan(species: Species.dog, birthday: threeYearsAgo, now: now);
  final dog = _grooming(dogPlan);

  check(dog.isNotEmpty, '成年犬应生成洗澡排期');
  if (dog.isNotEmpty) {
    final gap = dog.first.dueAt.difference(now).inDays;
    check(gap >= 28 && gap <= 31, '成年犬首次洗澡应约 30 天后（实际 $gap 天）');
    check(dog.first.code == 'grooming_bath', '洗澡项 code 应为 grooming_bath');
    check(dog.first.titleKey == 'plan.grooming', '文案 key 应为 plan.grooming');
    check(dog.first.recurring, '洗澡应是周期性项');
    check(
      dog.every((e) => e.dueAt.isAfter(now)),
      '洗澡排期不应出现已过去的日期',
    );
  }
  check(
    dog.length >= 11 && dog.length <= 13,
    '一年内狗洗澡约 12 次（实际 ${dog.length}）',
  );
  final dogTimes = dog.map((e) => e.dueAt.millisecondsSinceEpoch).toList();
  check(dogTimes.toSet().length == dogTimes.length, '洗澡排期不应有重复日期');

  // ---- 2) 成年猫：60 天一次，一年约 6 次 ----
  final catPlan = const CnRuleSet()
      .buildPlan(species: Species.cat, birthday: threeYearsAgo, now: now);
  final cat = _grooming(catPlan);
  check(cat.isNotEmpty, '成年猫应生成洗澡排期');
  check(
    cat.length >= 5 && cat.length <= 7,
    '一年内猫洗澡约 6 次（实际 ${cat.length}）',
  );
  check(
    cat.length < dog.length,
    '猫的洗澡频次应低于狗（猫 ${cat.length} / 狗 ${dog.length}）',
  );

  // ---- 3) 幼犬 7 周龄：首次洗澡应排到 8 周龄（约 7 天后）----
  final puppyPlan = const CnRuleSet().buildPlan(
    species: Species.dog,
    birthday: now.subtract(const Duration(days: 49)),
    now: now,
  );
  final puppy = _grooming(puppyPlan);
  check(puppy.isNotEmpty, '幼犬应排到首次洗澡');
  if (puppy.isNotEmpty) {
    final gap = puppy.first.dueAt.difference(now).inDays;
    check(gap >= 6 && gap <= 8, '7 周龄幼犬首次洗澡应在 8 周龄（实际 $gap 天后）');
  }

  // ---- 4) 其他物种不排：兔/鸟的洗澡需求差异太大，硬给排期是错的 ----
  final otherPlan = const CnRuleSet().buildPlan(
    species: Species.other,
    birthday: threeYearsAgo,
    now: now,
  );
  check(_grooming(otherPlan).isEmpty, '其他物种不应排洗澡');

  // ---- 5) 海外规则集同样要有 ----
  final intlDogPlan = const IntlRuleSet()
      .buildPlan(species: Species.dog, birthday: threeYearsAgo, now: now);
  check(_grooming(intlDogPlan).isNotEmpty, '海外规则集的狗也应有洗澡排期');
  final intlCatPlan = const IntlRuleSet()
      .buildPlan(species: Species.cat, birthday: threeYearsAgo, now: now);
  check(_grooming(intlCatPlan).isNotEmpty, '海外规则集的猫也应有洗澡排期');

  // ---- 6) 类型与 wire 名对齐（存库 / 同步都靠它）----
  check(PlanItemType.grooming.wireName == 'grooming', 'wire 名应为 grooming');

  // ---- 7) 不影响原有项：疫苗 / 驱虫 / 体检都还在 ----
  check(
    dogPlan.any((e) => e.type == PlanItemType.vaccine),
    '加了洗澡不应影响疫苗排期',
  );
  check(
    dogPlan.any((e) => e.type == PlanItemType.dewormInternal),
    '加了洗澡不应影响体内驱虫排期',
  );

  print('');
  print('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) {
    throw StateError('洗澡排期验证失败 $_failed 项');
  }
}
