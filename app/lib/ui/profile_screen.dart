/// 档案页 —— 单只宠物的完整画像（参考稿右侧那张屏）。
///
/// 版式：
/// 1. 渐变头图 + 圆形大照片（带相机角标）+ 名字 + 品种年龄 + 健康标签
/// 2. 五个分页签：资料 / 健康 / 记录 / 回忆 / 费用
/// 3. 基本信息卡 —— 标签左、值右，行与行之间用极淡分隔线
/// 4. 个性特点 —— 圆角标签串
/// 5. 家庭成员 —— 头像 + 名字 + 角色，底部一个「添加家庭成员」
///
/// 页签本身要真实存在，用户点得动才知道后面有什么。
/// 资料页和健康页 M1 就有内容；记录页（已完成的条目）与回忆页（相册）
/// 落在 M2/M3，先摆空态 —— 空态也要写清楚「以后这里放什么」。
library;

import 'delete_pet_button.dart';
import 'dart:io';

import 'package:flutter/material.dart';
// Clipboard：导出失败时把异常详情复制出来。侧载包在真机上跑，
// 开发者不一定连着 Xcode，拿不到控制台日志 —— 这是唯一的捞异常办法。
// ignore: unused_import
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:image_picker/image_picker.dart';

import '../core/feature_flags.dart';
import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/traits.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../data/repositories/member_repository.dart';
import '../domain/expense_stats.dart';
import '../domain/health_ledger.dart';
// PlanItemTypeX 是 wireName 所在的扩展，`show` 列表里漏了它就用不了 wireName。
import '../domain/immunization.dart'
    show Species, ruleSetFor, PlanItemTypeX;
import '../providers.dart';
import '../services/share_helper.dart';
import 'avatar_sheet.dart';
import 'edit_pet_sheet.dart';
import 'lost_card.dart';
import 'members_sheet.dart';
import 'record_detail.dart';
import 'records_screen.dart';
import 'reminder_sheet.dart';
import 'sheets.dart';
import 'walk_detail.dart';
import 'widgets.dart';
import 'medication_courses.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  static const _tabKeys = [
    'profile.tab.info',
    'profile.tab.health',
    'profile.tab.records',
    'profile.tab.memory',
    'profile.tab.expense',
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabKeys.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pets = ref.watch(petsProvider).valueOrNull ?? const <Pet>[];
    final pet = ref.watch(currentPetProvider);

    if (pet == null) {
      return EmptyState(
        icon: Icons.pets_outlined,
        title: pets.isEmpty ? L.t('profile.empty.title') : L.t('records.noPet'),
        hint: L.t('profile.empty.hint'),
        action: FilledButton.icon(
          onPressed: () => showAddPetSheet(context, ref),
          icon: const Icon(Icons.add),
          label: Text(L.t('action.add')),
        ),
      );
    }

    return NestedScrollView(
      headerSliverBuilder: (context, _) => [
        SliverToBoxAdapter(child: _HeroHeader(pet: pet)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _TabBarDelegate(
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              indicatorSize: TabBarIndicatorSize.label,
              indicatorWeight: 2.4,
              dividerColor: AppColors.divider,
              labelStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
              // 未选中与选中**同字重**：只靠颜色和指示条区分。
              // 字重不同（w600 vs 默认 w400）时，拉丁字母宽度会变，
              // 切换页签时文字会左右微跳 —— 中文看不出，英文版很明显。
              unselectedLabelStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
              tabs: [for (final k in _tabKeys) Tab(text: L.t(k))],
            ),
          ),
        ),
      ],
      body: TabBarView(
        controller: _tabs,
        children: [
          _InfoTab(pet: pet),
          _HealthTab(pet: pet),
          _RecordsTab(pet: pet),
          _MemoriesTab(pet: pet),
          _ExpenseTab(pet: pet),
        ],
      ),
    );
  }
}

/// TabBar 的吸顶壳。TabBar 高度固定，这里给它 48px。
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.bar);

  final TabBar bar;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      height: 48,
      color: AppColors.surface,
      child: bar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate old) => false;
}

// ------------------------------------------------------------------ 渐变头图

