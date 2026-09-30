/// 档案页 —— 单只宠物的完整画像（参考稿右侧那张屏）。
///
/// 版式：
/// 1. 渐变头图 + 圆形大照片（带相机角标）+ 名字 + 品种年龄 + 健康标签
/// 2. 四个分页签：资料 / 健康 / 记录 / 回忆
/// 3. 基本信息卡 —— 标签左、值右，行与行之间用极淡分隔线
/// 4. 个性特点 —— 圆角标签串
/// 5. 家庭成员 —— 头像 + 名字 + 角色，底部一个「添加家庭成员」
///
/// 页签本身要真实存在，用户点得动才知道后面有什么。
/// 资料页和健康页 M1 就有内容；记录页（已完成的条目）与回忆页（相册）
/// 落在 M2/M3，先摆空态 —— 空态也要写清楚「以后这里放什么」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../data/repositories/member_repository.dart';
import '../domain/immunization.dart' show Species;
import '../providers.dart';
import 'records_screen.dart';
import 'sheets.dart';
import 'widgets.dart';

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
              unselectedLabelStyle: const TextStyle(fontSize: 13.5),
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
          _PlaceholderTab(
            icon: Icons.checklist_rounded,
            title: L.t('profile.tab.records'),
            hint: L.isZh
                ? '疫苗、驱虫、用药等已完成的条目按时间排列'
                : 'Completed vaccines, deworming and meds in time order',
          ),
          _PlaceholderTab(
            icon: Icons.photo_album_outlined,
            title: L.t('profile.tab.memory'),
            hint: L.isZh
                ? '把照片按时间聚起来，长成一本相册'
                : 'Photos grouped by time into an album',
          ),
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
        AppSpace.gapS,
        AppSpace.page,
        AppSpace.gapL,
      ),
      child: Column(
        children: [
          // 顶栏：返回位 + 编辑
          Row(
            children: [
              const SizedBox(width: 38),
              const Spacer(),
              TextButton(
                onPressed: () => _editSoon(context),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
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
          const SizedBox(height: AppSpace.gapS),

          // 圆照片 + 相机角标
          Stack(
            clipBehavior: Clip.none,
            children: [
              PetAvatar(pet: pet, size: 96, borderWidth: 4),
              Positioned(
                right: -2,
                bottom: -2,
                child: GestureDetector(
                  onTap: () => _avatarSoon(context),
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
          const SizedBox(height: AppSpace.gapS),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  pet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
          const SizedBox(height: AppSpace.gapS),
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

  static String _ageText(DateTime? birthday) {
    if (birthday == null) return L.t('profile.ageUnknown');
    final now = DateTime.now();
    var months = (now.year - birthday.year) * 12 + (now.month - birthday.month);
    if (now.day < birthday.day) months -= 1;
    if (months < 0) months = 0;
    final y = months ~/ 12;
    final m = months % 12;
    if (y == 0) return L.isZh ? '$m个月' : '${m}mo';
    if (m == 0) return L.isZh ? '$y岁' : '${y}y';
    return L.isZh ? '$y岁$m个月' : '${y}y ${m}mo';
  }

  static String _speciesLabel(Species s) => switch (s) {
        Species.dog => L.t('addPet.species.dog'),
        Species.cat => L.t('addPet.species.cat'),
        Species.other => L.t('addPet.species.other'),
      };

  void _editSoon(BuildContext context) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(L.t('profile.editSoon'))));
  }

  void _avatarSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          L.isZh ? '头像上传在 M2 实现' : 'Avatar upload arrives in M2',
        ),
      ),
    );
  }
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
    final unit = Units.defaultWeightUnit(region, region.name);
    final series = ref.watch(weightSeriesProvider(pet.id)).valueOrNull;
    final latestWeight =
        (series == null || series.isEmpty) ? null : series.last.kg;
    final basicRows = _basicRows(pet, latestWeight, unit);

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
          child: Text(
            L.t('profile.traits.empty'),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
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
        _FamilyCard(petId: pet.id),

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
          _WalksCard(petId: pet.id),
          const SizedBox(height: AppSpace.gapXl),
        ],
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
      ],
    );
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

  static String _ageValue(Pet pet) {
    final m = pet.ageInMonths;
    if (m == null) return '--';
    final y = m ~/ 12;
    final mo = m % 12;
    if (y == 0) return L.isZh ? '$mo 个月' : '$mo mo';
    if (mo == 0) return L.isZh ? '$y 岁' : '$y yr';
    return L.isZh ? '$y 岁 $mo 个月' : '$y yr $mo mo';
  }

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
        _SectionTitle(L.t('profile.section.preventive')),
        const SizedBox(height: AppSpace.gapM),
        _PreventiveCard(pet: pet),

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

