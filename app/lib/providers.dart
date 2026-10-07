/// 状态层 —— Riverpod providers。
///
/// 分工：仓储只管数据，provider 管「谁在关心这些数据」。
/// UI 只读 provider，不直接摸仓储。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:uuid/uuid.dart';
import '../services/share_helper.dart';

import 'core/region.dart';
import 'core/l10n.dart';
import 'core/units.dart';
import 'data/db/app_database.dart';
import 'data/models.dart';
import 'data/repositories/attachment_repository.dart';
import 'data/repositories/expense_repository.dart';
import 'data/repositories/member_repository.dart';
import 'data/repositories/pet_repository.dart';
import 'data/repositories/record_repository.dart';
import 'data/repositories/reminder_repository.dart';
import 'data/repositories/user_repository.dart';
import 'data/repositories/walk_repository.dart';
import 'data/sync/secure_token_store.dart';
import 'data/sync/sync_api.dart';
import 'data/sync/sync_engine.dart';
import 'data/sync/unified_api.dart';
import 'domain/expense_stats.dart';
import 'domain/health_ledger.dart';
import 'domain/immunization.dart';
import 'domain/pet_report.dart';
import 'domain/medication_course.dart';
import 'domain/family_care.dart';
import 'domain/symptom_observation.dart';
import 'services/app_update_service.dart';
import 'services/report_renderer.dart';
import 'services/avatar_store.dart';
import 'services/notification_service.dart';
import 'services/backup_service.dart';

final backupServiceProvider = FutureProvider<BackupService>((ref) async {
  await ref.watch(dbReadyProvider.future);
  return BackupService(
    db: ref.read(databaseProvider).db,
    documentsPath: (await getApplicationDocumentsDirectory()).path,
  );
});

/// 未登录时的占位用户 id。登录后被 [UserRepository.adoptAccount] 换成账号 id。
/// 保留这个名字是为了不让已有调用点（created_by 的赋值处）全改一遍。
const String kCurrentUserId = UserRepository.localUserId;

// ------------------------------------------------------------------ 基础设施

final databaseProvider = Provider<AppDatabase>((ref) => AppDatabase.instance);

final petRepositoryProvider =
    Provider<PetRepository>((ref) => PetRepository());

final recordRepositoryProvider =
    Provider<RecordRepository>((ref) => RecordRepository());

final attachmentRepositoryProvider =
    Provider<AttachmentRepository>((ref) => AttachmentRepository());

final reminderRepositoryProvider =
    Provider<ReminderRepository>((ref) => ReminderRepository());

final expenseRepositoryProvider =
    Provider<ExpenseRepository>((ref) => ExpenseRepository());

final walkRepositoryProvider =
    Provider<WalkRepository>((ref) => WalkRepository());

final memberRepositoryProvider =
    Provider<MemberRepository>((ref) => MemberRepository());

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService.instance);

final userRepositoryProvider =
    Provider<UserRepository>((ref) => UserRepository());

// 数据库连接与密钥库都由这里注入，而不是让 SyncEngine 自己去够 ——
// 那会让引擎文件拖进 Flutter 插件依赖，从此只能用 flutter test 验（本机跑不动）。
// 详见 SyncEngine 构造函数的注释。
final syncEngineProvider = Provider<SyncEngine>(
  (ref) => SyncEngine(
    dbProvider: () => AppDatabase.instance.db,
    tokenStore: SecureTokenStore(),
  ),
);

final syncApiProvider = Provider<SyncApi>((ref) => SyncApi());

/// 官网统一账号客户端（**仅中国区**）。
///
/// 海外区构造出来也是个空地址对象，但没有任何代码路径会去用它 ——
/// 两个调用点（发码 / 登录）都先看 [UnifiedAccountApi.isAvailable]。
final unifiedAccountApiProvider =
    Provider<UnifiedAccountApi>((ref) => UnifiedAccountApi());

/// 我收到的待接受邀请。未登录时是空列表。
///
/// 只在「我的」页被 watch —— 它要发网络请求，不该在启动路径上跑。
final myInvitesProvider = FutureProvider<List<RemoteInvite>>((ref) async {
  final token = await ref.read(syncEngineProvider).token();
  if (token == null) return const <RemoteInvite>[];
  return ref.read(syncApiProvider).myInvites(token);
});

/// 当前用户（本地那一行）。联系方式、昵称都从这里读。
final currentUserProvider = FutureProvider<LocalUser?>((ref) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(userRepositoryProvider).current();
});

/// 自动更新服务。单独一个 provider 是为了让测试能 override 成假实现 ——
/// 真实现会发网络请求，widget 测试里不能真的打出去。
final appUpdateServiceProvider =
    Provider<AppUpdateService>((ref) => AppUpdateService());

/// 数据库是否已就绪。main() 里 await 打开，这里作为门禁。
final dbReadyProvider = FutureProvider<void>((ref) async {
  await ref.read(databaseProvider).open();
});

// ------------------------------------------------------------------ 宠物

/// 宠物列表。
///
/// 写成 notifier 而不是纯 FutureProvider，是为了让测试能 override 掉，
/// 避免 widget 测试碰 sqflite 平台通道。
class PetsNotifier extends AsyncNotifier<List<Pet>> {
  @override
  Future<List<Pet>> build() async {
    await ref.watch(dbReadyProvider.future);
    return ref.read(petRepositoryProvider).listAll();
  }

  /// 重新拉取。写操作后调用。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      return ref.read(petRepositoryProvider).listAll();
    });
  }
}

final petsProvider =
    AsyncNotifierProvider<PetsNotifier, List<Pet>>(PetsNotifier.new);

/// 当前选中的宠物 id。null 表示还没选，UI 落回列表第一个。
final selectedPetIdProvider = StateProvider<String?>((ref) => null);