/// 渐变头图。参考稿顶部是淡紫→淡蓝的渐变，中间一个带白边的圆照片。
class _HeroHeader extends ConsumerWidget {
  const _HeroHeader({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(petRemindersProvider(pet.id)).valueOrNull ??
        const <Reminder>[];
    final now = DateTime.now();
    final hasOverdue = reminders.any((r) => r.enabled && r.nextAt.isBefore(now));

    return Container(
      decoration: const BoxDecoration(
        gradient: AppGradients.header,
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(AppRadius.card),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        4,
        AppSpace.page,
        AppSpace.gapM,
      ),
      child: Column(
        children: [
          // 顶栏：返回位 + 编辑。
          // 「返回位」那格 38px 是给以后真返回键留的对称位；现在只为
          // 让「编辑」不贴左，顺手平衡视觉重量。
          Row(
            children: [
              const SizedBox(width: 38),
              const Spacer(),
              TextButton(
                onPressed: () => showEditPetSheet(context, pet: pet),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                ),
                child: Text(
                  L.t('profile.edit'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),

          // 圆照片 + 相机角标
          Stack(
            clipBehavior: Clip.none,
            children: [
              PetAvatar(pet: pet, size: 96, borderWidth: 4),
              Positioned(
                right: -2,
                bottom: -2,
                child: GestureDetector(
                  onTap: () => showAvatarSheet(context, ref, pet),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.5),
                    ),
                    child: const Icon(Icons.photo_camera_rounded,
                        size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gapXs),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  pet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Header 上最大的文字就是它 —— 名字是身份页的视觉中心。
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    height: 1.15,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _GenderMark(gender: pet.gender),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _breedAgeLine(pet),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpace.gapXs),
          SoftTag(
            hasOverdue ? L.t('profile.healthAlert') : L.t('profile.healthGood'),
            color: hasOverdue ? AppColors.warning : AppColors.success,
            bg: hasOverdue ? AppColors.warningBg : AppColors.successBg,
            icon: hasOverdue
                ? Icons.error_outline_rounded
                : Icons.verified_rounded,
          ),
        ],
      ),
    );
  }

  static String _breedAgeLine(Pet pet) {
    final parts = <String>[
      _speciesLabel(pet.species),
      if ((pet.breed ?? '').trim().isNotEmpty) pet.breed!.trim(),
      _ageText(pet.birthday),
    ];
    return parts.join(' · ');
  }

  // 统一到 domain/labels.dart：原先这里和 today_screen 各抄了一份完全相同的
  // 实现，导出报告还要用第三份。now 从外面传 ⇒ 可测。
  static String _ageText(DateTime? birthday) =>
      petAgeLabel(birthday, DateTime.now()) ?? L.t('profile.ageUnknown');

  static String _speciesLabel(Species s) => switch (s) {
        Species.dog => L.t('addPet.species.dog'),
        Species.cat => L.t('addPet.species.cat'),
        Species.other => L.t('addPet.species.other'),
      };
}

/// 性别符号。与今日页保持同一套绘制。
class _GenderMark extends StatelessWidget {
  const _GenderMark({required this.gender});

  final String? gender;

  @override
  Widget build(BuildContext context) {
    final g = (gender ?? '').trim().toLowerCase();
    final (symbol, color) = switch (g) {
      'female' || 'f' || '母' || '雌' => ('♀', const Color(0xFFEC4899)),
      'male' || 'm' || '公' || '雄' => ('♂', const Color(0xFF3B82F6)),
      _ => ('', AppColors.textTertiary),
    };
    if (symbol.isEmpty) return const SizedBox.shrink();
    return Text(
      symbol,
      style: TextStyle(fontSize: 17, height: 1, color: color),
    );
  }
}

// ------------------------------------------------------------------ 资料页签

class _InfoTab extends ConsumerWidget {
  const _InfoTab({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const region = AppRegion.current;
    final unit = Units.defaultWeightUnit(region);
    final series = ref.watch(weightSeriesProvider(pet.id)).valueOrNull;
    final latestWeight =
        (series == null || series.isEmpty) ? null : series.last.kg;
    final basicRows = _basicRows(pet, latestWeight, unit);
    final traits = knownPersonalities(pet.personality);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapL,
        AppSpace.page,
        96,
      ),
      children: [
        // ---- 基本信息 ----
        Text(
          L.t('profile.section.basic'),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.gapM),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.gapL,
            vertical: AppSpace.gapXs,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              // 空值行直接不出现（breed/生日/体重/体型/毛色 没填就隐藏）
              // —— 一屏「--」只会显得表单没填完，档案页应该显得完整。
              // 年龄/性别永远有值，撑住卡片下限。
              for (var i = 0; i < basicRows.length; i++) ...[
                if (i > 0) const RowDivider(),
                basicRows[i],
              ],
              if ((pet.chipNo ?? '').trim().isNotEmpty) ...[
                const RowDivider(),
                InfoRow(L.t('profile.field.chip'), pet.chipNo!.trim()),
              ],
              if ((pet.allergy ?? '').trim().isNotEmpty) ...[
                const RowDivider(),
                InfoRow(
                  L.t('profile.field.allergy'),
                  pet.allergy!.trim(),
                  valueColor: AppColors.danger,
                ),
              ],

        // ---- 危险区（删除宠物）----
        //
        // 放在资料页最末尾：删除不可逆，位置该反映操作频率 —���
        // 「归档」是日常操作，「删除」一年可能做一次。
        //
        // DeletePetButton 这个组件之前写好了却从没被挂进任何页面，
        // 所以 iOS 上根本找不到删除入口 —— 挂在���里。
        _dangerZone(context),
            ],
          ),
        ),

        // ---- 个性特点 ----
        const SizedBox(height: AppSpace.gapXl),
        Text(
          L.t('profile.section.traits'),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.gapM),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpace.gapL),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: AppColors.border),
          ),
          child: traits.isEmpty
              ? Text(
                  L.t('profile.traits.empty'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                )
              : Wrap(
                  spacing: AppSpace.gapS,
                  runSpacing: AppSpace.gapS,
                  children: [
                    for (final code in traits)
                      SoftTag(
                        personalityLabel(code),
                        color: AppColors.primary,
                        bg: AppColors.primaryLight,
                      ),
                  ],
                ),
        ),

        // ---- 家庭成员 ----
        const SizedBox(height: AppSpace.gapXl),
        Text(
          L.t('profile.section.family'),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.gapM),
        _FamilyCard(pet: pet),

        // ---- 文档原件 ----
        const SizedBox(height: AppSpace.gapXl),
        Text(
          L.t('profile.section.documents'),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.gapM),
        _DocumentsCard(pet: pet),

        // ---- 提醒计划（这个 App 的核心价值，不能因为改版就藏起来） ----
        const SizedBox(height: AppSpace.gapXl),
        Text(
          L.t('profile.reminders'),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpace.gapM),
        _RemindersCard(pet: pet),

        // ---- 遛狗记录 ----
        const SizedBox(height: AppSpace.gapXl),
        // 遛狗没开时整块不出现，见 feature_flags.dart。
        if (kWalkEnabled) ...[
          Text(
            L.t('profile.section.walks'),
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpace.gapM),
          _WalksCard(petId: pet.id, petName: pet.name),
          const SizedBox(height: AppSpace.gapXl),
        ],
        // 导出健康报告：档案 + 台账 + 体重 + 最近记录画成一张彩色长图，
        // 分享给兽医。放在这一组是因为它同样是「低频但重要」的动作。
        Center(
          child: Builder(
            // ⚠️ 这个 Builder 不是多余的：iPad 上唤起分享面板必须锚定一个
            // **可见的源视图**，share_plus 缺 `sharePositionOrigin` 会直接抛
            // `PlatformException: sharePositionOrigin: argument must be set`
            // （手机上也抛，UIActivityViewController 的通用要求）。
            // 传外层的 page context 也能跑，但面板会从页面左上角弹出；
            // 传按钮自己的 context 才符合「从这个按钮弹出来」的直觉。
            builder: (buttonContext) => OutlinedButton.icon(
              onPressed: () => _exportReport(
                buttonContext,
                ref,
                pet,
                shareOrigin: originOf(buttonContext),
              ),
              icon: const Icon(Icons.share_outlined, size: 17),
              label: Text(L.t('report.action')),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.border),
                minimumSize: const Size(0, 42),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.tile),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.gapS),

        // 走失协查卡片和归档放在最后一组：都是低频、且需要确认的动作，
        // 不放在页面显眼处 —— 平时用不到，真要用时一眼能找到就行。
        Center(
          child: OutlinedButton.icon(
            onPressed: () => showLostCardSheet(context, pet),
            icon: const Icon(Icons.priority_high_rounded, size: 17),
            label: Text(L.t('lost.action')),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.danger,
              side: const BorderSide(color: AppColors.border),
              minimumSize: const Size(0, 42),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.tile),
              ),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.gapS),
        Center(
          child: TextButton.icon(
            onPressed: () => _archive(context, ref, pet),
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: Text(L.t('action.archive')),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
          ),
        ),
        DeletePetButton(pet: pet),
      ],
    );
  }

  /// 导出报告并发起分享。
  ///
  /// 成功不需要额外提示 —— 系统分享面板弹出来本身就是反馈。但**失败必须说**：
  /// 登录页刚踩过「错误提示被弹窗挡住、用户以为点了没反应」的坑，别再来一次。
  ///
  /// ⚠️ 原来这里是 `catch (_)`，把真实异常整个丢掉了 —— 界面上只弹一句
  /// "导出失败，请重试"，开发者在真机上没有任何线索可查。**iOS 上导出失败过一次，
  /// 就是因为这个裸捕获**。现在把异常和栈一起打出来，失败原因在日志里一目了然。
  static Future<void> _exportReport(
    BuildContext context,
    WidgetRef ref,
    Pet pet, {
    Rect? shareOrigin,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(appActionsProvider)
          .exportPetReport(pet, shareOrigin: shareOrigin ?? originOf(context));
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ [exportPetReport] 失败：$e\n$st');
      debugPrint('❌ [exportPetReport] 失败：$e');
      debugPrintStack(stackTrace: st, label: '[exportPetReport]');
      messenger.showSnackBar(
        SnackBar(
          content: Text(L.t('report.failed')),
          // 真机排查时能直接把详情复制出来，不用截屏。
          action: SnackBarAction(
            label: L.t('common.copyDetail'),
            onPressed: () => _copyDetail(context, e, st),
          ),
        ),
      );
    }
  }

  /// 把异常与栈复制到剪贴板。
  ///
  /// 侧载包在真机上跑，开发者不一定连着 Xcode —— 拿不到控制台日志。
  /// 让用户能自己把详情捞出来，这是唯一在没有 Xcode 的情况下拿到异常的办法。
  static Future<void> _copyDetail(BuildContext context, Object e, StackTrace st) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: '[exportPetReport] $e\n\n$st'),
    );
    messenger.showSnackBar(SnackBar(content: Text(L.t('common.detailCopied'))));
  }

  /// 基本信息行：没填的字段直接跳过，不摆「--」。
  ///
  /// breed 是用户自填的自由文本（录入「疫苗」就是「疫苗」），这里不做
  /// 智能纠正 —— 数据修正交给 M2.2 的编辑功能，界面只负责不展示空值。
  static List<Widget> _basicRows(Pet pet, double? latestWeight, WeightUnit unit) {
    return [
      if ((pet.breed ?? '').trim().isNotEmpty)
        InfoRow(L.t('profile.field.breed'), pet.breed!.trim()),
      if (pet.birthday != null)
        InfoRow(L.t('profile.field.birthday'), _birthdayValue(pet)),
      InfoRow(L.t('profile.field.age'), _ageValue(pet)),
      InfoRow(L.t('profile.field.gender'), _genderValue(pet)),
      if (latestWeight != null)
        InfoRow(
          L.t('profile.field.weight'),
          Units.formatWeight(latestWeight, unit),
        ),
      if (pet.weightBaseline != null)
        InfoRow(L.t('profile.field.shape'), _shapeValue(pet)),
      if ((pet.color ?? '').trim().isNotEmpty)
        InfoRow(L.t('profile.field.color'), pet.color!.trim()),
    ];
  }

  static String _birthdayValue(Pet pet) {
    final b = pet.birthday;
    if (b == null) return '--';
    final base = '${b.year}年${b.month}月${b.day}日';
    if (!pet.birthdayEstimated) return base;
    return L.isZh ? '$base（估算）' : '$base (est.)';
  }

  // 也走统一的 petAgeLabel：原先用 Pet.ageInMonths，那个属性只看年月不看日，
  // 月末会多算一个月，和同屏头部显示的年龄可能差一岁。
  static String _ageValue(Pet pet) =>
      petAgeLabel(pet.birthday, DateTime.now()) ?? '--';

  static String _genderValue(Pet pet) {
    final g = (pet.gender ?? '').trim().toLowerCase();
    final base = switch (g) {
      'female' || 'f' || '母' || '雌' => L.t('profile.gender.female'),
      'male' || 'm' || '公' || '雄' => L.t('profile.gender.male'),
      _ => L.t('profile.gender.unknown'),
    };
    if (base == L.t('profile.gender.unknown')) return base;
    return pet.neutered
        ? '$base（${L.t('profile.neuteredSuffix')}）'
        : base;
  }

  /// 体型从体重基线推断。没有基线就不猜。
  static String _shapeValue(Pet pet) {
    final kg = pet.weightBaseline;
    if (kg == null) return '--';
    if (pet.species == Species.cat) return L.t('profile.shape.cat');
    if (kg >= 20) return L.t('profile.shape.large');
    if (kg >= 10) return L.t('profile.shape.medium');
    return L.t('profile.shape.small');
  }

  Future<void> _archive(BuildContext context, WidgetRef ref, Pet pet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('action.archive')),
        content: Text(
          L.isZh
              ? '归档后 ${pet.name} 不再出现在列表里，但记录会保留，可以随时恢复。'
              : '${pet.name} will be hidden from the list. Records are kept and can be restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('action.archive')),
          ),
        ],
      ),
    );

    if (ok != true) return;
    await ref.read(petRepositoryProvider).archive(pet.id);
    ref.invalidate(petsProvider);
    ref.invalidate(upcomingRemindersProvider);
  }

  /// 资料页末尾：删除宠物。
  ///
  /// ## 为什么放在最后而不是顶部
  ///
  /// 删除不可逆（只能先归档、确认没用再删）。放在显眼处容易被误触 ——
  /// 「归档」是日常操作，「删除」是一年可能做一次的事，位置该反映频率。
  ///
  /// ## 为什么这个组件之前是死的
  ///
  /// `DeletePetButton` 写好了但**从没被挂进任何页面**，
  /// 所以 iOS 上根本找不到删除入口。这里是它该在的地方。
  Widget _dangerZone(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 8),
      child: Column(
        children: [
          const Divider(),
          const SizedBox(height: AppSpace.gapM),
          DeletePetButton(pet: pet),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 健康页签

/// 章节小标题。资料页签里同样的样式写了四遍，这里收成一个。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      );
}

/// 健康页签：预防保健状态 + 体重趋势 + 过敏 + 病史。
///
/// 四块都是**已发生或已排期的事实**，不给健康评分。
/// 「状态：良好」这种自评标签在首页已经删了，这里更不能有。
class _HealthTab extends ConsumerWidget {
  const _HealthTab({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapL,
        AppSpace.page,
        96,
      ),
      children: [
        MedicationCoursesLink(pet: pet),
        const SizedBox(height: AppSpace.gapL),
        _SectionTitle(L.t('profile.section.quick')),
        const SizedBox(height: AppSpace.gapM),
        _QuickRecordBar(petId: pet.id),

        const SizedBox(height: AppSpace.gapXl),
        _SectionTitle(L.t('profile.section.preventive')),
        const SizedBox(height: AppSpace.gapM),
        _CareLedgerCard(pet: pet),
        const SizedBox(height: AppSpace.gapS),
        // 把「排期从哪来」讲清楚：它跟着出生日期算，不是我们拍脑袋定的。
        // 顺带把「记一笔」的作用说明白 —— 否则用户只会用提醒，不用记录，
        // 台账的「上次」永远是空的。
        Text(
          L.t('profile.ledger.hint'),
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: AppColors.textTertiary,
          ),
        ),

        const SizedBox(height: AppSpace.gapXl),
        _SectionTitle(L.t('records.weight.title')),
        const SizedBox(height: AppSpace.gapM),
        // 直接复用记录页那张图，不在这里另写一份图表 —— 两处画法不同
        // 迟早会漂移。
        WeightChartCard(petId: pet.id),

        const SizedBox(height: AppSpace.gapXl),
        _SectionTitle(L.t('profile.field.allergy')),
        const SizedBox(height: AppSpace.gapM),
        _AllergyCard(pet: pet),

        const SizedBox(height: AppSpace.gapXl),
        _SectionTitle(L.t('profile.section.medical')),
        const SizedBox(height: AppSpace.gapM),
        _MedicalCard(pet: pet),

        const SizedBox(height: AppSpace.gapXl),
        // 合规：排期是建议，不是诊断。放在这一页的结尾，别只藏在「我的」。
        _PlainHint(
          icon: Icons.info_outline_rounded,
          text: L.t('me.disclaimer.short'),
        ),
      ],
    );
  }
}