/// 预防保健：每条提醒一行，右侧给到期状态（逾期标红）。
///
/// 与资料页签的「提醒计划」不重复：那边是**开关**（管要不要提醒），
/// 这里是**状态**（管还差多久）。同一份数据的两种读法。
class _PreventiveCard extends ConsumerWidget {
  const _PreventiveCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(petRemindersProvider(pet.id)).valueOrNull ??
        const <Reminder>[];

    if (reminders.isEmpty) {
      return _PlainHint(
        icon: Icons.health_and_safety_outlined,
        text: L.t('profile.preventive.empty'),
      );
    }

    final sorted = [...reminders]..sort((a, b) => a.nextAt.compareTo(b.nextAt));
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
          for (var i = 0; i < sorted.length; i++) ...[
            if (i > 0) const RowDivider(),
            _PreventiveRow(
              reminder: sorted[i],
              overdue: sorted[i].nextAt.isBefore(now),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreventiveRow extends StatelessWidget {
  const _PreventiveRow({required this.reminder, required this.overdue});

  final Reminder reminder;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final disabled = !reminder.enabled;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: overdue
                  ? AppColors.dangerBg
                  : AppColors.tileTints[
                      reminder.type.hashCode.abs() % AppColors.tileTints.length],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              reminderTypeIcon(reminder.type),
              size: 16,
              color: overdue ? AppColors.danger : AppColors.primary,
            ),
          ),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Text(
              reminderTitle(reminder),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: disabled ? AppColors.textTertiary : AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.gapS),
          if (disabled)
            SoftTag(
              L.t('profile.healthGood'),
              color: AppColors.textTertiary,
              bg: AppColors.divider,
            )
          else
            Text(
              dueLabel(reminder.nextAt),
              style: TextStyle(
                fontSize: 12,
                fontWeight: overdue ? FontWeight.w600 : FontWeight.w400,
                color: overdue ? AppColors.danger : AppColors.textSecondary,
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
  const _FamilyCard({required this.petId});

  final String petId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(petMembersProvider(petId)).valueOrNull ??
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
            role: L.t('profile.role.member'),
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
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(L.t('profile.member.addSoon'))),
                );
              },
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

class _RemindersCard extends ConsumerWidget {
  const _RemindersCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(petRemindersProvider(pet.id));

    return reminders.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => Text('$e'),
      data: (list) {
        if (list.isEmpty) {
          return _PlainHint(
            icon: Icons.notifications_none_rounded,
            text: L.isZh
                ? '还没有提醒。填了生日就会自动生成疫苗和驱虫计划。'
                : 'No reminders yet. Add a birthday to generate a plan.',
          );
        }

        final sorted = [...list]..sort((a, b) => a.nextAt.compareTo(b.nextAt));
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
              for (var i = 0; i < sorted.length; i++) ...[
                if (i > 0) const RowDivider(),
                _ReminderRow(reminder: sorted[i], overdue: sorted[i].nextAt.isBefore(now)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ReminderRow extends ConsumerWidget {
  const _ReminderRow({required this.reminder, required this.overdue});

  final Reminder reminder;
  final bool overdue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
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
                  : Icons.notifications_none_rounded,
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
                  '${_short(reminder.nextAt)} · ${dueLabel(reminder.nextAt)}',
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
            onChanged: (v) async {
              await ref.read(reminderRepositoryProvider).setEnabled(reminder.id, v);
              ref.invalidate(petRemindersProvider(reminder.petId));
              ref.invalidate(upcomingRemindersProvider);
            },
          ),
        ],
      ),
    );
  }

  static String _short(DateTime d) =>
      '${d.year}-${_p(d.month)}-${_p(d.day)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}

// ------------------------------------------------------------------ 遛狗记录

class _WalksCard extends ConsumerWidget {
  const _WalksCard({required this.petId});

  final String petId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walks = ref.watch(petWalksProvider(petId)).valueOrNull ??
        const <WalkSession>[];
    const region = AppRegion.current;
    final unit = Units.defaultDistanceUnit(region, region.name);

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
              return Padding(
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
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 其他页签

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

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
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpace.gapS),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
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