/// 当前宠物。选中 id 无效时自动回落到第一只。
final currentPetProvider = Provider<Pet?>((ref) {
  final pets = ref.watch(petsProvider).valueOrNull ?? const <Pet>[];
  if (pets.isEmpty) return null;

  final selected = ref.watch(selectedPetIdProvider);
  if (selected != null) {
    for (final p in pets) {
      if (p.id == selected) return p;
    }
  }
  return pets.first;
});

// ------------------------------------------------------------------ 记录

/// 某宠物的全部记录。
final petRecordsProvider =
    FutureProvider.family<List<PetRecord>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(recordRepositoryProvider).listByPet(petId);
});

/// 记录页的筛选类型。null = 全部。
final recordFilterProvider = StateProvider<RecordType?>((ref) => null);

/// 某宠物的体重序列（图表用）。
final weightSeriesProvider = FutureProvider.family<
    List<({DateTime at, double kg})>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(recordRepositoryProvider).weightSeries(petId);
});

/// 某条记录的照片（详情页照片区）。
///
/// 与 [recordDocumentsProvider] 分开：两者在同一张表，但一个是缩略图画廊、
/// 一个是文件列表，混在一起任一侧都要在渲染时自己再筛一遍 —— 而筛错的表现
/// 是「PDF 当成图片渲染出一堆灰块」，很难联想到是漏了 kind 条件。
final recordPhotosProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, recordId) async {
  await ref.watch(dbReadyProvider.future);
  return ref
      .read(attachmentRepositoryProvider)
      .listByRecord(recordId, kind: 'photo');
});

/// 某条记录挂的文档原件（PDF / Word…）。
final recordDocumentsProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, recordId) async {
  await ref.watch(dbReadyProvider.future);
  return ref
      .read(attachmentRepositoryProvider)
      .listByRecord(recordId, kind: 'document');
});

/// 某只宠物的全部照片（跨记录）。档案页「回忆」相册用。
final petPhotosProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(attachmentRepositoryProvider).listPhotosByPet(petId);
});

/// 某只宠物的全部文档原件（跨记录）。档案页「资料」页签用。
final petDocumentsProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(attachmentRepositoryProvider).listDocumentsByPet(petId);
});

// ------------------------------------------------------------------ 费用

/// 某宠物的全部支出（未删除），按消费日期倒序。
final petExpensesProvider =
    FutureProvider.family<List<Expense>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(expenseRepositoryProvider).listByPet(petId);
});

/// 某宠物的费用汇总：本月 / 累计 / 近 6 个月 / 本月分类。
///
/// 从 [petExpensesProvider] 那份全量数据算，而不是为每块各发一条 SQL：
/// 支出是一个月几十条的规模，四条聚合查询换一次内存计算并不划算，
/// 而且分开查会出现「卡片上本月 320、下面列表加起来 300」这种对不上。
final expenseSummaryProvider =
    FutureProvider.family<ExpenseSummary, String>((ref, petId) async {
  final all = await ref.watch(petExpensesProvider(petId).future);
  return buildExpenseSummary(all, now: DateTime.now());
});

// ------------------------------------------------------------------ 提醒

/// 某宠物的提醒计划。
final petRemindersProvider =
    FutureProvider.family<List<Reminder>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(reminderRepositoryProvider).listForPet(petId);
});

/// 跨宠物的待办（今日页 + 接下来 7 天）。
class UpcomingRemindersNotifier extends AsyncNotifier<List<Reminder>> {
  @override
  Future<List<Reminder>> build() async {
    await ref.watch(dbReadyProvider.future);
    // 依赖宠物列表，加宠物后自动刷新。
    await ref.watch(petsProvider.future);
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return ref.read(reminderRepositoryProvider).upcoming(
          from: start.subtract(const Duration(days: 30)), // 含最近过期项
          to: start.add(const Duration(days: 8)),
        );
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(build);
  }
}

final upcomingRemindersProvider =
    AsyncNotifierProvider<UpcomingRemindersNotifier, List<Reminder>>(
  UpcomingRemindersNotifier.new,
);

// ------------------------------------------------------------------ 遛狗

final petWalksProvider =
    FutureProvider.family<List<WalkSession>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(walkRepositoryProvider).listSessions(petId, limit: 20);
});

/// 进行中的遛狗。null = 没在遛。
final activeWalkProvider = StateProvider<WalkSession?>((ref) => null);

/// 某次遛狗的轨迹点。详情页画折线用。
///
/// 用 family 按 session 缓存：同一段轨迹在详情页与分享流程里会被取两次，
/// 每次都查 1800 行是没必要的。
final walkPointsProvider =
    FutureProvider.family<List<WalkPoint>, String>((ref, sessionId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(walkRepositoryProvider).pointsOf(sessionId);
});

// ------------------------------------------------------------------ 共养

final petMembersProvider =
    FutureProvider.family<List<PetMember>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(memberRepositoryProvider).listByPet(petId);
});

final petRoleProvider = FutureProvider.family<MemberRole?, String>((ref, petId) async {
  final user = await ref.watch(currentUserProvider.future);
  await ref.watch(petsProvider.future);
  await ref.watch(petMembersProvider(petId).future);
  return ref.read(memberRepositoryProvider).roleFor(petId, user?.id ?? kCurrentUserId);
});

final careLogsProvider = FutureProvider.family<List<Map<String, Object?>>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(reminderRepositoryProvider).logsForPet(petId);
});

final careEventsProvider = FutureProvider.family<List<CareEvent>, (String, int)>((ref, key) async {
  final records = await ref.watch(petRecordsProvider(key.$1).future);
  final reminders = await ref.watch(petRemindersProvider(key.$1).future);
  final logs = await ref.watch(careLogsProvider(key.$1).future);
  return buildCareEvents(records: records, reminders: reminders, logs: logs,
      day: DateTime.fromMillisecondsSinceEpoch(key.$2));
});