/// 快捷记录条 —— 从健康页直接开对应的录入表单。
///
/// 为什么不走通用「记一笔」再让用户挑类型：这一页要记的就这四样，
/// 摆成一行比「点 + → 在九个类型里找驱虫」少两步。`showAddRecordSheet`
/// 本来就收 `initialType`，只是之前没人从这一页调。
class _QuickRecordBar extends ConsumerWidget {
  const _QuickRecordBar({required this.petId});

  final String petId;

  /// (落到的记录类型, 按钮文案 key)。
  ///
  /// 疫苗和驱虫用台账那套名字：`recordTypeLabel(vaccine)` 返回的是
  /// 「核心疫苗」，那是规则集里的细分名，摆在按钮上太窄。
  static const _items = <(RecordType, String)>[
    (RecordType.weight, 'addRecord.type.weight'),
    (RecordType.vaccine, 'profile.care.vaccine'),
    (RecordType.dewormInternal, 'profile.care.dewormInternal'),
    (RecordType.medical, 'addRecord.type.medical'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: AppSpace.gapS,
      runSpacing: AppSpace.gapS,
      children: [
        for (final (type, labelKey) in _items)
          ActionChip(
            avatar: Icon(
              recordTypeIcon(type),
              size: 16,
              color: AppColors.primary,
            ),
            label: Text(L.t(labelKey)),
            onPressed: () => showAddRecordSheet(
              context,
              ref,
              petId: petId,
              initialType: type,
            ),
          ),
      ],
    );
  }
}

