/// 界面冒烟测试 —— 不需要设备，纯 widget 层。
///
/// 跑通这条说明：四 Tab 能构建、区域配置能注入、空态能正确展示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/l10n.dart';
import 'package:pet_app/core/region.dart';
import 'package:pet_app/core/reminder_text.dart';
import 'package:pet_app/core/traits.dart';
import 'package:pet_app/data/models.dart';
import 'package:pet_app/providers.dart';
import 'package:pet_app/services/app_update_service.dart';
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
        // 预防台账（M3.4）：分类名 + 上次/下次 + 快捷记录
        'profile.section.quick',
        'profile.care.vaccine',
        'profile.care.dewormInternal',
        'profile.care.dewormExternal',
        'profile.care.checkup',
        'profile.care.grooming',
        'profile.care.last',
        'profile.care.lastNone',
        'profile.care.next',
        'profile.care.unscheduled',
        'profile.care.off',
        'profile.care.log',
        'profile.ledger.hint',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('文档原件文案都已翻译', () {
      for (final k in [
        'detail.documents',
        'detail.documents.empty',
        'detail.documents.add',
        'detail.documents.delete',
        'profile.section.documents',
        'doc.pickFailed',
        'doc.added',
        'doc.unknownType',
        'doc.localOnly',
        // {n} 是上限 MB 数，漏了就是一句「文件超过 MB」
        'doc.tooLarge',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      expect(
        L.tp('doc.tooLarge', {'n': 20}),
        isNot(contains('{n}')),
        reason: 'doc.tooLarge 的 {n} 没被替换',
      );
    });

    test('费用页签文案都已翻译', () {
      for (final k in [
        'profile.tab.expense',
        'expense.title',
        'expense.add',
        'expense.thisMonth',
        'expense.allTime',
        'expense.avgMonth',
        'expense.trend',
        'expense.byCategory',
        'expense.recent',
        'expense.empty.hint',
        'expense.amount',
        'expense.amountRequired',
        'expense.saved',
        'expense.deleted',
        // 八个分类：库里存 wire 名，展示时才翻，少一条界面上就是裸 key
        'expense.category.food',
        'expense.category.medical',
        'expense.category.vaccine',
        'expense.category.deworm',
        'expense.category.grooming',
        'expense.category.supply',
        'expense.category.boarding',
        'expense.category.other',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
    });

    test('台账的「上次 / 下次」占位符能被替换', () {
      // 这两条是多占位符的：漏一个就是一个字面量 {v} 摆在界面上。
      expect(L.tp('profile.care.last', {'v': '3 天前'}), contains('3 天前'));
      expect(L.tp('profile.care.next', {'v': '还有 5 天'}), contains('还有 5 天'));
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

    test('档案编辑与个性特点文案都已翻译', () {
      for (final k in [
        'editPet.title',
        'editPet.name',
        'editPet.nameEmpty',
        'editPet.breed',
        'editPet.breedHint',
        'editPet.birthdayPick',
        'editPet.birthdayEstimated',
        'editPet.weightBaseline',
        'editPet.weightBaselineHint',
        'editPet.save',
        'editPet.saved',
        'avatar.title',
        'avatar.camera',
        'avatar.gallery',
        'avatar.remove',
        'avatar.failed',
        'profile.traits.empty',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      // 每个预设标签都要有中文/英文文案，否则会退化成显示 code。
      for (final code in kPersonalityCodes) {
        expect(
          personalityLabel(code),
          isNot(code),
          reason: '标签 $code 没有翻译',
        );
      }
    });

    test('自动更新文案都已翻译', () {
      for (final k in [
        'update.title',
        'update.current',
        'update.latest',
        'update.notes',
        'update.now',
        'update.later',
        'update.mustTitle',
        'update.mustBody',
        'update.downloading',
        'update.installing',
        'update.failed',
        'update.upToDate',
        'update.check',
        'update.checkFailed',
        'update.permissionHint',
        'update.noApk',
        'me.version',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      expect(
        L.tp('update.downloading', {'percent': 42}),
        contains('42'),
      );
    });

    test('档案页两个新页签的文案都已翻译', () {
      for (final k in [
        'profile.records.empty',
        'profile.records.emptyHint',
        'profile.memory.empty',
        'profile.memory.emptyHint',
        'profile.memory.add',
        'profile.memory.added',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      expect(L.tp('profile.memory.count', {'n': 3}), contains('3'));
    });

    test('相册照片在记录行上显示成「照片」而不是「笔记」', () {
      // 回忆页加的照片 = 一条 payload.kind=photo 的 note 记录，
      // 记录行靠这个标记换名字（库里不存 i18n 文本）。
      final photo = PetRecord(
        id: 'r1',
        petId: 'p1',
        type: RecordType.note,
        recordedAt: DateTime(2026, 9, 30),
        createdBy: 'u1',
        createdAt: DateTime(2026, 9, 30),
        updatedAt: DateTime(2026, 9, 30),
        payload: const {'kind': 'photo'},
      );
      expect(recordPayloadSummary(photo), L.t('record.kind.photo'));

      // 普通笔记不受影响 —— 不能把所有 note 都改叫照片。
      final plain = PetRecord(
        id: 'r2',
        petId: 'p1',
        type: RecordType.note,
        recordedAt: DateTime(2026, 9, 30),
        createdBy: 'u1',
        createdAt: DateTime(2026, 9, 30),
        updatedAt: DateTime(2026, 9, 30),
        payload: const {},
      );
      expect(recordPayloadSummary(plain), isEmpty);
    });

    test('联系方式与走失卡片文案都已翻译', () {
      for (final k in [
        'contact.title',
        'contact.hint',
        'contact.phone',
        'contact.email',
        'contact.wechat',
        'contact.note',
        'contact.noteHint',
        'contact.empty',
        'contact.save',
        'contact.saved',
        'contact.missing',
        'lost.title',
        'lost.action',
        'lost.preview',
        'lost.share',
        'lost.lastSeen',
        'lost.unknownWhere',
        'lost.since',
        'lost.contactMe',
        'lost.noContact',
        'lost.shareSubject',
        'lost.failed',
        'walk.detail',
        'walk.track',
        'walk.noTrack',
        'walk.shareText',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      // 带占位符的两条要真的替换掉
      expect(L.tp('lost.since', {'n': 3}), contains('3'));
      expect(L.tp('lost.since', {'n': 3}), isNot(contains('{n}')));
    });

    test('手动提醒相关文案都已翻译', () {      for (final k in [
        'reminder.add',
        'reminder.new',
        'reminder.edit',
        'reminder.type',
        'reminder.name',
        'reminder.nameHint',
        'reminder.repeat',
        'reminder.repeat.once',
        'reminder.repeat.custom',
        'reminder.repeat.monthly',
        'reminder.repeat.quarterly',
        'reminder.repeat.halfYearly',
        'reminder.repeat.yearly',
        'reminder.repeat.everyNDays',
        'reminder.days',
        'reminder.firstAt',
        'reminder.firstAtHint',
        'reminder.save',
        'reminder.saved',
        'reminder.deleted',
        'reminder.delete',
        'reminder.deleteConfirm',
        'reminder.deleteConfirm.hint',
        'reminder.source.auto',
        'reminder.source.manual',
        'reminder.due.unknown',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      // 每种可手动新建的类型都要有显示名，否则界面会露出内部串。
      for (final type in kManualReminderTypes) {
        expect(
          reminderTypeLabel(type),
          isNot(type),
          reason: '提醒类型 $type 没有翻译',
        );
      }
    });

    test('登录、同步与共养文案都已翻译', () {
      for (final k in [
        'auth.title',
        'auth.why',
        'auth.channel.sms',
        'auth.channel.email',
        'auth.target.phone',
        'auth.target.email',
        'auth.target.required',
        'auth.sendCode',
        'auth.resendIn',
        'auth.code',
        'auth.codeHint',
        'auth.codeRequired',
        'auth.devCode',
        'auth.submit',
        'auth.sent',
        'auth.failed',
        'auth.notLoggedIn',
        'auth.notLoggedInHint',
        'auth.account',
        'auth.logout',
        'auth.logoutConfirm',
        'auth.logoutHint',
        'auth.loggedOut',
        'sync.title',
        'sync.now',
        'sync.never',
        'sync.lastAt',
        'sync.pending',
        'sync.upToDate',
        'sync.syncing',
        'sync.failed',
        'sync.done',
        'members.invite',
        'members.inviteHint',
        'members.target',
        'members.role',
        'members.role.owner',
        'members.role.editor',
        'members.role.viewer',
        'members.status.pending',
        'members.invite.sent',
        'members.invite.failed',
        'members.notRegistered',
        'members.remove',
        'members.removeConfirm',
        'members.removeHint',
        'members.removed',
        'members.needLogin',
        'members.invites.title',
        'members.invites.accept',
        'members.invites.accepted',
        'members.me',
        'me.privacy',
        'me.terms',
      ]) {
        expect(L.t(k), isNot(k), reason: '$k 没有翻译');
      }
      // 三档角色都得有文案，否则权限说明会露出 role.editor 这种串。
      for (final r in const ['owner', 'editor', 'viewer']) {
        expect(L.t('members.role.$r'), isNot('members.role.$r'));
      }
      // 带占位符的三条
      expect(L.tp('auth.resendIn', {'n': 30}), contains('30'));
      expect(L.tp('sync.lastAt', {'time': '10-01 09:00'}), contains('10-01'));
      expect(L.tp('sync.pending', {'n': 5}), contains('5'));
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

    test('knownPersonalities 过滤掉已废弃的 code', () {
      // 老数据里可能有历史标签：展示层只认预设内的，
      // 否则档案页会冒出一个看不懂的灰标签。
      expect(
        knownPersonalities(['friendly', 'legacy_tag', 'calm']),
        ['friendly', 'calm'],
      );
      expect(knownPersonalities(const []), isEmpty);
    });

    test('reminderTitleFrom：系统 key 翻译、自建名字原样、空值用类型名', () {
      // 系统按免疫规程生成的提醒存的是 i18n key。
      expect(
        reminderTitleFrom('plan.vaccine.core', 'vaccine'),
        L.t('plan.vaccine.core'),
      );
      // 用户自己起的名字必须原样显示 —— 早先这里会被回落到 type，
      // 界面上出现 'medication' 这种内部串。
      expect(reminderTitleFrom('剪指甲', 'medication'), '剪指甲');
      // 没起名就显示类型名。
      expect(reminderTitleFrom('', 'checkup'), L.t('reminder.type.checkup'));
      expect(reminderTitleFrom('   ', 'checkup'), L.t('reminder.type.checkup'));
    });

    test('提醒类型图标认得库里存的下划线式类型', () {
      // 库里存的是 deworm_internal（PlanItemType.wireName），
      // 早年只匹配驼峰式，导致驱虫/体检一律显示默认铃铛。
      expect(reminderTypeIcon('deworm_internal'),
          isNot(reminderTypeIcon('unknown_type')));
      expect(reminderTypeIcon('deworm_external'),
          isNot(reminderTypeIcon('unknown_type')));
      expect(reminderTypeIcon('checkup'),
          isNot(reminderTypeIcon('unknown_type')));
    });
  });

  group('文档原件 · 展示层', () {
    RecordAttachment att({
      String? fileName,
      String? localPath,
      int? sizeBytes,
    }) =>
        RecordAttachment(
          id: 'a1',
          recordId: 'r1',
          kind: 'document',
          localPath: localPath ?? '/data/x/abcdef.pdf',
          fileName: fileName,
          sizeBytes: sizeBytes,
          createdAt: DateTime(2026, 9, 29),
        );

    test('展示名优先原始文件名，没有才退回路径末段', () {
      // 用户认的是「狂犬疫苗本.pdf」，换成 doc-<uuid>.pdf 之后
      // 分享给兽医时对方那边也是一串乱码名。
      expect(attachmentTitle(att(fileName: '狂犬疫苗本.pdf')), '狂犬疫苗本.pdf');
      expect(attachmentTitle(att(fileName: '  ')), 'abcdef.pdf');
      expect(attachmentTitle(att(localPath: 'C:\\x\\y\\lab.jpg')), 'lab.jpg');
      expect(attachmentTitle(att(fileName: '', localPath: '')), '');
    });

    test('文件大小：KB 取整，MB 一位小数', () {
      expect(fileSizeLabel(512), '512 B');
      expect(fileSizeLabel(2048), '2 KB');
      expect(fileSizeLabel(3 * 1024 * 1024), '3.0 MB');
      // null / 0 给空串，调用方据此不渲染这一行 —— 不显示「0 B」。
      expect(fileSizeLabel(null), '');
      expect(fileSizeLabel(0), '');
    });

    test('扩展名 → MIME，认不出的落 octet-stream', () {
      expect(mimeOfExt('pdf'), 'application/pdf');
      expect(mimeOfExt('.PDF'), 'application/pdf', reason: '大小写与点号都要吃');
      expect(mimeOfExt('jpg'), 'image/jpeg');
      expect(mimeOfExt('docx'), startsWith('application/'));
      expect(mimeOfExt('exe'), 'application/octet-stream');
      expect(mimeOfExt(null), 'application/octet-stream');
    });
  });

  group('版本比较', () {
    test('按数字段比大小，后缀不参与', () {
      expect(AppUpdateService.compareVersion('0.2.0', '0.1.9') > 0, isTrue);
      expect(AppUpdateService.compareVersion('0.1.0', '0.1.0'), 0);
      expect(AppUpdateService.compareVersion('1.0.0-beta', '0.9.9') > 0, isTrue);
    });

    test('清单缺字段或格式不对时解析失败，而不是抛异常', () {
      expect(UpdateManifest.tryParse(null), isNull);
      expect(UpdateManifest.tryParse({'version': '0.2.0'}), isNull); // 缺 build/url
      expect(UpdateManifest.tryParse({'version': '', 'build': 2, 'url': 'x'}), isNull);

      final ok = UpdateManifest.tryParse({
        'version': '0.2.0',
        'build': 2,
        'url': 'https://example.com/app.apk',
        'notes': '修了几个问题',
        'minBuild': 2,
      });
      expect(ok, isNotNull);
      expect(ok!.build, 2);
      expect(ok.minBuild, 2);
    });
  });
}