// ------------------------------------------------------------------ 动作层

/// 写操作的集合。UI 调它，由它负责失效相关 provider。
class AppActions {
  AppActions(this.ref);

  final Ref ref;

  static const _uuid = Uuid();

  PetRepository get _pets => ref.read(petRepositoryProvider);
  UserRepository get _users => ref.read(userRepositoryProvider);

  /// 当前用户 id。**不要写死成常量** —— 登录成功后本地那一行的 id
  /// 会从 'local-user' 换成账号 id（见 UserRepository.adoptAccount），
  /// 写死会让登录后新建的记录全挂在占位用户名下，既同步不上去、
  /// 也判断不出归属。每次查一次库，PK 命中，开销可忽略。
  Future<String> _currentUserId() async {
    final u = await _users.current();
    return u?.id ?? kCurrentUserId;
  }
  RecordRepository get _records => ref.read(recordRepositoryProvider);
  AttachmentRepository get _attachments =>
      ref.read(attachmentRepositoryProvider);
  ReminderRepository get _reminders => ref.read(reminderRepositoryProvider);
  ExpenseRepository get _expenses => ref.read(expenseRepositoryProvider);
  WalkRepository get _walks => ref.read(walkRepositoryProvider);
  NotificationService get _notify => ref.read(notificationServiceProvider);

  Future<void> _requirePetPermission(String petId, {bool manage = false}) async {
    final role = await ref.read(memberRepositoryProvider).roleFor(petId, await _currentUserId());
    if (role == null || (manage ? !role.canManage : !role.canWrite)) {
      throw StateError(L.t(manage ? 'pet.delete.ownerOnly' : 'care.readOnly'));
    }
  }

  Future<void> deletePet(String petId) async {
    final pet = await _pets.findById(petId);
    if (pet == null) throw StateError(L.t('care.error.changed'));
    await _requirePetPermission(pet.id, manage: true);
    await _pets.softDelete(pet.id);
    for (final reminder in await _reminders.listForPet(pet.id)) {
      await _notify.cancel(reminder.id);
    }
    if (ref.read(selectedPetIdProvider) == pet.id) {
      ref.read(selectedPetIdProvider.notifier).state = null;
    }
    if (ref.read(activeWalkProvider)?.petId == pet.id) {
      ref.read(activeWalkProvider.notifier).state = null;
    }
    ref.invalidate(petsProvider);
    ref.invalidate(upcomingRemindersProvider);
    ref.invalidate(petRoleProvider(pet.id));
    await ref.read(syncControllerProvider.notifier).markDirty();
  }

  Future<Reminder> saveMedicationCourse(String petId, MedicationCourse course,
      {Reminder? existing}) async {
    await _requirePetPermission(petId);
    if (existing != null && existing.petId != petId) throw StateError('wrong pet');
    final saved = existing == null
        ? await _reminders.createCourse(petId: petId, course: course)
        : await _reminders.updateCourse(existing, course);
    await _syncReminder(saved);
    await _notify.requestPermission();
    await ref.read(syncControllerProvider.notifier).markDirty();
    return saved;
  }

  Future<void> toggleMedicationCourse(Reminder reminder, bool enabled) async {
    await _requirePetPermission(reminder.petId);
    await _syncReminder(await _reminders.toggleCourse(reminder, enabled));
    await ref.read(syncControllerProvider.notifier).markDirty();
  }

  Future<void> refreshNotifications() async {
    await _notify.cancelAll();
    for (final pet in await _pets.listAll()) {
      await _notify.rescheduleAll(await _reminders.listForPet(pet.id, onlyEnabled: true),
          petName: pet.name);
    }
  }

  /// 最近一次 [addPet] 生成的计划条数。
  ///
  /// 为什么用状态位而不是改 [addPet] 的返回值：改成记录类型会波及所有
  /// 调用点，而这里只有建档弹层要拿这个数字弹一句提示。
  int lastPlanCount = 0;

  /// 添加宠物，并按免疫规则自动生成提醒计划。
  ///
  /// 冷启动顺序不可逆：先落宠物 → 再生成计划 → 最后请求通知权限。
  /// 先给价值（「你家猫该驱虫了」），再要权限。
  ///
  /// [skipPlanCodes] 来自建档问卷：用户勾了「已经打过」的疫苗，
  /// 对应的建议排期就不再生成，避免刚填完就被提醒打一针已经打过的。
  Future<Pet> addPet({
    required String name,
    required Species species,
    DateTime? birthday,
    bool birthdayEstimated = false,
    String? breed,
    Set<String> skipPlanCodes = const <String>{},
  }) async {
    final pet =     await _pets.create(Pet(
      id: _uuid.v4(),
      name: name,
      species: species,
      breed: breed,
      birthday: birthday,
      birthdayEstimated: birthdayEstimated,
      createdBy: await _currentUserId(),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));

    ref.invalidate(petsProvider);
    ref.read(selectedPetIdProvider.notifier).state = pet.id;

    lastPlanCount = 0;
    if (birthday != null) {
      lastPlanCount = await generatePlanFor(pet, skipCodes: skipPlanCodes);
    }
    return pet;
  }

  /// 保存档案编辑结果。
  ///
  /// 两个副作用要留意：
  /// - **首次填上生日**会把免疫计划补出来。用户建档时跳过生日是常见情况，
  ///   补上生日后就该拿到计划，否则「填了生日却什么都没发生」很困惑。
  /// - **已经有计划再改生日**不动排期。日期可能被用户手动调过，
  ///   静默重排会把「我明明改过」变成说不清的事，交给用户自己决定。
  Future<void> updatePet(Pet pet) async {
    final before = await _pets.findById(pet.id);
    await _pets.update(pet);

    ref.invalidate(petsProvider);
    ref.invalidate(petRemindersProvider(pet.id));
    ref.invalidate(upcomingRemindersProvider);

    if (before?.birthday == null && pet.birthday != null) {
      await generatePlanFor(pet);
    }
  }