/// 预防保健台账 —— 「上次」与「下次」并排。
///
/// 与资料页签的「提醒计划」不重复：那边是**开关**（管要不要提醒），
/// 这里是**对账**（已发生 vs 已排期）。
///
/// 旧版这一块只读 reminders，于是「打过疫苗但没排计划」和
/// 「有计划但压根没打」在界面上长得一模一样，都只是「有一行」。
/// 台账把 records 也拉进来，两种情况的差别才看得见。
class _CareLedgerCard extends ConsumerWidget {
  const _CareLedgerCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records =
        ref.watch(petRecordsProvider(pet.id)).valueOrNull ?? const <PetRecord>[];
    final reminders = ref.watch(petRemindersProvider(pet.id)).valueOrNull ??
        const <Reminder>[];

    // 映射与合并都走 domain —— 导出报告用的是同一份，别在这里再写一遍。
    final inputs = ledgerInputs(
      records: records,
      reminders: reminders,
      summaryOf: _factSummary,
    );
    final rows = buildCareLedger(
      facts: inputs.facts,
      schedules: inputs.schedules,
    );

    // 疫苗和体检对所有物种都成立，永远给一行；驱虫两行只在有内容时出现 ——
    // 一只从没驱过虫、也没排期的宠物，摆两行「还没有记录」纯属噪音。
    // 入口没丢：上面那排快捷记录里就有驱虫。
    final visible = rows
        .where((r) =>
            r.kind == PlanItemType.vaccine ||
            r.kind == PlanItemType.checkup ||
            !r.isEmpty)
        .toList();

    final now = DateTime.now();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: AppSpace.gapXs,
      ),
      child: Column(
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) const RowDivider(),
            _row(context, ref, visible[i], now),
          ],
        ],
      ),
    );
  }

  /// 单行。抽成方法是为了让回调捕获**参数**而不是循环变量 ——
  /// 「记一笔」在点击时才求值，若它捕获的是 `i`，越界只是时间问题。
  Widget _row(
    BuildContext context,
    WidgetRef ref,
    CareLedgerRow row,
    DateTime now,
  ) {
    return _CareLedgerRowView(
      row: row,
      now: now,
      onLog: () => showAddRecordSheet(
        context,
        ref,
        petId: pet.id,
        initialType: _recordTypeForCare(row.kind),
      ),
    );
  }

  /// 行内副文本：优先用户写的（疫苗名 / 就诊原因），其次 payload 摘要
  /// （剂量、给药方式这类结构化字段）。
  static String? _factSummary(PetRecord r) {
    final text = (r.valueText ?? '').trim();
    if (text.isNotEmpty) return text;
    final payload = recordPayloadSummary(r).trim();
    return payload.isEmpty ? null : payload;
  }
}

/// 台账分类 → 打开录入表单时预选的记录类型。
///
/// 体检排期的实际发生落在「就诊」上 —— 没有独立的体检记录类型，
/// 也不该为它单开一个：用户心里「带去医院」就是一件事。
RecordType _recordTypeForCare(PlanItemType kind) => switch (kind) {
      PlanItemType.vaccine => RecordType.vaccine,
      PlanItemType.dewormInternal => RecordType.dewormInternal,
      PlanItemType.dewormExternal => RecordType.dewormExternal,
      PlanItemType.checkup => RecordType.medical,
      PlanItemType.grooming => RecordType.grooming,
    };

/// 台账一行：图标 + 分类名 + 「上次」+ 「下次」+ 记一笔。
class _CareLedgerRowView extends StatelessWidget {
  const _CareLedgerRowView({
    required this.row,
    required this.now,
    required this.onLog,
  });

