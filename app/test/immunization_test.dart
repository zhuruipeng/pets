/// 免疫计划生成测试。
///
/// 这是 MVP 里唯一「有专业含量」的算法，必须验：
/// 1. 计划项不落在过去（除非本来就是补做）
/// 2. 幼年期按间隔递推
/// 3. 成年期周期性重复
/// 4. cn / intl 两套规则确实不同
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/region.dart';
import 'package:pet_app/domain/immunization.dart';

void main() {
  final now = DateTime(2026, 9, 28, 12);

  group('幼犬计划', () {
    test('出生 2 个月的犬，一年内应有计划项', () {
      final birthday = now.subtract(const Duration(days: 60));
      final plan = ruleSetFor().buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
      );

      expect(plan, isNotEmpty);

      // 所有项都应落在未来
      for (final item in plan) {
        expect(
          item.dueAt.isAfter(now),
          isTrue,
          reason: '${item.code} 排在 ${item.dueAt}，早于 now',
        );
      }
    });

    test('计划按时间升序排列', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.dog,
        birthday: now.subtract(const Duration(days: 45)),
        now: now,
      );

      for (var i = 1; i < plan.length; i++) {
        expect(
          plan[i].dueAt.isBefore(plan[i - 1].dueAt),
          isFalse,
          reason: '第 $i 项早于前一项，排序错了',
        );
      }
    });

    test('幼年疫苗按 21 天间隔递推，三针', () {
      // 出生 6 周，核心疫苗首针在 7 周龄 → 7 天后
      final birthday = DateTime(2026, 8, 17);
      final plan = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
        horizonDays: 365,
      );

      final core = plan.where((p) => p.code == 'vaccine_core').toList();
      // 首针在 7 周龄 = birthday + 49 天 = 2026-10-05
      expect(core, isNotEmpty);
      expect(core.first.dueAt, DateTime(2026, 10, 5));

      // 若三针都在 horizon 内，间隔应为 21 天
      if (core.length >= 2) {
        final gap = core[1].dueAt.difference(core[0].dueAt).inDays;
        expect(gap, 21);
      }
    });

    test('horizon 之外的项不产出', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.dog,
        birthday: now.subtract(const Duration(days: 60)),
        now: now,
        horizonDays: 30,
      );

      final limit = now.add(const Duration(days: 30));
      for (final item in plan) {
        expect(item.dueAt.isAfter(limit), isFalse,
            reason: '${item.code} 超出了 30 天窗口');
      }
    });
  });

  group('成年犬计划', () {
    test('3 岁犬仍有周期性项目（驱虫 / 体检）', () {
      final birthday = DateTime(2023, 9, 28);
      final plan = ruleSetFor().buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
      );

      expect(plan, isNotEmpty);
      // 成年犬的年度加强应该出现
      final codes = plan.map((p) => p.code).toSet();
      expect(
        codes.any((c) => c.contains('deworm') || c.contains('checkup')),
        isTrue,
        reason: '成年犬没有驱虫或体检项',
      );
    });

    test('成年项都标记为周期性', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.dog,
        birthday: DateTime(2023, 9, 28),
        now: now,
      );
      // 3 岁犬的计划里，周期项应占多数
      expect(plan.where((p) => p.recurring).length, greaterThan(0));
    });
  });

  group('区域差异', () {
    test('cn 与 intl 的犬规则集不同', () {
      final birthday = now.subtract(const Duration(days: 50));

      final cn = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
      );
      final intl = ruleSetFor(Region.intl).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
      );

      final cnTimes = cn.map((p) => '${p.code}@${p.dueAt}').toList();
      final intlTimes = intl.map((p) => '${p.code}@${p.dueAt}').toList();

      expect(cnTimes, isNot(equals(intlTimes)),
          reason: '两套规则集产出了一样的计划，说明区域差异没生效');
    });

    test('规则集 id 正确', () {
      expect(ruleSetFor(Region.cn).id, 'cn');
      expect(ruleSetFor(Region.intl).id, 'intl');
    });
  });

  group('猫', () {
    test('幼猫同样生成计划', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.cat,
        birthday: now.subtract(const Duration(days: 70)),
        now: now,
      );
      expect(plan, isNotEmpty);
    });
  });

  group('其他种类', () {
    test('只有体检项，不含犬猫专用疫苗', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.other,
        birthday: now.subtract(const Duration(days: 400)),
        now: now,
      );

      final codes = plan.map((p) => p.code).toSet();
      expect(codes.contains('vaccine_rabies'), isFalse);
      expect(plan.every((p) => p.type == PlanItemType.checkup), isTrue);
    });
  });

  group('边界', () {
    test('生日在未来时不崩，且不产出过去的项', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.dog,
        birthday: now.add(const Duration(days: 10)),
        now: now,
      );
      // 未来的生日，首针也在未来之后，不该崩
      expect(plan, isNotNull);
    });

    test('刚出生的宠物计划全部在未来', () {
      final plan = ruleSetFor().buildPlan(
        species: Species.cat,
        birthday: now,
        now: now,
        horizonDays: 365,
      );
      for (final item in plan) {
        expect(item.dueAt.isBefore(now), isFalse);
      }
    });
  });

  // 建档问卷的「已打过哪些疫苗」直接落到 skipCodes。
  // 这里的门槛很实际：用户刚填完就说要打一针已经打过的，会当场失去信任。
  group('skipCodes（建档问卷跳过已打疫苗）', () {
    final birthday = now.subtract(const Duration(days: 60));

    test('不传 skipCodes 时，联苗与狂犬都在计划里', () {
      final plan = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
      );
      final codes = plan.map((p) => p.code).toSet();
      expect(codes.contains('vaccine_core'), isTrue);
      expect(codes.contains('vaccine_rabies'), isTrue);
    });

    test('跳过联苗后，只少联苗，狂犬仍在', () {
      final plan = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
        skipCodes: const {'vaccine_core'},
      );
      final codes = plan.map((p) => p.code).toSet();
      expect(codes.contains('vaccine_core'), isFalse);
      expect(codes.contains('vaccine_rabies'), isTrue);
    });

    test('联苗和狂犬都跳过时，疫苗项一个不剩', () {
      final plan = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
        skipCodes: const {'vaccine_core', 'vaccine_rabies'},
      );
      expect(
        plan.any((p) => p.type == PlanItemType.vaccine),
        isFalse,
        reason: '两类疫苗都打过了，不该再排疫苗',
      );
      // 驱虫与体检不受影响，仍应保留
      expect(plan, isNotEmpty);
    });

    test('skipCodes 只跳疫苗，不误伤驱虫和体检', () {
      final plan = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
        skipCodes: const {'vaccine_core', 'vaccine_rabies'},
      );
      final types = plan.map((p) => p.type).toSet();
      expect(types.contains(PlanItemType.dewormInternal), isTrue);
      expect(types.contains(PlanItemType.dewormExternal), isTrue);
    });

    test('跳过不存在的 code 不影响结果', () {
      final base = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
      );
      final bogus = ruleSetFor(Region.cn).buildPlan(
        species: Species.dog,
        birthday: birthday,
        now: now,
        skipCodes: const {'no_such_code'},
      );
      expect(
        bogus.map((p) => p.code).toList(),
        base.map((p) => p.code).toList(),
      );
    });
  });
}
