/// 界面冒烟测试 —— 不需要设备，纯 widget 层。
///
/// 跑通这条说明：四 Tab 能构建、区域配置能注入、空态能正确展示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/core/region.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/ui/me_screen.dart';
import 'package:pet_app/ui/today_screen.dart';
import 'package:pet_app/ui/widgets.dart';

/// 空宠物列表的替身，避开 sqflite 平台通道。
class _EmptyPets extends PetsNotifier {
  @override
  Future<List<Pet>> build() async => const [];
}

/// 空待办列表的替身。
class _EmptyUpcoming extends UpcomingRemindersNotifier {
  @override
  Future<List<Reminder>> build() async => const [];
}

void main() {
  group('区域配置', () {
    test('AppRegion 由编译期注入，且 cn/intl 互斥', () {
      expect(AppRegion.isCn, isNot(AppRegion.isIntl));
    });

    test('中国区不渲染地图、需展示备案号', () {
      const cn = Region.cn;
      expect(cn.mapRenderingEnabled, isFalse);
      expect(cn.requiresIcpDisplay, isTrue);
      expect(cn.geocoderVendor, 'amap');
      expect(cn.immunizationRuleSet, 'cn');
    });

    test('海外渲染地图、用 Mapbox', () {
      const intl = Region.intl;
      expect(intl.mapRenderingEnabled, isTrue);
      expect(intl.requiresIcpDisplay, isFalse);
      expect(intl.geocoderVendor, 'mapbox');
      expect(intl.immunizationRuleSet, 'intl');
    });

    test('两个区域的后端地址不同 —— 数据不出境的前提', () {
      expect(Region.cn.apiBaseUrl, isNot(Region.intl.apiBaseUrl));
    });
  });

  group('今日页空态', () {
    testWidgets('没有宠物时展示引导，并能找到添加按钮', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            petsProvider.overrideWith(_EmptyPets.new),
            // 待办列表也要给出空值，否则会去摸数据库。
            upcomingRemindersProvider.overrideWith(_EmptyUpcoming.new),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TodayScreen()),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text(L.t('profile.empty.title')), findsOneWidget);
      expect(find.byType(FilledButton), findsWidgets);
    });
  });

  group('我的页自检面板', () {
    testWidgets('展示当前区域的四项关键配置', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: MeScreen())),
        ),
      );
      await tester.pumpAndSettle();

      const region = AppRegion.current;

      // 值带前缀，避免同名值（比如区域 intl 与规则集 intl）互相混淆
      expect(find.text('region:${region.name}'), findsOneWidget);
      expect(find.text('vendor:${region.geocoderVendor}'), findsOneWidget);
      expect(find.text('rules:${region.immunizationRuleSet}'), findsOneWidget);
      expect(
        find.text(region.mapRenderingEnabled ? 'on' : 'off'),
        findsOneWidget,
      );
    });
  });

  group('文案表', () {
    test('缺 key 时回落到 key 本身，不抛异常', () {
      expect(L.t('this.key.does.not.exist'), 'this.key.does.not.exist');
    });

    // 中英文必须一起开发：加一条中文就得加一条英文。
    // t() 在 zh 缺 key 时会静默回落到 en，运行期根本看不出来，
    // 所以这条断言不能省 —— 它是「双语同步」这条约定的唯一守门人。
    test('中英文文案表完全对齐', () {
      final diff = L.tableDiff();
      expect(diff.onlyZh, isEmpty, reason: '这些键只有中文：${diff.onlyZh}');
      expect(diff.onlyEn, isEmpty, reason: '这些键只有英文：${diff.onlyEn}');
    });

    test('分类型快速记录文案都已翻译', () {
      for (final k in [
        'addRecord.weight.last',
        'addRecord.med.name',
        'addRecord.med.nameRequired',
        'addRecord.med.dose',
        'addRecord.med.route',
        'addRecord.med.route.oral',
        'addRecord.med.route.topical',
        'addRecord.med.route.injection',
        'addRecord.feed.kind',
        'addRecord.feed.kind.dry',
        'addRecord.feed.kind.wet',
        'addRecord.feed.kind.treat',
        'addRecord.feed.brand',
        'addRecord.feed.grams',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('档案健康页文案都已翻译', () {
      for (final k in [
        'profile.section.preventive',
        'profile.preventive.empty',
        'profile.section.medical',
        'profile.medical.empty',
        'profile.allergy.empty',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('四个 Tab 文案都已翻译', () {
      for (final k in [
        'tab.home',
        'tab.records',
        'tab.profile',
        'tab.me',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('今日页新增文案都已翻译', () {
      for (final k in [
        'home.greetingMorning',
        'home.greetingAfternoon',
        'home.greetingEvening',
        'home.subtitle',
        'home.subtitleEmpty',
        'home.lastRecord',
        'home.lastRecord.today',
        'home.todoEmpty',
        'home.switchPet',
        'home.weekOverview',
        'home.weekWalks',
        'home.weekRecords',
        'home.weekWeight',
        'home.vsLast',
        'home.steady',
        'profile.ageUnknown',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('遛狗结果页文案都已翻译', () {
      for (final k in [
        'walk.result',
        'walk.result.skip',
        'walk.mood',
        'walk.mood.great',
        'walk.mood.good',
        'walk.mood.tired',
        'walk.mood.anxious',
        'walk.mood.sick',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      // 五种心情都得有对应的文案和 emoji
      for (final code in kWalkMoods) {
        expect(L.t('walk.mood.$code'), isNot('walk.mood.$code'));
        expect(walkMoodEmoji(code), isNotEmpty);
      }
    });

    test('建档三步向导文案都已翻译', () {
      for (final k in [
        'addPet.title',
        'addPet.progress',
        'addPet.step1.title',
        'addPet.step1.hint',
        'addPet.step2.title',
        'addPet.step2.hint',
        'addPet.step3.title',
        'addPet.step3.hint',
        'addPet.name',
        'addPet.name.hint',
        'addPet.nameRequired',
        'addPet.species.dog',
        'addPet.species.cat',
        'addPet.species.other',
        'addPet.breed',
        'addPet.birthday',
        'addPet.birthday.hint',
        'addPet.birthday.estimated',
        'addPet.region.cn',
        'addPet.region.intl',
        'addPet.vaccine.none',
        'addPet.vaccine.core',
        'addPet.vaccine.coreRabies',
        'addPet.submit',
        'addPet.created',
        'action.back',
        'action.next',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }

      // 进度是多占位符的，容易被替换逻辑漏掉一个。
      expect(
        L.tp('addPet.progress', {'a': 2, 'b': 3}),
        allOf(contains('2'), contains('3')),
      );
    });

    test('提醒倒计时文案都已翻译', () {
      for (final k in ['due.tomorrow', 'due.inDays', 'due.overdueBy']) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('记录搜索与详情页文案都已翻译', () {
      for (final k in [
        'today.quickAdd',
        'today.quickAdd.more',
        'records.search.hint',
        'records.search.none',
        'detail.recordedAt',
        'detail.createdAt',
        'detail.backfilledHint',
        'detail.note',
        'detail.editTime',
        'detail.deleteConfirm',
        'detail.deleteConfirm.hint',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('占位符替换生效', () {
      final s = L.tp('timeline.daysAgo', {'n': 5});
      expect(s.contains('5'), isTrue);
      expect(s.contains('{n}'), isFalse);
    });
  });

  group('格式化工具', () {
    test('relativeDay：今天 / 昨天 / 更早', () {
      final now = DateTime.now();
      expect(relativeDay(now), L.t('timeline.today'));
      expect(
        relativeDay(now.subtract(const Duration(days: 1))),
        L.t('timeline.yesterday'),
      );
      final old = relativeDay(now.subtract(const Duration(days: 60)));
      expect(old.contains('-'), isTrue);
    });

    test('dueLabel：过期 / 今天 / 未来', () {
      final now = DateTime.now();
      expect(dueLabel(now), L.t('timeline.today'));
      expect(dueLabel(now.subtract(const Duration(days: 3))).contains('3'), isTrue);
      expect(dueLabel(now.add(const Duration(days: 3))).contains('3'), isTrue);
    });

    test('compactDateTime 补零', () {
      expect(compactDateTime(DateTime(2026, 3, 5, 9, 7)), '03-05 09:07');
    });

    test('recordTypeLabel 每个类型都有文案', () {
      for (final t in RecordType.values) {
        final label = recordTypeLabel(t);
        expect(label.isNotEmpty, isTrue);
        expect(label.startsWith('addRecord.'), isFalse, reason: '$t 缺文案');
      }
    });
  });
}