  /// 换头像：先把图拷进应用目录，再写路径。旧图删掉（一对一，不会被别处引用）。
  Future<Pet> setAvatar(Pet pet, String sourcePath) async {
    final oldPath = pet.avatarUrl;
    final path = await AvatarStore.import(sourcePath, petId: pet.id);
    final updated = pet.copyWith(avatarUrl: path);
    await _pets.update(updated);
    ref.invalidate(petsProvider);
    await AvatarStore.deleteQuietly(oldPath);
    return updated;
  }

  Future<Pet> removeAvatar(Pet pet) async {
    final oldPath = pet.avatarUrl;
    final updated = pet.copyWith(clearAvatar: true);
    await _pets.update(updated);
    ref.invalidate(petsProvider);
    await AvatarStore.deleteQuietly(oldPath);
    return updated;
  }

  /// 依免疫规则生成提醒计划。已存在的同 code 提醒不重复生成。
  Future<int> generatePlanFor(
    Pet pet, {
    Set<String> skipCodes = const <String>{},
  }) async {
    final birthday = pet.birthday;
    if (birthday == null) return 0;

    final now = DateTime.now();
    final plan = ruleSetFor(AppRegion.current).buildPlan(
      species: pet.species,
      birthday: birthday,
      now: now,
      horizonDays: 365,
      skipCodes: skipCodes,
    );

    final existing = await _reminders.listForPet(pet.id);
    final existingTypes = existing.map((r) => r.type).toSet();
    final seen = <String>{};

    var created = 0;
    for (final item in plan) {
      // 同一 code 只保留最近一次，避免 3 针疫苗生成 3 条。
      if (!seen.add(item.code)) continue;
      // 已有同类型的提醒就不重复建（用户可能手工加过）。
      if (existingTypes.contains(item.type.wireName)) continue;

      await _reminders.createInterval(
        petId: pet.id,
        type: item.type.wireName,
        title: item.titleKey, // 存 i18n key，展示时再翻
        everyDays: item.recurring ? _intervalDaysOf(item) : 0,
        firstAt: item.dueAt,
        source: 'auto',
      );
      created++;
    }

    if (created > 0) {
      ref.invalidate(petRemindersProvider(pet.id));
      ref.invalidate(upcomingRemindersProvider);
      await _notify.rescheduleAll(
        await _reminders.listForPet(pet.id, onlyEnabled: true),
        petName: pet.name,
      );
    }
    return created;
  }

  static int _intervalDaysOf(PlannedEvent item) => switch (item.type) {
        PlanItemType.dewormExternal => 30,
        PlanItemType.dewormInternal => 90,
        PlanItemType.checkup => 365,
        PlanItemType.vaccine => 365,
        // 洗澡/美容：一个月一次。比疫苗密得多，所以「完成即排下次」在这里
        // 才是真正有用的那条路径（用户洗一次点一下，下次自动排出来）。
        PlanItemType.grooming => 30,
      };

  /// 写一条记录。
  Future<void> addRecord({
    required String petId,
    required RecordType type,
    required DateTime recordedAt,
    double? valueNum,
    String? valueText,
    String? unit,
    Map<String, dynamic> payload = const {},
    String? note,
  }) async {
    final actor = await _users.current();
    await _requirePetPermission(petId);
    if (type == RecordType.symptom) {
      final observation = SymptomObservation.fromPayload(payload);
      if (observation == null) throw ArgumentError('observation.invalid');
      if (observation.medicalRecordId != null) {
        final visit = await _records.findById(observation.medicalRecordId!);
        if (visit == null ||
            visit.petId != petId ||
            visit.type != RecordType.medical ||
            visit.deletedAt != null) {
          throw ArgumentError('observation.linkUnavailable');
        }
      }
      if (observation.courseReminderId != null) {
        final reminder = await _reminders.findById(observation.courseReminderId!);
        if (reminder == null ||
            reminder.petId != petId ||
            reminder.deletedAt != null ||
            MedicationCourse.fromReminder(reminder) == null) {
          throw ArgumentError('observation.linkUnavailable');
        }
      }
    }
    await _records.createSimple(
      petId: petId,
      type: type,
      recordedAt: recordedAt,
      createdBy: await _currentUserId(),
      valueNum: valueNum,
      valueText: valueText,
      unit: unit,
      payload: {...payload, if (actor != null) 'actor_name': actor.nickname},
      note: note,
    );
    ref.invalidate(petRecordsProvider(petId));
    ref.invalidate(weightSeriesProvider(petId));
  }

  /// 从「回忆」页直接加一张照片。
  ///
  /// 附件在数据模型上**必须挂在一条 record 上**（`attachments.record_id` 非空），
  /// 所以这里顺手建一条 `note` 记录当载体，而不是另开一张「无主照片」表。
  /// 换来两个好处：这张照片同时出现在记录时间线里（用户点得进去、改得了
  /// 事件时间、删得掉），同步也走同一条链路，不用为它单独定协议。
  ///
  /// `payload.kind = 'photo'` 是给界面认的标记，用来把这类记录显示成「照片」
  /// 而不是光秃秃一个「笔记」。
  Future<void> addPhotoMemory({
    required String petId,
    required String sourcePath,
    DateTime? recordedAt,
    String? note,
  }) async {
    final record = await _records.createSimple(
      petId: petId,
      type: RecordType.note,
      recordedAt: recordedAt ?? DateTime.now(),
      createdBy: await _currentUserId(),
      payload: const {'kind': 'photo'},
      note: note,
    );
    // 先落库、后收编文件：addPhoto 自己保证「拷贝失败就不落库」，
    // 但记录已经写进去了 —— 那种情况会留下一条没有照片的空笔记。
    // 真发生了也不致命（用户删掉即可），比丢照片好。
    await _attachments.addPhoto(recordId: record.id, sourcePath: sourcePath);
    ref.invalidate(petRecordsProvider(petId));
    ref.invalidate(recordPhotosProvider(record.id));
    ref.invalidate(petPhotosProvider(petId));
  }

