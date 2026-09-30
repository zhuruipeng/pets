/// 状态层 —— Riverpod providers。
///
/// 分工：仓储只管数据，provider 管「谁在关心这些数据」。
/// UI 只读 provider，不直接摸仓储。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'core/region.dart';
import 'data/db/app_database.dart';
import 'data/models.dart';
import 'data/repositories/attachment_repository.dart';
import 'data/repositories/member_repository.dart';
import 'data/repositories/pet_repository.dart';
import 'data/repositories/record_repository.dart';
import 'data/repositories/reminder_repository.dart';
import 'data/repositories/walk_repository.dart';
import 'domain/immunization.dart';
import 'services/notification_service.dart';

/// 当前用户 id。M6 接入账号前用固定值，保证本地可用。
const String kCurrentUserId = 'local-user';

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

final walkRepositoryProvider =
    Provider<WalkRepository>((ref) => WalkRepository());

final memberRepositoryProvider =
    Provider<MemberRepository>((ref) => MemberRepository());

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService.instance);

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

/// 某条记录的附件（照片）。详情页用；增删后 invalidate 这个 family。
final recordAttachmentsProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, recordId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(attachmentRepositoryProvider).listByRecord(recordId);
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

// ------------------------------------------------------------------ 共养

final petMembersProvider =
    FutureProvider.family<List<PetMember>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(memberRepositoryProvider).listByPet(petId);
});

// ------------------------------------------------------------------ 动作层

/// 写操作的集合。UI 调它，由它负责失效相关 provider。
class AppActions {
  AppActions(this.ref);

  final Ref ref;

  static const _uuid = Uuid();

  PetRepository get _pets => ref.read(petRepositoryProvider);
  RecordRepository get _records => ref.read(recordRepositoryProvider);
  ReminderRepository get _reminders => ref.read(reminderRepositoryProvider);
  WalkRepository get _walks => ref.read(walkRepositoryProvider);
  NotificationService get _notify => ref.read(notificationServiceProvider);

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
      createdBy: kCurrentUserId,
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
    await _records.createSimple(
      petId: petId,
      type: type,
      recordedAt: recordedAt,
      createdBy: kCurrentUserId,
      valueNum: valueNum,
      valueText: valueText,
      unit: unit,
      payload: payload,
      note: note,
    );
    ref.invalidate(petRecordsProvider(petId));
    ref.invalidate(weightSeriesProvider(petId));
  }

  /// 完成一次提醒：留档 + 排下次 + 重排通知。
  Future<ReminderTickResult> completeReminder(String reminderId) async {
    final result = await _reminders.completeOnce(reminderId);
    ref.invalidate(upcomingRemindersProvider);
    ref.invalidate(petRemindersProvider(result.reminder.petId));

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

    final next = await _reminders.snooze(reminderId, const Duration(days: 1));
    ref.invalidate(upcomingRemindersProvider);
    ref.invalidate(petRemindersProvider(reminder.petId));
    if (next != null) {
      await _notify.schedule(reminder, nextAt: next);
    }
  }

  /// 开始遛狗。
  Future<WalkSession> startWalk(String petId) async {
    final session = await _walks.startSession(
      petId: petId,
      createdBy: kCurrentUserId,
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

  Future<void> deletePet(String petId) async {
    await _pets.softDelete(petId);
    ref.invalidate(petsProvider);
    ref.invalidate(upcomingRemindersProvider);
  }
}

final appActionsProvider = Provider<AppActions>(AppActions.new);