  final CareLedgerRow row;
  final DateTime now;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    final overdue = row.isOverdue(now);
    final last = row.lastDoneAt;
    final lastSummary = row.lastSummary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: overdue
                  ? AppColors.dangerBg
                  : AppColors.tileTints[
                      row.kind.hashCode.abs() % AppColors.tileTints.length],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              careKindIcon(row.kind),
              size: 16,
              color: overdue ? AppColors.danger : AppColors.primary,
            ),
          ),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        careKindLabel(row.kind),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    // 「关了提醒」不等于「不用做」，所以行还在，只是标出来。
                    if (row.hasSchedule && !row.scheduleEnabled) ...[
                      const SizedBox(width: AppSpace.gapS),
                      SoftTag(
                        L.t('profile.care.off'),
                        color: AppColors.textTertiary,
                        bg: AppColors.divider,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  last == null
                      ? L.t('profile.care.lastNone')
                      : L.tp('profile.care.last', {
                          'v': lastSummary == null
                              ? relativeDay(last)
                              : '${relativeDay(last)} · $lastSummary',
                        }),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.nextDueAt == null
                      ? L.t('profile.care.unscheduled')
                      : L.tp('profile.care.next', {
                          'v': dueLabel(row.nextDueAt!),
                        }),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: overdue ? FontWeight.w600 : FontWeight.w400,
                    color:
                        overdue ? AppColors.danger : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.gapS),
          // 「记一笔」是这一行的重点：台账的「上次」全靠用户补上来，
          // 没有这个按钮，它永远停在「还没有记录」。
          TextButton(
            onPressed: onLog,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.gapS),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              L.t('profile.care.log'),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 过敏。没有记录就明说没有，不摆占位符。
class _AllergyCard extends StatelessWidget {
  const _AllergyCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context) {
    final allergy = (pet.allergy ?? '').trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.gapL),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: allergy.isEmpty
          ? Text(
              L.t('profile.allergy.empty'),
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            )
          : Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 18, color: AppColors.danger),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Text(
                    allergy,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 病史：type == medical 的记录按时间倒序。
///
/// 只列就诊，不掺疫苗和驱虫 —— 那些归「预防保健」和记录页，
/// 混在一起会让「看过几次病」这个问题变得答不上来。
class _MedicalCard extends ConsumerWidget {
  const _MedicalCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(petRecordsProvider(pet.id)).valueOrNull ??
        const <PetRecord>[];
    final visits = all.where((r) => r.type == RecordType.medical).toList();

    if (visits.isEmpty) {
      return _PlainHint(
        icon: Icons.local_hospital_outlined,
        text: L.t('profile.medical.empty'),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: AppSpace.gapXs,
      ),
      child: Column(
        children: [
          for (var i = 0; i < visits.length; i++) ...[
            if (i > 0) const RowDivider(),
            _VisitRow(record: visits[i]),
          ],
        ],
      ),
    );
  }
}

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.record});

  final PetRecord record;

  @override
  Widget build(BuildContext context) {
    final reason = (record.valueText ?? '').trim();
    final note = (record.note ?? '').trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reason.isEmpty ? L.t('addRecord.type.medical') : reason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                if (note.isNotEmpty)
                  Text(
                    note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.gapM),
          Text(
            relativeDay(record.recordedAt),
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 家庭成员

class _FamilyCard extends ConsumerWidget {
  const _FamilyCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 待接受的成员也一并显示（下面标「待接受」）—— 否则邀请发出去之后
    // 发起人看不到任何变化，会以为没成功，转头再邀请一次。
    final members = ref.watch(petMembersProvider(pet.id)).valueOrNull ??
        const <PetMember>[];

    // 至少显示当前用户一条 —— 创建者一定在，否则共养无从谈起。
    final rows = <({String name, String role, IconData icon})>[
      (
        name: L.t('profile.member.you'),
        role: L.t('profile.role.primary'),
        icon: Icons.star_rounded,
      ),
      for (final m in members)
        if (m.role != MemberRole.owner)
          (
            name: m.userId,
            role: m.status == MemberStatus.pending
                ? L.t('members.status.pending')
                : L.t('profile.role.member'),
            icon: Icons.person_rounded,
          ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: AppSpace.gapM,
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const RowDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryLight,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(rows[i].icon,
                        size: 18, color: AppColors.primary),
                  ),
                  const SizedBox(width: AppSpace.gapM),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rows[i].name,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          rows[i].role,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpace.gapS),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => showMembersSheet(context, pet: pet),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
              label: Text(L.t('profile.addFamily')),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.border),
                minimumSize: const Size(0, 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.tile),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 提醒计划

/// 规则集排了、但这只宠物还没有的排期类型（wire 名）。
///
/// 纯计算，不写库。用途：装新版本后**存量宠物不会自动获得新增的排期项**
/// （排期只在建档 / 首次补生日时生成），比如这次的「洗澡美容」。
/// 界面据此提示「可以补全 N 项」，由用户主动点 —— 不做静默重建，
/// 因为静默重建会把他手动删掉的提醒又变回来。
Set<String> _missingPlanTypes(Pet pet, List<Reminder> existing) {
  final birthday = pet.birthday;
  if (birthday == null) return const <String>{};
  final plan = ruleSetFor(AppRegion.current).buildPlan(
    species: pet.species,
    birthday: birthday,
    now: DateTime.now(),
  );
  final have = existing.map((r) => r.type).toSet();
  return plan.map((e) => e.type.wireName).toSet().difference(have);
}

class _RemindersCard extends ConsumerWidget {
  const _RemindersCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(petRemindersProvider(pet.id));

    final addButton = Padding(
      padding: const EdgeInsets.only(top: AppSpace.gapM),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => showReminderSheet(context, pet: pet),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(L.t('reminder.add')),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            side: const BorderSide(color: AppColors.border),
            minimumSize: const Size(0, 42),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.tile),
            ),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );

    return reminders.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text('$e'),
      data: (list) {
        // 规则集排了、但这条宠物还没有的项（例如这次新增的洗澡美容）。
        // 存量宠物不会自动拥有，给一个**显式**的补全入口 —— 不做静默重建，
        // 那会把他手动删掉的提醒又变回来。
        final missing = _missingPlanTypes(pet, list);
        final fillButton = missing.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: AppSpace.gapS),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    // await 之前先抓住 messenger，别在 await 之后碰 context。
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final n = await ref
                          .read(appActionsProvider)
                          .generatePlanFor(pet);
                      messenger.showSnackBar(SnackBar(
                        content:
                            Text(L.tp('reminder.fillPlanDone', {'n': n})),
                      ));
                    },
                    icon: const Icon(Icons.auto_awesome_outlined, size: 16),
                    label:
                        Text(L.tp('reminder.fillPlan', {'n': missing.length})),
                  ),
                ),
              );

        if (list.isEmpty) {
          return Column(
            children: [
              _PlainHint(
                icon: Icons.notifications_none_rounded,
                text: L.isZh
                    ? '还没有提醒。填了生日会自动生成疫苗和驱虫计划，也可以自己加一条。'
                    : 'No reminders yet. A birthday generates a plan, or add your own.',
              ),
              if (fillButton != null) fillButton,
              addButton,
            ],
          );
        }

        final sorted = [...list]..sort((a, b) => a.nextAt.compareTo(b.nextAt));
        final now = DateTime.now();

        return Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: AppRadius.cardBorder,
                border: Border.all(color: AppColors.border),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.gapL,
                vertical: AppSpace.gapXs,
              ),
              child: Column(
                children: [
                  for (var i = 0; i < sorted.length; i++) ...[
                    if (i > 0) const RowDivider(),
                    _ReminderRow(
                      reminder: sorted[i],
                      pet: pet,
                      overdue: sorted[i].nextAt.isBefore(now),
                    ),
                  ],
                ],
              ),
            ),
            if (fillButton != null) fillButton,
            addButton,
          ],
        );
      },
    );
  }
}

class _ReminderRow extends ConsumerWidget {
  const _ReminderRow({
    required this.reminder,
    required this.pet,
    required this.overdue,
  });

  final Reminder reminder;
  final Pet pet;
  final bool overdue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manual = reminder.source == 'manual';
    final canWrite = ref.watch(petRoleProvider(pet.id)).valueOrNull?.canWrite == true;