  /// 记一笔支出。
  ///
  /// 币种取区域默认值（cn → CNY），**不跟着系统 locale 变**：
  /// 一个在中国生活的用户把手机语言调成英文，记的仍是人民币，
  /// 按 locale 走会把 ¥120 存成 $120，汇总时两种钱加在一起就是错的。
  Future<Expense> addExpense({
    required String petId,
    required double amount,
    required ExpenseCategory category,
    required DateTime spentAt,
    String? note,
    String? recordId,
  }) async {
    final expense = await _expenses.createSimple(
      petId: petId,
      amount: amount,
      category: category,
      spentAt: spentAt,
      createdBy: await _currentUserId(),
      currency: AppRegion.current.defaultCurrency,
      note: note,
      recordId: recordId,
    );
    ref.invalidate(petExpensesProvider(petId));
    return expense;
  }

  /// 删除一笔支出（软删除）。
  ///
  /// 软删而不是物理删：费用也能同步到云端，硬删会变成一个「删除」变更，
  /// 万一对方设备上还有这条的新版本，两边就会反复打架。
  Future<void> deleteExpense(String petId, String expenseId) async {
    await _expenses.softDelete(expenseId);
    ref.invalidate(petExpensesProvider(petId));
  }

  /// 给一条已有记录加照片：拷贝进应用目录 + 落库 + 失效相关 provider。
  ///
  /// 与 [addPhotoMemory] 的区别：那边连载体记录一起建（用于「回忆」相册
  /// 直接加照片），这里记录已经存在。
  Future<RecordAttachment> addPhotoToRecord({
    required String recordId,
    required String petId,
    required String sourcePath,
  }) async {
    final att = await _attachments.addPhoto(
      recordId: recordId,
      sourcePath: sourcePath,
    );
    ref.invalidate(recordPhotosProvider(recordId));
    ref.invalidate(petPhotosProvider(petId));
    return att;
  }

  /// 挂一份文档原件（PDF / Word / 图片）。
  ///
  /// [recordId] 为空时**顺手建一条 note 记录当载体**（与 [addPhotoMemory]
  /// 同一套路）：附件在数据模型上必须挂在 record 上，而疫苗本、保单这类
  /// 文档不属于任何一次事件。建了载体记录，它就会出现在记录时间线里，
  /// 用户点得进去、改得了时间、删得掉。
  ///
  /// 文件**只拷进本机**，不上传服务端（见 schema 的 kSyncSkipWhen）。
  Future<RecordAttachment> addDocument({
    required String petId,
    required String sourcePath,
    required String fileName,
    String? mime,
    int? sizeBytes,
    String? recordId,
  }) async {
    String target = recordId ?? '';
    if (target.isEmpty) {
      final carrier = await _records.createSimple(
        petId: petId,
        type: RecordType.note,
        recordedAt: DateTime.now(),
        createdBy: await _currentUserId(),
        payload: const {'kind': 'document'},
      );
      target = carrier.id;
      ref.invalidate(petRecordsProvider(petId));
    }

    final att = await _attachments.addDocument(
      recordId: target,
      sourcePath: sourcePath,
      fileName: fileName,
      mime: mime,
      sizeBytes: sizeBytes,
    );
    ref.invalidate(recordDocumentsProvider(target));
    ref.invalidate(petDocumentsProvider(petId));
    return att;
  }

  /// 删除一个附件（照片或文档，软删除）。
  Future<void> deleteAttachment({
    required String petId,
    required String recordId,
    required String attachmentId,
  }) async {
    await _attachments.softDelete(attachmentId);
    ref.invalidate(recordPhotosProvider(recordId));
    ref.invalidate(recordDocumentsProvider(recordId));
    ref.invalidate(petPhotosProvider(petId));
    ref.invalidate(petDocumentsProvider(petId));
  }

  /// 完成一次提醒：留档 + 排下次 + 重排通知。
  Future<ReminderTickResult> completeReminder(String reminderId, {DateTime? expectedDueAt}) async {
    final reminder = await _reminders.findById(reminderId);
    if (reminder == null) throw StateError(L.t('care.error.changed'));
    await _requirePetPermission(reminder.petId);
    final actor = await _users.current();
    final result = await _reminders.completeOnce(reminderId,
        expectedDueAt: expectedDueAt ?? reminder.nextAt,
        createdBy: actor?.id ?? kCurrentUserId, actorName: actor?.nickname);
    ref.invalidate(upcomingRemindersProvider);
    ref.invalidate(petRemindersProvider(result.reminder.petId));
    ref.invalidate(careLogsProvider(result.reminder.petId));
    ref.invalidate(petRecordsProvider(result.reminder.petId));
    await ref.read(syncControllerProvider.notifier).markDirty();

    if (result.nextAt != null) {
      await _notify.schedule(result.reminder, nextAt: result.nextAt!);
    } else {
      await _notify.cancel(result.reminder.id);
    }
    return result;
  }

