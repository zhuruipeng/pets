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
import 'data/repositories/user_repository.dart';
import 'data/repositories/walk_repository.dart';
import 'data/sync/sync_api.dart';
import 'data/sync/sync_engine.dart';
import 'domain/immunization.dart';
import 'services/app_update_service.dart';
import 'services/avatar_store.dart';
import 'services/notification_service.dart';

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

final walkRepositoryProvider =
    Provider<WalkRepository>((ref) => WalkRepository());

final memberRepositoryProvider =
    Provider<MemberRepository>((ref) => MemberRepository());

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService.instance);

final userRepositoryProvider =
    Provider<UserRepository>((ref) => UserRepository());

final syncEngineProvider = Provider<SyncEngine>((ref) => SyncEngine());

final syncApiProvider = Provider<SyncApi>((ref) => SyncApi());

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

/// 某条记录的附件（照片）。详情页用；增删后 invalidate 这个 family。
final recordAttachmentsProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, recordId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(attachmentRepositoryProvider).listByRecord(recordId);
});

/// 某只宠物的全部照片（跨记录）。档案页「回忆」相册用。
final petPhotosProvider =
    FutureProvider.family<List<RecordAttachment>, String>((ref, petId) async {
  await ref.watch(dbReadyProvider.future);
  return ref.read(attachmentRepositoryProvider).listPhotosByPet(petId);
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
      createdBy: await _currentUserId(),
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
    await _reminders.update(reminder);
    await _syncReminder(reminder);
  }

  /// 删除提醒。**软删除 + 撤掉通知**：记录留着，但不能再弹。
  Future<void> deleteReminder(Reminder reminder) async {
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

  Future<void> deletePet(String petId) async {
    await _pets.softDelete(petId);
    ref.invalidate(petsProvider);
    ref.invalidate(upcomingRemindersProvider);
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
              phone: updated.phone,
              email: updated.email,
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
  Future<({bool sent, String? devCode, int? expiresIn})> requestLoginCode({
    required String channel,
    required String target,
  }) async {
    final r = await ref.read(syncApiProvider).requestCode(
          channel: channel,
          target: target,
        );
    return (sent: r.sent, devCode: r.devCode, expiresIn: r.expiresIn);
  }

  /// 验证码登录。
  ///
  /// 顺序不能变：**先过户本地数据、再存会话、最后同步**。
  /// - 过户放在最前面：`created_by` 要在第一次 push 之前就指向账号 id，
  ///   否则第一次同步会把本地数据挂到占位用户名下推上去。
  /// - 同步放在最后：它要把过户后的全量本地数据推上去。
  Future<LocalUser> login({
    required String channel,
    required String target,
    required String code,
  }) async {
    final engine = ref.read(syncEngineProvider);
    final session = await ref.read(syncApiProvider).verifyCode(
          channel: channel,
          target: target,
          code: code,
          deviceId: await engine.deviceId(),
        );

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
  }

  /// 本地进了一批新数据。**不立刻同步**，等下一次定时/前台恢复时一起走 ——
  /// 连记五条就发五次请求是纯浪费。
  Future<void> markDirty() async {
    state = state.copyWith(pending: await _engine.pendingCount());
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(SyncController.new);