    return InkWell(
      // 点进编辑，长按删除 —— 列表行放不下两个按钮，
      // 而「删除」是低频且危险的动作，长按是合适的门槛。
      onTap: canWrite ? () => showReminderSheet(context, pet: pet, existing: reminder) : null,
      onLongPress: canWrite ? () => _confirmDelete(context, ref) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: overdue ? AppColors.dangerBg : AppColors.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                overdue
                    ? Icons.error_outline_rounded
                    : reminderTypeIcon(reminder.type),
                size: 16,
                color: overdue ? AppColors.danger : AppColors.primary,
              ),
            ),
            const SizedBox(width: AppSpace.gapM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reminderTitle(reminder),
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      '${_short(reminder.nextAt)} · ${dueLabel(reminder.nextAt)}',
                      if (reminder.isRecurring)
                        L.tp('reminder.repeat.everyNDays',
                            {'n': reminder.everyDays}),
                      // 手动建的标一下来源，方便和系统生成的区分开
                      if (manual) L.t('reminder.source.manual'),
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: overdue
                          ? AppColors.danger
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: reminder.enabled,
              onChanged: !canWrite ? null : (v) async {
                // 走 updateReminder 而不是只改库里的 enabled：它会顺带
                // 撤掉/重排本地通知。只写数据的话，关掉的提醒照样会弹。
                try {
                  final actions = ref.read(appActionsProvider);
                  if (reminder.rule['mode'] == 'medication') {
                    await actions.toggleMedicationCourse(reminder, v);
                  } else {
                    await actions.updateReminder(reminder.copyWith(enabled: v));
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.error(e))));
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('reminder.deleteConfirm')),
        content: Text(L.t('reminder.deleteConfirm.hint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(L.t('reminder.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(appActionsProvider).deleteReminder(reminder);
  }

  static String _short(DateTime d) =>
      '${d.year}-${_p(d.month)}-${_p(d.day)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}

// ------------------------------------------------------------------ 遛狗记录

class _WalksCard extends ConsumerWidget {
  const _WalksCard({required this.petId, this.petName});

  final String petId;

  /// 分享轨迹时要在文案里带上名字，取不到就留空。
  final String? petName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walks = ref.watch(petWalksProvider(petId)).valueOrNull ??
        const <WalkSession>[];
    const region = AppRegion.current;
    final unit = Units.defaultDistanceUnit(region);

    if (walks.isEmpty) {
      return _PlainHint(
        icon: Icons.directions_walk_rounded,
        text: L.t('profile.walk.empty'),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: AppSpace.gapXs,
      ),
      child: Column(
        children: [
          for (var i = 0; i < walks.take(5).length; i++) ...[
            if (i > 0) const RowDivider(),
            Builder(builder: (_) {
              final w = walks[i];
              final (h, m) = Units.splitDuration(w.durationS);
              final dur = h > 0 ? '${h}h ${m}m' : '${m}m';
              return InkWell(
                onTap: () => showWalkDetailSheet(
                  context,
                  session: w,
                  petName: petName,
                ),
                child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.directions_walk_rounded,
                        size: 17, color: AppColors.primary),
                    const SizedBox(width: AppSpace.gapM),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  relativeDay(w.startedAt),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              // 心情是结束后补填的，没填就不占位
                              if ((w.mood ?? '').isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Text(
                                  walkMoodEmoji(w.mood!),
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ],
                          ),
                          if ((w.note ?? '').isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              w.note!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Text(
                      '${Units.formatDistance(w.distanceM, unit)} · $dur',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 记录页签

/// 记录页签：这只宠物**已经完成**的条目，按时间倒序，点进详情。
///
/// 与底部「记录」Tab 的分工：那边是全宇宙（筛选、搜索、补录入口都在那），
/// 这边只回答「这只宠物都发生过什么」—— 换个宠物就是另一段历史。
/// 渲染直接复用 [RecordTimeline]，不另写一套。
class _RecordsTab extends ConsumerWidget {
  const _RecordsTab({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(petRecordsProvider(pet.id));

    return records.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
        if (list.isEmpty) {
          return const _TabEmpty(
            icon: Icons.checklist_rounded,
            titleKey: 'profile.records.empty',
            hintKey: 'profile.records.emptyHint',
          );
        }
        final sorted = [...list]
          ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            AppSpace.gapL,
            AppSpace.page,
            96,
          ),
          children: [RecordTimeline(records: sorted)],
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 回忆页签

/// 回忆页签：这只宠物的照片墙。
///
/// 数据源是**记录上的附件**，不另存一份。这样「回忆」不是又一个需要维护的
/// 功能，而是记录页的另一种读法 —— 用户随手给记录加的照片，攒起来就是相册，
/// 不用逼他「先建相册再传图」。
///
/// 但「另一种读法」不等于**只读**：只读的相册是个死胡同，用户在这里看到
/// 空态、被告知「给记录加张照片」，却找不到入口。所以这里自带添加入口，
/// 并且每个格子点得进它所属的那条记录（改时间、删照片都在那边）。
class _MemoriesTab extends ConsumerWidget {
  const _MemoriesTab({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photos = ref.watch(petPhotosProvider(pet.id));
    // 记录也读一份，用来把格子映射回所属记录 —— 不然点开没东西可点。
    // 记录页签本来就在 watch 它，这里不额外查库。
    final records =
        ref.watch(petRecordsProvider(pet.id)).valueOrNull ?? const <PetRecord>[];
    final recordById = {for (final r in records) r.id: r};

    return photos.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (list) {
        // 只留**本地文件真的在**的那些 —— 附件行可能在（同步过来的、
        // 或者用户清过存储），文件却没了，那种格子只会是一块灰。
        final visible = [
          for (final att in list)
            if ((att.localPath ?? '').trim().isNotEmpty &&
                File(att.localPath!).existsSync())
              att,
        ];

        if (visible.isEmpty) {
          return _TabEmpty(
            icon: Icons.photo_album_outlined,
            titleKey: 'profile.memory.empty',
            hintKey: 'profile.memory.emptyHint',
            action: FilledButton.icon(
              onPressed: () => _addMemoryPhoto(context, ref, pet),
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: Text(L.t('profile.memory.add')),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            AppSpace.gapL,
            AppSpace.page,
            96,
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.tp('profile.memory.count', {'n': '${visible.length}'}),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _addMemoryPhoto(context, ref, pet),
                  icon: const Icon(Icons.add_a_photo_outlined, size: 17),
                  label: Text(L.t('profile.memory.add')),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.gapM),
            _PhotoGrid(
              attachments: visible,
              onTap: (att) {
                final record = recordById[att.recordId];
                if (record != null) {
                  showRecordDetailSheet(context, ref, record: record);
                }
              },
            ),
          ],
        );
      },
    );
  }
}

/// 从「回忆」页加照片：拍照 / 相册 → 建一条带图的记录。
///
/// 附件在数据模型上**必须挂在一条记录上**（`attachments.record_id` 非空），
/// 所以这里会顺带建一条 `note` 记录当载体 —— 用户看到的是「加了张照片」，
/// 不是「建了条笔记」；那条记录在时间线里显示成「照片」。
Future<void> _addMemoryPhoto(
  BuildContext context,
  WidgetRef ref,
  Pet pet,
) async {
  // 弹层一关，context 可能已经失效。**在任何 await 之前**把 messenger
  // 抓在手里，后面全程不再碰 context —— 免得靠 `context.mounted` 事后补救。
  final messenger = ScaffoldMessenger.of(context);
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_rounded),
            title: Text(L.t('detail.photos.camera')),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: Text(L.t('detail.photos.gallery')),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return;

  try {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2048,
      imageQuality: 85,
    );
    if (picked == null) return;

    await ref.read(appActionsProvider).addPhotoMemory(
          petId: pet.id,
          sourcePath: picked.path,
        );
    messenger.showSnackBar(
      SnackBar(content: Text(L.t('profile.memory.added'))),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

/// 照片网格。三列正方形，间距按页面栅格走。
///
/// 调用方负责过滤掉文件已丢失的附件 —— 这里只管画。
class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({required this.attachments, required this.onTap});

  final List<RecordAttachment> attachments;
  final void Function(RecordAttachment att) onTap;

  @override
  Widget build(BuildContext context) {
    const gap = AppSpace.gapS;
    return LayoutBuilder(
      builder: (context, constraints) {
        const cols = 3;
        final size = (constraints.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final att in attachments)
              GestureDetector(
                onTap: () => onTap(att),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(att.localPath!),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: size,
                      height: size,
                      color: AppColors.divider,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 页签空态。三个页签共用一套，免得每处各写一遍「图标 + 标题 + 两行说明」。
class _TabEmpty extends StatelessWidget {
  const _TabEmpty({
    required this.icon,
    required this.titleKey,
    required this.hintKey,
    this.action,
  });

  final IconData icon;
  final String titleKey;
  final String hintKey;

  /// 空态下的动作按钮。**空态光说明不给出路等于没说** ——
  /// 能加东西的页签（比如回忆）应该在这里就把入口摆出来。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.primaryLight,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: AppColors.primary),
            ),
            const SizedBox(height: AppSpace.gapL),
            Text(
              L.t(titleKey),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpace.gapS),
            Text(
              L.t(hintKey),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpace.gapL),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _PlainHint extends StatelessWidget {
  const _PlainHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.gapL),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textTertiary),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 费用页签

/// 费用页签：本月汇总 + 近半年趋势 + 分类占比 + 明细。
///
/// **不做预算、不做预警**：我们没有「该花多少」的任何依据，给个
/// 「本月超支」的红字就是拍脑袋。这里只回答两个问题——花了多少、花在哪。
///
/// **不做币种换算**：汇率是外部数据，本 App 没有来源，换算出来的数字
/// 就是编的。记的时候是什么币种，看的时候就是什么币种。
class _ExpenseTab extends ConsumerWidget {
  const _ExpenseTab({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = AppRegion.current.defaultCurrency;
    final expenses =
        ref.watch(petExpensesProvider(pet.id)).valueOrNull ?? const <Expense>[];
    final summary = ref.watch(expenseSummaryProvider(pet.id));

    return summary.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpace.gapXl),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(AppSpace.page),
        child: _PlainHint(icon: Icons.error_outline_rounded, text: '$e'),
      ),
      data: (s) => ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          AppSpace.gapL,
          AppSpace.page,
          96,
        ),
        children: [
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: () => showAddExpenseSheet(context, ref, petId: pet.id),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(L.t('expense.add')),
            ),
          ),

          if (s.isEmpty) ...[
            const SizedBox(height: AppSpace.gapXl),
            _PlainHint(
              icon: Icons.payments_outlined,
              text: L.t('expense.empty.hint'),
            ),
          ] else ...[
            const SizedBox(height: AppSpace.gapL),
            _ExpenseHeadCard(summary: s, currency: currency),

            if (s.months.any((m) => m.total > 0)) ...[
              const SizedBox(height: AppSpace.gapXl),
              _SectionTitle(L.t('expense.trend')),
              const SizedBox(height: AppSpace.gapM),
              _ExpenseTrendCard(summary: s, currency: currency),
            ],

            if (s.byCategory.isNotEmpty) ...[
              const SizedBox(height: AppSpace.gapXl),
              _SectionTitle(L.t('expense.byCategory')),
              const SizedBox(height: AppSpace.gapM),
              _ExpenseCategoryCard(summary: s, currency: currency),
            ],

            if (expenses.isNotEmpty) ...[
              const SizedBox(height: AppSpace.gapXl),
              _SectionTitle(L.t('expense.recent')),
              const SizedBox(height: AppSpace.gapM),
              _ExpenseListCard(
                petId: pet.id,
                expenses: expenses.take(10).toList(),
                currency: currency,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 汇总卡：本月大数字 + 累计 + 月均。
///
/// 月均的分母刻意取「有支出的月份数」而不是「6」：App 装了半年只记过
/// 一个月的账，除以 6 会得出一个低得离谱的数字，比不显示更误导。
class _ExpenseHeadCard extends StatelessWidget {
  const _ExpenseHeadCard({required this.summary, required this.currency});

  final ExpenseSummary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.gapL),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                L.t('expense.thisMonth'),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                L.tp('expense.count', {'n': summary.monthCount}),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gapXs),
          Text(
            formatMoney(summary.monthTotal, currency),
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpace.gapM),
          const RowDivider(),
          const SizedBox(height: AppSpace.gapM),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: L.t('expense.allTime'),
                  value: formatMoney(summary.allTotal, currency),
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: L.t('expense.avgMonth'),
                  value: formatMoney(summary.avgPerActiveMonth, currency),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      );
}

/// 近半年柱状图。
///
/// 纵轴不标刻度：金额的量级差异很大（几十到几千），固定刻度要么全是 0
/// 要么挤成一团；柱高本身已经能看出高低，具体数字在下面的列表里。
class _ExpenseTrendCard extends StatelessWidget {
  const _ExpenseTrendCard({required this.summary, required this.currency});

  final ExpenseSummary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final maxV = summary.months
        .map((m) => m.total)
        .fold(0.0, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gapM,
        AppSpace.gapL,
        AppSpace.gapL,
        AppSpace.gapXs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: SizedBox(
        height: 150,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            // 顶部留 20% 空隙，最高的那根不会贴着卡片边。
            maxY: maxV * 1.2,
            minY: 0,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: maxV <= 0 ? 1 : maxV / 3,
              getDrawingHorizontalLine: (_) => const FlLine(
                color: AppColors.divider,
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            // 柱子矮的时候点不到，而数字在下面列表里都有，关掉省事。
            barTouchData: BarTouchData(enabled: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: const AxisTitles(),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 24,
                  getTitlesWidget: (v, meta) {
                    final i = v.round();
                    if (i < 0 || i >= summary.months.length) {
                      return const SizedBox.shrink();
                    }
                    final m = summary.months[i];
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        L.tp('expense.month.short', {'m': m.month}),
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < summary.months.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: summary.months[i].total,
                      width: 16,
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分类占比：横条而不是饼图。
///
/// 八个分类里经常只有两三个有值，饼图上剩下的碎块既看不出是什么、
/// 也点不中；横条还能顺带把金额对齐成一列，扫读更快。
class _ExpenseCategoryCard extends StatelessWidget {
  const _ExpenseCategoryCard({required this.summary, required this.currency});

  final ExpenseSummary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: AppSpace.gapM,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < summary.byCategory.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpace.gapS),
            _CategoryBar(
              slice: summary.byCategory[i],
              total: summary.monthTotal,
              currency: currency,
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.slice,
    required this.total,
    required this.currency,
  });

  final ExpenseSlice slice;
  final double total;
  final String currency;

  @override
  Widget build(BuildContext context) {
    // total 为 0 时不可能走到这里（分类有值意味着本月有支出），
    // 但仍挡一下 —— 除零会算出 NaN，宽度 NaN 会让渲染层直接抛。
    final frac = total <= 0 ? 0.0 : (slice.total / total).clamp(0.0, 1.0);

    return Row(
      children: [
        Icon(expenseCategoryIcon(slice.category),
            size: 16, color: AppColors.primary),
        const SizedBox(width: AppSpace.gapS),
        SizedBox(
          width: 72,
          child: Text(
            expenseCategoryLabel(slice.category),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: AppSpace.gapS),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Stack(
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                // 至少留 2px：占比极小时整条变透明，看起来像「没记上」。
                Container(
                  height: 6,
                  width: (c.maxWidth * frac).clamp(2.0, c.maxWidth),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpace.gapS),
        SizedBox(
          width: 76,
          child: Text(
            formatMoney(slice.total, currency),
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 最近支出明细。长按/点删除按钮可删（软删除）。
class _ExpenseListCard extends ConsumerWidget {
  const _ExpenseListCard({
    required this.petId,
    required this.expenses,
    required this.currency,
  });

  final String petId;
  final List<Expense> expenses;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: AppSpace.gapXs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < expenses.length; i++) ...[
            if (i > 0) const RowDivider(),
            _ExpenseRow(
              petId: petId,
              expense: expenses[i],
              currency: currency,
            ),
          ],
        ],
      ),
    );
  }
}

class _ExpenseRow extends ConsumerWidget {
  const _ExpenseRow({
    required this.petId,
    required this.expense,
    required this.currency,
  });

  final String petId;
  final Expense expense;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = (expense.note ?? '').trim();

    return Row(
      children: [
        Icon(expenseCategoryIcon(expense.category),
            size: 18, color: AppColors.textSecondary),
        const SizedBox(width: AppSpace.gapM),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                expenseCategoryLabel(expense.category),
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                note.isEmpty
                    ? compactDate(expense.spentAt)
                    : '${compactDate(expense.spentAt)} · $note',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpace.gapS),
        Text(
          formatMoney(expense.amount, expense.currency.isEmpty
              ? currency
              : expense.currency),
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: 2),
        SizedBox(
          width: 32,
          child: IconButton(
            iconSize: 17,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded,
                color: AppColors.textTertiary),
            tooltip: L.t('expense.delete'),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('expense.delete')),
        content: Text(
          '${expenseCategoryLabel(expense.category)} '
          '${formatMoney(expense.amount, currency)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('action.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(L.t('expense.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(appActionsProvider).deleteExpense(petId, expense.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('expense.deleted'))),
    );
  }
}

// ---------------------------------------------------------------- 文档原件卡

/// 一只宠物的全部文档原件（跨记录）。档案页「资料」页签用。
///
/// 为什么在这里也能加：疫苗本、保单这类东西**不属于任何一次事件**
/// （不是打针那天才有这本本子），让用户先去建一条记录再挂附件，
/// 会让「存个 PDF」变成三步。这里加的会自动建一条载体记录，
/// 之后在记录时间线里同样找得到、删得掉。
///
/// 与记录详情页那份是同一批数据（同一个 provider 家族的不同成员），
/// 不会出现「这边删了那边还在」。
class _DocumentsCard extends ConsumerWidget {
  const _DocumentsCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs =
        ref.watch(petDocumentsProvider(pet.id)).valueOrNull ??
            const <RecordAttachment>[];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.gapL),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (docs.isEmpty)
            Text(
              L.t('detail.documents.empty'),
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            )
          else ...[
            for (var i = 0; i < docs.length; i++) ...[
              if (i > 0) const RowDivider(),
              _DocumentLine(attachment: docs[i]),
            ],
            const SizedBox(height: AppSpace.gapS),
            Text(
              L.t('doc.localOnly'),
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: AppSpace.gapM),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton.icon(
              onPressed: () => _pick(context, ref),
              icon: const Icon(Icons.attach_file_rounded, size: 17),
              label: Text(L.t('detail.documents.add')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    // ⚠️ `openFile` 与 `File.length()` 都在 try 里，理由见 record_detail.dart
    // 的同名方法（那里有完整分析）。
    //
    // **这里曾经漏了。** 之前修「点添加文档没反应」时只改了记录详情页，
    // 忘了宠物档案页也有一模一样的按钮 —— 同一个 bug 修了一半，
    // 于是用户在这边点还是没反应。
    //
    // 教训：`grep 'detail.documents.add'` 找到 N 处就要检查 N 处，
    // 「我改过这个 bug」不等于「这个 bug 修完了」。
    String path;
    String name;
    int size;
    try {
      // 与记录详情页同款（file_selector 官方插件，理由见那边注释）。
      final picked = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: L.t('detail.documents'),
            extensions: kDocumentExtensions,
          ),
        ],
      );
      // null = 用户主动取消，正常路径，静默返回。
      if (picked == null) return;
      if (picked.path.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.t('doc.pickFailed'))),
        );
        return;
      }
      path = picked.path;
      name = picked.name;
      size = await File(path).length();
    } catch (e) {
      // 取消在某些 iOS 版本里是抛异常而非返回 null，单独识别，
      // 别把「用户主动取消」显示成「出错了」。
      final cancelled = e.toString().toLowerCase();
      final isCancel = cancelled.contains('cancel') ||
          cancelled.contains('already_active') ||
          cancelled.contains('user_canceled') ||
          cancelled.contains('inconsistency');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isCancel
              ? L.t('doc.pickCancelled')
              : L.tp('doc.pickError', {'e': '$e'})),
        ),
      );
      return;
    }

    if (size > kMaxDocumentBytes) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.tp('doc.tooLarge', {'n': kMaxDocumentBytes ~/ (1024 * 1024)}),
          ),
        ),
      );
      return;
    }

    try {
      // 不传 recordId：这批文档不属于任何事件，由 Actions 建一条载体记录。
      await ref.read(appActionsProvider).addDocument(
            petId: pet.id,
            sourcePath: path,
            fileName: name,
            mime: mimeOfExt(name),
            sizeBytes: size,
          );
      ref.invalidate(petRecordsProvider(pet.id));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('doc.added'))),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }
}

class _DocumentLine extends StatelessWidget {
  const _DocumentLine({required this.attachment});

  final RecordAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final name = attachmentTitle(attachment);
    final size = fileSizeLabel(attachment.sizeBytes);
    final dot = (attachment.fileName ?? '').lastIndexOf('.');
    final ext = dot < 0 ? '' : attachment.fileName!.substring(dot + 1);

    return InkWell(
      onTap: () async {
        final p = attachment.localPath;
        if (p == null) return;
        await shareFiles(
        files: [XFile(p)],
        subject: name,
        context: context,
      );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.gapS),
        child: Row(
          children: [
            Icon(documentIcon(ext), size: 20, color: AppColors.primary),
            const SizedBox(width: AppSpace.gapM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isEmpty ? L.t('doc.unknownType') : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (size.isNotEmpty)
                    Text(
                      size,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.open_in_new_rounded,
                size: 16, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