  Future<void> snoozeReminder(String reminderId) async {
    final reminder = await _reminders.findById(reminderId);
    if (reminder == null) return;
    await _requirePetPermission(reminder.petId);
    // A course's slots are fixed; postponing a dose by a whole day breaks it.
    if (reminder.rule['mode'] == 'medication') throw StateError(L.t('med.pauseHint'));

    final next = await _reminders.snooze(reminderId, const Duration(days: 1));
    ref.invalidate(upcomingRemindersProvider);
    ref.invalidate(petRemindersProvider(reminder.petId));
    if (next != null) {
      await _notify.schedule(reminder, nextAt: next, petName: _petNameOf(reminder.petId));
    }
  }

  // ---- M4：手动提醒的增删改 ----

  /// 新建提醒。[everyDays] <= 0 表示一次性。
  ///
  /// 数据先落库、通知后调度：调度失败（权限没给、系统拒绝）不该让提醒丢掉，
  /// 用户至少还能在列表里看到它。
  Future<Reminder> createReminder({
    required String petId,
    required String type,
    required String title,
    required int everyDays,
    required DateTime firstAt,
  }) async {
    await _requirePetPermission(petId);
    final reminder = await _reminders.createInterval(
      petId: petId,
      type: type,
      title: title,
      everyDays: everyDays,
      firstAt: firstAt,
    );
    await _syncReminder(reminder);
    return reminder;
  }

  Future<void> updateReminder(Reminder reminder) async {
    await _requirePetPermission(reminder.petId);
    if (reminder.rule['mode'] == 'medication') {
      throw StateError(L.t('med.error.schedule'));
    }
    await _reminders.update(reminder);
    await _syncReminder(reminder);
  }

  /// 删除提醒。**软删除 + 撤掉通知**：记录留着，但不能再弹。
  Future<void> deleteReminder(Reminder reminder) async {
    await _requirePetPermission(reminder.petId);
    await _reminders.softDelete(reminder.id);
    await _notify.cancel(reminder.id);
    ref.invalidate(petRemindersProvider(reminder.petId));
    ref.invalidate(upcomingRemindersProvider);
  }

  /// 提醒变更后的统一收尾：失效相关 provider + 重排这条通知。
  Future<void> _syncReminder(Reminder reminder) async {
    ref.invalidate(petRemindersProvider(reminder.petId));
    ref.invalidate(upcomingRemindersProvider);

    if (!reminder.enabled) {
      await _notify.cancel(reminder.id);
      return;
    }
    await _notify.schedule(
      reminder,
      nextAt: reminder.nextAt,
      petName: _petNameOf(reminder.petId),
    );
  }

  /// 通知副标题要显示宠物名；取不到就留空，不编。
  String? _petNameOf(String petId) {
    final pets = ref.read(petsProvider).valueOrNull ?? const <Pet>[];
    for (final p in pets) {
      if (p.id == petId) return p.name;
    }
    return null;
  }

  /// 开始遛狗。
  Future<WalkSession> startWalk(String petId) async {
    final session = await _walks.startSession(
      petId: petId,
      createdBy: await _currentUserId(),
    );
    ref.read(activeWalkProvider.notifier).state = session;
    return session;
  }

  /// 结束遛狗并保存。
  Future<WalkSession> endWalk(String sessionId) async {
    final session = await _walks.endSession(sessionId);
    ref.read(activeWalkProvider.notifier).state = null;
    ref.invalidate(petWalksProvider(session.petId));
    return session;
  }

  /// 遛狗结束后补录心情与备注。结果页提交时调一次。
  Future<void> saveWalkFeedback(
    String sessionId, {
    String? mood,
    String? note,
  }) async {
    final updated = await _walks.setFeedback(sessionId, mood: mood, note: note);
    if (updated != null) ref.invalidate(petWalksProvider(updated.petId));
  }

  /// 保存联系方式（M5）。
  ///
  /// 本地先落库再尝试推服务端：**离线也能改**，服务端那份等下次同步补上。
  /// 反过来的话，用户在没网时点保存只会得到一个错误提示。
  Future<void> updateContact({
    required LocalUser user,
    required LocalUser updated,
  }) async {
    await _users.update(updated);
    ref.invalidate(currentUserProvider);

    // 已登录才推；未登录时这份数据只存在本地，登录后由同步引擎整体推上去。
    if (await ref.read(syncEngineProvider).isLoggedIn()) {
      try {
        await ref.read(syncEngineProvider).pushContact(
              wechat: updated.wechat,
              contactNote: updated.contactNote,
            );
      } catch (_) {
        // 推失败不回滚本地：用户的输入不能因为网络问题丢掉。
        // 下次同步会带上（users 行参与同步）。
      }
    }
  }

  // ---- M6：账号 ----

  /// 请求登录验证码。返回 true 表示服务端已发出。
  ///
  /// 开发环境服务端会回显 `dev_code`，界面直接显示出来省掉真短信通道 ——
  /// 上生产前记得把服务端的 `DEV_ECHO_CODE` 关掉。
  ///
  /// 中国区走官网统一账号（A 方案）：验证码由**官网**的短信通道发出去，
  /// 本服务端不参与。所以 cn 区拿不到 dev 回显，联调时要在官网侧开
  /// `APP_SMS_DEBUG=1`（见 docs/账号体系复用.md）。
  Future<({bool sent, String? devCode, int? expiresIn})> requestLoginCode({
    required String channel,
    required String target,
  }) async {
    if (UnifiedAccountApi.isAvailable) {
      _requirePhoneChannel(channel);
      final r = await ref
          .read(unifiedAccountApiProvider)
          .requestCode(phone: target);
      // 官网的调试回显字段叫 debug_code，这里翻成界面在用的 devCode。
      return (sent: r.sent, devCode: r.debugCode, expiresIn: r.expiresIn);
    }

    final r = await ref.read(syncApiProvider).requestCode(
          channel: channel,
          target: target,
        );
    return (sent: r.sent, devCode: r.devCode, expiresIn: r.expiresIn);
  }

  /// 统一账号只支持手机号（官网没有邮箱登录）。界面在 cn 区不显示邮箱选项，
  /// 走到这里说明有别的入口漏了判断 —— 抛出来比发一个注定失败的请求好。
  void _requirePhoneChannel(String channel) {
    if (channel != 'sms') {
      throw StateError('unified account supports phone login only');
    }
  }

  /// 验证码登录。
  ///
  /// 顺序不能变：**先过户本地数据、再存会话、最后同步**。
  /// - 过户放在最前面：`created_by` 要在第一次 push 之前就指向账号 id，
  ///   否则第一次同步会把本地数据挂到占位用户名下推上去。
  /// - 同步放在最后：它要把过户后的全量本地数据推上去。
  ///
  /// 两条登录路径，区别只在「怎么拿到宠物域令牌」：
  /// - 中国区：官网验证码登录 → 拿账号域令牌 → 宠物服务端换票。
  ///   官网令牌**用完即弃、不落盘**，宠物域有自己的令牌。
  /// - 海外区：宠物服务端自己的验证码通道，一步到位。
  Future<LocalUser> login({
    required String channel,
    required String target,
    required String code,
  }) async {
    final engine = ref.read(syncEngineProvider);

    final AuthSession session;
    if (UnifiedAccountApi.isAvailable) {
      _requirePhoneChannel(channel);
      final unified = await ref
          .read(unifiedAccountApiProvider)
          .login(phone: target, code: code);
      session = await ref.read(syncApiProvider).exchangeUnified(
            unifiedToken: unified.token,
            deviceId: await engine.deviceId(),
          );
    } else {
      session = await ref.read(syncApiProvider).verifyCode(
            channel: channel,
            target: target,
            code: code,
            deviceId: await engine.deviceId(),
          );
    }

    return _finishLogin(session);
  }

  /// 密码登录。直接走宠物服务端 `/auth/password/login`，与官网统一账号无关
  /// （官网没有密码）。cn/intl 两区都可用。
  Future<LocalUser> loginWithPassword({
    required String channel,
    required String target,
    required String password,
  }) async {
    final engine = ref.read(syncEngineProvider);
    final session = await ref.read(syncApiProvider).passwordLogin(
          channel: channel,
          target: target,
          password: password,
          deviceId: await engine.deviceId(),
        );
    return _finishLogin(session);
  }

  /// 拿到会话之后的统一收尾：过户本地数据 → 存会话 → 刷新依赖 → 同步。
  ///
  /// 验证码登录与密码登录共用这一段，保证两条路径的落地行为完全一致。
  Future<LocalUser> _finishLogin(AuthSession session) async {
    final engine = ref.read(syncEngineProvider);

    await _users.adoptAccount(
      accountId: session.user.id,
      region: session.user.region ?? AppRegion.current.name,
      nickname: session.user.nickname,
      phone: session.user.phone,
      email: session.user.email,
    );
    await engine.saveSession(session, accountRegion: AppRegion.current.name);

    ref.invalidate(currentUserProvider);
    ref.invalidate(petsProvider);
    ref.invalidate(myInvitesProvider);

    // 登录后立刻同步一次：把本地已有数据推上去、把账号里已有的拉下来。
    // 失败也不影响登录成功 —— 用户在设置页能看到「上次同步」是错的。
    await ref.read(syncControllerProvider.notifier).runSync();

    return (await _users.current())!;
  }

  /// 设置登录密码（需已登录）。首次验证码登录后引导调用。
  Future<void> setPassword(String password) async {
    final token = await ref.read(syncEngineProvider).token();
    if (token == null) throw StateError('未登录');
    await ref.read(syncApiProvider).setPassword(
          token: token,
          password: password,
        );
  }

  /// 导出健康报告：组装内容 → 画成彩色长图 → 唤起系统分享。
  ///
  /// 数据源与档案页**完全一致**（同一批 provider + 同一份 [ledgerInputs]），
  /// 所以报告上的台账不会和页面上看到的对不上 —— 那是最让人困惑的一种错。
  /// 返回成图字节数，供调用方给「已生成」反馈。
  ///
  /// ⚠️ [shareOrigin] 是 iPad 必需项：share_plus 在 iPad 上没有它会直接抛
  /// `PlatformException: sharePositionOrigin: argument must be set`。
  /// iPhone 上同样会抛（UIActivityViewController 的通用要求）。
  /// 传**触发分享的那个按钮**的 Rect，别传 `Rect.zero`（也抛，报 must be non-zero）。
  Future<int> exportPetReport(Pet pet, {Rect? shareOrigin}) async {
    final records = await ref.read(petRecordsProvider(pet.id).future);
    final reminders = await ref.read(petRemindersProvider(pet.id).future);
    final weights = await ref.read(weightSeriesProvider(pet.id).future);

    final inputs = ledgerInputs(records: records, reminders: reminders);
    final ledger = buildCareLedger(
      facts: inputs.facts,
      schedules: inputs.schedules,
    );

    const region = AppRegion.current;
    final report = buildPetReport(
      pet: pet,
      ledger: ledger,
      weightSeries: weights,
      records: records,
      now: DateTime.now(),
      weightUnit: Units.defaultWeightUnit(region),
    );

    final png = await renderPetReportPng(report);

    // 落在临时目录：分享出去之后就是对方的文件了，我们这边不必长期保留。
    // 文件名带上 petId，家里两只宠物各导一份时不会互相覆盖。
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/health-report-${pet.id}.png');
    await file.writeAsBytes(png, flush: true);

    await shareFiles(
      files: [XFile(file.path, mimeType: 'image/png')],
      subject: pet.name,
      origin: shareOrigin,
    );
    return png.length;
  }

  Future<void> logout() async {
    await ref.read(syncEngineProvider).signOut();
    ref.invalidate(myInvitesProvider);
    ref.read(syncControllerProvider.notifier).refresh();
  }

  // ---- M6：共养 ----

  Future<void> inviteMember({
    required String petId,
    required String channel,
    required String target,
    required String role,
  }) async {
    final token = await ref.read(syncEngineProvider).token();
    if (token == null) throw StateError('未登录');
    await ref.read(syncApiProvider).inviteMember(
          token,
          petId,
          channel: channel,
          target: target,
          role: role,
        );
    ref.invalidate(petMembersProvider(petId));
  }

  Future<void> acceptInvite(String inviteId) async {
    final token = await ref.read(syncEngineProvider).token();
    if (token == null) throw StateError('未登录');
    await ref.read(syncApiProvider).acceptInvite(token, inviteId);
    ref.invalidate(myInvitesProvider);
    ref.invalidate(petsProvider);
    // 接受之后那只宠物才对我可见，立刻拉一次。
    await ref.read(syncControllerProvider.notifier).runSync();
  }

  Future<void> removeMember(String petId, String userId) async {
    final token = await ref.read(syncEngineProvider).token();
    if (token == null) throw StateError('未登录');
    await ref.read(syncApiProvider).removeMember(token, petId, userId);
    ref.invalidate(petMembersProvider(petId));
  }
}

final appActionsProvider = Provider<AppActions>(AppActions.new);

// ------------------------------------------------------------------ 同步状态

/// 同步的对外状态。UI 只看这个，不直接碰 [SyncEngine]。
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.notLoggedIn,
    this.lastSyncAt,
    this.pending = 0,
    this.message,
  });

  final SyncPhase phase;
  final DateTime? lastSyncAt;

  /// 待推送条数。有值时说明本地有改动还没上去。
  final int pending;

  /// 出错时的一句话。**同步失败不弹窗**，只在这里给设置页看 ——
  /// 后台同步失败就打断用户是最招人烦的设计之一。
  final String? message;

  bool get syncing => phase == SyncPhase.syncing;
  bool get loggedIn => phase != SyncPhase.notLoggedIn;

  SyncStatus copyWith({
    SyncPhase? phase,
    DateTime? lastSyncAt,
    int? pending,
    String? message,
    bool clearMessage = false,
  }) =>
      SyncStatus(
        phase: phase ?? this.phase,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        pending: pending ?? this.pending,
        message: clearMessage ? null : (message ?? this.message),
      );
}

class SyncController extends Notifier<SyncStatus> {
  @override
  SyncStatus build() {
    // 先探一次本地状态（纯查库，不联网），让设置页一进来就有东西显示。
    Future.microtask(refresh);
    return const SyncStatus();
  }

  SyncEngine get _engine => ref.read(syncEngineProvider);

  /// 数据库还没打开时不要碰引擎。
  ///
  /// 生产环境里 main() 会先 await 打开，走不到这个分支；但 widget 测试
  /// 只 pump 一个 `MeScreen()` 时数据库是没开的，而 `build()` 里那次
  /// `refresh()` 是 microtask 自动跑的 —— 不挡的话会抛
  /// `Bad state: AppDatabase 尚未打开`，把整页测试打挂。
  ///
  /// 这里**显式判断而不是 try/catch**：吞掉异常会把真正的问题也一起藏起来。
  bool get _ready => AppDatabase.instance.isOpen;

  /// 只刷新本地状态，不联网。
  Future<void> refresh() async {
    if (!_ready) {
      state = state.copyWith(
        phase: SyncPhase.notLoggedIn,
        pending: 0,
        clearMessage: true,
      );
      return;
    }
    final loggedIn = await _engine.isLoggedIn();
    final pending = await _engine.pendingCount();
    state = state.copyWith(
      phase: loggedIn ? SyncPhase.idle : SyncPhase.notLoggedIn,
      lastSyncAt: await _engine.lastSyncAt(),
      pending: pending,
      clearMessage: true,
    );
  }

  /// 跑一次同步。任何失败都只反映在 state 里。
  Future<void> runSync() async {
    if (!_ready) return;
    if (state.syncing) return; // 防抖：定时器与手动按钮可能撞上

    if (!await _engine.isLoggedIn()) {
      state = state.copyWith(phase: SyncPhase.notLoggedIn);
      return;
    }

    state = state.copyWith(phase: SyncPhase.syncing, clearMessage: true);
    final report = await _engine.sync();

    if (report.error != null) {
      // 401 已经被引擎处理成「退出登录」，这里跟着反映。
      final stillLoggedIn = await _engine.isLoggedIn();
      state = SyncStatus(
        phase: stillLoggedIn ? SyncPhase.error : SyncPhase.notLoggedIn,
        lastSyncAt: await _engine.lastSyncAt(),
        pending: await _engine.pendingCount(),
        message: report.error.toString(),
      );
      return;
    }

    state = SyncStatus(
      phase: SyncPhase.idle,
      lastSyncAt: await _engine.lastSyncAt(),
      pending: await _engine.pendingCount(),
    );
    // Shared records must update immediately after a manual sync.
    ref.invalidate(petsProvider);
    ref.invalidate(petRecordsProvider);
    ref.invalidate(petRemindersProvider);
    ref.invalidate(petMembersProvider);
    ref.invalidate(petRoleProvider);
    ref.invalidate(careLogsProvider);
    ref.invalidate(upcomingRemindersProvider);
    ref.invalidate(weightSeriesProvider);
    await ref.read(appActionsProvider).refreshNotifications();
  }

  /// 本地进了一批新数据。不立刻同步，等待用户主动同步或登录时同步。
  /// 连记五条就发五次请求是纯浪费。
  Future<void> markDirty() async {
    state = state.copyWith(pending: await _engine.pendingCount());
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(SyncController.new);
