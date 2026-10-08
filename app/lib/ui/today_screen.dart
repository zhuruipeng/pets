/// 今日页 —— 回访引擎的入口，也是参考稿的主屏。
///
/// 版式（自上而下，别乱动顺序，这是留存的关键）：
/// 1. 问候语 + 右上角铃铛 —— 每天打开的第一句话
/// 2. 宠物主卡 —— 照片 + 名字 + 品种年龄 + 体重/最近记录，只放查得到的事实
/// 3. 本周概览 —— 遛狗次数 / 记录条数 / 体重较上次，三格真实统计
/// 4. 遛狗入口 —— 进行中时换成渐变大卡
/// 5. 今日待办（横向滚动）—— 每格一张小卡，带类型色底和倒计时
/// 6. 接下来 7 天 —— 预告即将到期的条目
/// 7. 多宠切换条（只有一只时不出现）
///
/// 交互原则不变：待办卡上直接给「完成」，一键收工，完成后原地反馈「下次：X」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_capabilities.dart';
import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../providers.dart';
import 'sheets.dart';
import 'widgets.dart';
import 'family_care_board.dart';
import 'reminder_sheet.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pets = ref.watch(petsProvider);
    final currentPet = ref.watch(currentPetProvider);
    final upcoming = ref.watch(upcomingRemindersProvider);
    final activeWalk = ref.watch(activeWalkProvider);

    return pets.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('${L.t('action.retry')}: $e')),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.pets_outlined,
            title: L.t('profile.empty.title'),
            hint: L.t('profile.empty.hint'),
            action: FilledButton.icon(
              onPressed: () => showAddPetSheet(context, ref),
              icon: const Icon(Icons.add),
              label: Text(L.t('action.add')),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(upcomingRemindersProvider);
            await ref.read(upcomingRemindersProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              AppSpace.gapS,
              AppSpace.page,
              AppSpace.pageBottom,
            ),
            children: [
              const _Greeting(),
              const SizedBox(height: AppSpace.gapL),

              if (currentPet != null) ...[
                _PetHeroCard(pet: currentPet),
                _WeekOverview(pet: currentPet),
                _QuickAddRow(pet: currentPet),
                FamilyCareBoard(pet: currentPet),
                const SizedBox(height: AppSpace.gapL),
              ],

              // 遛狗入口见 feature_flags.dart：GPS 没接之前不能放出来。
              if (AppCapabilities.current.supports(AppFeature.walkTracking))
                _WalkBanner(activeWalk: activeWalk, pet: currentPet),

              upcoming.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(L.error(e)),
                ),
                data: (reminders) => _TodoSection(reminders: reminders),
              ),

              if (list.length > 1) _PetStrip(pets: list, current: currentPet),
            ],
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 问候语

/// 顶部问候。左边汉堡菜单 + 问候语，右边铃铛。
///
/// 汉堡菜单在 M1 只是占位（单页结构没有抽屉），但保留位置，
/// 参考稿里它撑着左侧视觉重量，去掉整行会左轻右重。
class _Greeting extends ConsumerWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pets = ref.watch(petsProvider).valueOrNull ?? const <Pet>[];
    final current = ref.watch(currentPetProvider);

    // M1 还没有账号体系，用「你」占位；参考稿这里是用户的昵称。
    final who = L.isZh ? '你' : 'there';
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? L.t('home.greetingMorning')
        : (hour < 18
            ? L.t('home.greetingAfternoon')
            : L.t('home.greetingEvening'));

    return Row(
      children: [
        _CircleIconButton(
          icon: Icons.menu_rounded,
          onTap: () => _showPetDrawer(context, ref, pets, current),
        ),
        const SizedBox(width: AppSpace.gapM),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$greeting，$who 👋',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                current == null
                    ? L.t('home.subtitleEmpty')
                    : L.tp('home.subtitle', {'name': current.name}),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        _CircleIconButton(
          icon: Icons.notifications_none_rounded,
          onTap: () => _showNotifications(context, ref),
        ),
      ],
    );
  }

  void _showPetDrawer(
    BuildContext context,
    WidgetRef ref,
    List<Pet> pets,
    Pet? current,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _PetSwitcherSheet(
        pets: pets,
        currentId: current?.id,
        onPick: (id) {
          ref.read(selectedPetIdProvider.notifier).state = id;
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Future<void> _showNotifications(BuildContext context, WidgetRef ref) async {
    final reminders = await ref.read(upcomingRemindersProvider.future);
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _NotificationSheet(reminders: reminders),
    );
  }
}

/// 圆形描边图标按钮。参考稿左上/右上都是这个形状，比 IconButton 更轻。
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: AppSpace.tapTarget,
          height: AppSpace.tapTarget,
          child: Icon(icon, size: 21, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 宠物主卡

/// 宠物主卡：左边照片，右边名字 + 品种年龄 + 一行可验证的事实。
///
/// 这里**不放健康评分和活跃度**。理由：
/// - 「状态：良好」是自己给自己打分，没有数据支撑，属于伪指标；
/// - 「活跃度：--」永远填不上值，摆一个恒为占位的格子反而伤可信度。
/// 只陈述查得到的事实（体重、最近一次记录时间），拿不准就显示「--」。
class _PetHeroCard extends ConsumerWidget {
  const _PetHeroCard({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const region = AppRegion.current;
    final unit = Units.defaultWeightUnit(region);
    final records = ref.watch(petRecordsProvider(pet.id)).valueOrNull;
    final latest = _latestWeight(records);

    final weightValue =
        latest == null ? '--' : Units.weightNumber(latest, unit);
    final weightUnit = Units.weightUnitLabel(unit);

    return Container(
      padding: const EdgeInsets.all(AppSpace.gapM),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PetAvatar(pet: pet, size: 48),
              const SizedBox(width: AppSpace.gapM),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            pet.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                              height: 1.15,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
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
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.gapM),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.monitor_weight_outlined,
                  value: weightValue,
                  unit: weightUnit,
                  label: L.t('profile.field.weight'),
                  tint: AppColors.tileTints[0],
                ),
              ),
              const StatDivider(),
              Expanded(
                child: StatTile(
                  icon: Icons.schedule_rounded,
                  value: _latestRecordText(records),
                  label: L.t('home.lastRecord'),
                  tint: AppColors.tileTints[3],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 「金毛猎犬 · 3岁2个月」——品种可能没填，那就只留年龄。
  static String _breedAgeLine(Pet pet) {
    final breed = (pet.breed ?? '').trim();
    final age = _ageText(pet.birthday);
    return breed.isEmpty ? age : '$breed · $age';
  }

  // 与 profile_screen 统一到 domain/labels.dart（原先两处逐字重复）。
  static String _ageText(DateTime? birthday) =>
      petAgeLabel(birthday, DateTime.now()) ?? L.t('profile.ageUnknown');

  /// 最近一条体重记录。没有体重记录时返回 null，界面显示「--」。
  ///
  /// 体重存在 valueNum 里（公制 kg），不是独立字段。
  static double? _latestWeight(List<PetRecord>? records) {
    if (records == null) return null;
    PetRecord? best;
    for (final r in records) {
      if (r.type != RecordType.weight) continue;
      if (r.valueNum == null) continue;
      if (best == null || r.recordedAt.isAfter(best.recordedAt)) best = r;
    }
    return best?.valueNum;
  }

  /// 最近一条记录距今多久。没有记录返回「--」，不编造。
  ///
  /// 今天有记录时带上时刻（「今天 20:42」）—— 只报「今天」信息量太薄，
  /// 用户记了三次就分不清是早上还是刚记的。
  static String _latestRecordText(List<PetRecord>? records) {
    if (records == null || records.isEmpty) return '--';
    var newest = records.first.recordedAt;
    for (final r in records) {
      if (r.recordedAt.isAfter(newest)) newest = r.recordedAt;
    }
    final days = DateTime.now().difference(newest).inDays;
    if (days <= 0) {
      return L.tp('home.lastRecord.todayAt', {'time': _clockText(newest)});
    }
    return L.tp('home.lastRecord.daysAgo', {'n': '$days'});
  }

  /// 中文用 24 小时制，海外用 12 小时制（8:42 PM）。
  static String _clockText(DateTime d) {
    final mm = d.minute.toString().padLeft(2, '0');
    if (L.isZh) {
      return '${d.hour.toString().padLeft(2, '0')}:$mm';
    }
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// 本周概览：遛狗次数 / 记录条数 / 体重较上次。三格全是查得到的统计。
///
/// 为什么只放这三格：
/// - 遛狗次数、记录条数按本周（周一 00:00 起）直接数，没有推算；
/// - 体重报的是最近一次与上一次的差，只给数字不评价好坏 —— 胖了瘦了
///   该由兽医判断，App 不打分。
///
/// 参考稿在这块旁边还挂了个「健康良好」绿标签，那是自己给自己发奖状，
/// 没有数据支撑，不跟。数据没加载出来时显示「--」，不编 0。
class _WeekOverview extends ConsumerWidget {
  const _WeekOverview({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const region = AppRegion.current;
    final unit = Units.defaultWeightUnit(region);

    final walks = ref.watch(petWalksProvider(pet.id)).valueOrNull;
    final records = ref.watch(petRecordsProvider(pet.id)).valueOrNull;
    final series = ref.watch(weightSeriesProvider(pet.id)).valueOrNull;

    final from = _mondayOf(DateTime.now());

    // 用 ?. 而不是 `x == null ? null : x.…`：后者 analyzer 会报
    // prefer_null_aware_operators，而且可读性更差。
    final walkCount = walks?.where((w) => !w.startedAt.isBefore(from)).length;
    final recordCount =
        records?.where((r) => !r.recordedAt.isBefore(from)).length;

    // 第三格：有两磅以上体重才谈「较上次」，只有一条时退回「当前体重」
    // —— 恒为「--」的格子摆在那只会让人怀疑 App 是不是坏了。
    //
    // ⚠️ 三个分支必须覆盖三种状态：null（还在加载）、**空列表**
    // （加载完了但这只宠物还没记过体重）、有数据。漏了空列表就是
    // series.last 直接抛 StateError —— debug 里是红屏一眼能看到，
    // **release 里是一整块灰屏**（2026-10-01 实测：新装用户建完第一只
    // 宠物，首页宠物卡以下全灰，记了第一笔才恢复）。
    final String weightValue;
    final String weightLabel;
    if (series != null && series.length >= 2) {
      final d = _deltaOf(series, unit);
      // 「持平」没有单位；正负差值带上 kg/lb，别让用户猜单位。
      weightValue = d.$2 == null ? d.$1 : '${d.$1} ${d.$2}';
      weightLabel = '${L.t('home.weekWeight')} · ${L.t('home.vsLast')}';
    } else if (series == null || series.isEmpty) {
      weightValue = '--';
      weightLabel = '${L.t('home.weekWeight')} · ${L.t('home.vsLast')}';
    } else {
      weightValue = Units.formatWeight(series.last.kg, unit);
      weightLabel = L.t('home.weekWeightCurrent');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(L.t('home.weekOverview')),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.gapM,
            vertical: AppSpace.gapM,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: AppColors.border),
          ),
          // 遛狗没开时把「散步次数」那格抽掉：它恒为 0，留着是噪音不是信息。
          // 两格时中间只剩一根分隔线，三格时是两根，所以这里动态拼。
          child: Row(
            children:
                _statTiles(walkCount, recordCount, weightValue, weightLabel),
          ),
        ),
      ],
    );
  }

  static List<Widget> _statTiles(
    int? walkCount,
    int? recordCount,
    String weightValue,
    String weightLabel,
  ) {
    final tiles = <Widget>[
      if (AppCapabilities.current.supports(AppFeature.walkTracking))
        Expanded(
          child: StatTile(
            icon: Icons.directions_walk_rounded,
            value: walkCount == null
                ? '--'
                : L.tp('home.weekWalks.value', {'n': '$walkCount'}),
            label: L.t('home.weekWalks'),
            tint: AppColors.tileTints[3],
          ),
        ),
      Expanded(
        child: StatTile(
          icon: Icons.sticky_note_2_outlined,
          value: recordCount == null
              ? '--'
              : L.tp('home.weekRecords.value', {'n': '$recordCount'}),
          label: L.t('home.weekRecords'),
          tint: AppColors.tileTints[4],
        ),
      ),
      Expanded(
        child: StatTile(
          icon: Icons.monitor_weight_outlined,
          value: weightValue,
          label: weightLabel,
          tint: AppColors.tileTints[1],
        ),
      ),
    ];

    // 相邻两格之间插一根竖线。
    final out = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      if (i > 0) out.add(const StatDivider());
      out.add(tiles[i]);
    }
    return out;
  }

  /// 本周起点：周一 00:00。跨周归零靠这个。
  static DateTime _mondayOf(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  /// 体重差（展示单位）。返回 (文本, 单位)。
  ///
  /// 只有不到两条体重记录时给「--」—— 一条记录算不出差值，
  /// 硬凑一个 0.0 出来就是编数据。
  static (String, String?) _deltaOf(
    List<({DateTime at, double kg})>? series,
    WeightUnit unit,
  ) {
    if (series == null || series.length < 2) return ('--', null);

    final last = series.last.kg;
    final prev = series[series.length - 2].kg;
    final d = Units.toDisplayWeight(last - prev, unit);

    if (d.abs() < 0.05) return (L.t('home.steady'), null);

    final sign = d > 0 ? '+' : '-';
    return ('$sign${d.abs().toStringAsFixed(1)}', Units.weightSymbol(unit));
  }
}

// ------------------------------------------------------------------ 快捷记录

/// 首页快捷记录 —— 「3 秒记录」这条产品原则的物理入口。
///
/// 为什么是这四格而不是把九种类型全摊开：
/// 日常真正在手机上反复记的只有体重、喂食、用药三件，
/// 疫苗和驱虫一年才几次，塞在「更多」里足够了。
/// 摊开九个图标反而会让每次记录都要先做一次选择。
class _QuickAddRow extends ConsumerWidget {
  const _QuickAddRow({required this.pet});

  final Pet pet;

  /// 前三格是固定高频项，第四格是兜底「更多」。
  static const _quick = [
    RecordType.weight,
    RecordType.feeding,
    RecordType.medication,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(L.t('today.quickAdd')),
        LayoutBuilder(builder: (context, constraints) {
          final width = ((constraints.maxWidth - 24) / 4).clamp(0.0, 68.0);
          final types = [..._quick, null];
          return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < types.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              SizedBox(
                  width: width,
                  child: _QuickAddTile(
                    icon: types[i] == null
                        ? Icons.grid_view_rounded
                        : recordTypeIcon(types[i]!),
                    label: types[i] == null
                        ? L.t('today.quickAdd.more')
                        : recordTypeLabel(types[i]!),
                    tint: AppColors.tileTints[i == 3 ? 1 : i],
                    onTap: () {
                      if (types[i] == null) {
                        showAddRecordSheet(context, ref, petId: pet.id);
                      } else {
                        showAddRecordSheet(context, ref,
                            petId: pet.id, initialType: types[i]!);
                      }
                    },
                  )),
            ],
          ]);
        }),
      ],
    );
  }
}

class _QuickAddTile extends StatelessWidget {
  const _QuickAddTile({
    required this.icon,
    required this.label,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.tileBorder,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 22, color: AppColors.primary),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 性别符号。参考稿把母标记画成粉色 ♀，公狗是蓝色 ♂。
///
/// 未知性别返回空盒子，不要凭空画一个符号出来 —— 那是编数据。
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
      style: TextStyle(fontSize: 16, height: 1, color: color),
    );
  }
}

// ------------------------------------------------------------------ 今日待办

/// 今日待办：标题 + 「查看全部」，下面是横向滚动的小卡。
///
/// 用横向滚动而不是竖列表，是因为待办常常有 8-10 条，
/// 竖着排会把「接下来 7 天」挤出首屏 —— 那才是用户想看的新东西。
class _TodoSection extends ConsumerWidget {
  const _TodoSection({required this.reminders});

  final List<Reminder> reminders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final sorted = [...reminders]..sort((a, b) => a.nextAt.compareTo(b.nextAt));

    // 三分：过期 → 今天 → 之后。
    // 「今天」与「之后」必须分开 —— 首页要先回答「今天要做什么」，
    // 未来的事归到 Upcoming，不占今天的注意力。
    final endOfToday =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final overdue = sorted.where((r) => r.nextAt.isBefore(now)).toList();
    final today = sorted
        .where((r) => !r.nextAt.isBefore(now) && r.nextAt.isBefore(endOfToday))
        .toList();
    final upcoming =
        sorted.where((r) => !r.nextAt.isBefore(endOfToday)).toList();

    final visible = [...overdue, ...today].take(12).toList();

    final pets = ref.watch(petsProvider).valueOrNull ?? const <Pet>[];
    final nameOf = {for (final p in pets) p.id: p.name};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          L.t('home.todo'),
          trailing: Text(
            L.t('home.viewAll'),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (visible.isEmpty)
          // 空态压成一行半：没有待办是好消息，不值得占半个首屏，
          // 下方直接露出「接下来 7 天」。
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.gapL,
              vertical: 14,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.cardBorder,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline,
                    size: 20, color: AppColors.success),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L.t('home.todoEmpty'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        L.t('home.todoCaughtUp'),
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
          )
        else
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: visible.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpace.gapM),
              itemBuilder: (context, i) {
                final r = visible[i];
                return TodoTile(
                  reminder: r,
                  petName: nameOf[r.petId],
                  overdue: overdue.contains(r),
                );
              },
            ),
          ),
        if (visible.isNotEmpty) ...[
          const SizedBox(height: AppSpace.gapM),
          _TodoActions(reminders: visible),
        ],

        // Upcoming 只在真的有未来的事时才出现，不摆空区块占位。
        if (upcoming.isNotEmpty) _UpcomingSection(reminders: upcoming),
      ],
    );
  }
}

/// 「接下来 7 天」—— 紧凑竖行，只陈述事实：什么时候、什么事、哪只宠。
///
/// 与今日待办的区别：这里**不给操作按钮**。未来的事现在做不了决定，
/// 摆按钮只会制造误操作。
class _UpcomingSection extends ConsumerWidget {
  const _UpcomingSection({required this.reminders});

  final List<Reminder> reminders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pets = ref.watch(petsProvider).valueOrNull ?? const <Pet>[];
    final nameOf = {for (final p in pets) p.id: p.name};
    final visible = reminders.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(L.t('today.upcoming')),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0) const RowDivider(),
                _UpcomingRow(
                  reminder: visible[i],
                  petName: nameOf[visible[i].petId],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  const _UpcomingRow({required this.reminder, this.petName});

  final Reminder reminder;
  final String? petName;

  @override
  Widget build(BuildContext context) {
    final name = reminderTitle(reminder);
    final pet = petName;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.gapL,
        vertical: 12,
      ),
      child: Row(
        children: [
          Icon(
            reminderTypeIcon(reminder.type),
            size: 18,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Text(
              pet == null ? name : '$name · $pet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.gapM),
          Text(
            dueLabel(reminder.nextAt),
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 待办卡下方的操作条 —— 当前选中（最近到期）那条的完成/稍后。
///
/// 为什么要这个：横向小卡只有 132px 高，塞不下按钮，但「一键完成」不能丢。
/// 折中方案是卡片负责「看」，操作条负责「做」，默认操作最近到期那条。
class _TodoActions extends ConsumerStatefulWidget {
  const _TodoActions({required this.reminders});

  final List<Reminder> reminders;

  @override
  ConsumerState<_TodoActions> createState() => _TodoActionsState();
}

class _TodoActionsState extends ConsumerState<_TodoActions> {
  int _index = 0;
  bool _busy = false;

  @override
  void didUpdateWidget(_TodoActions old) {
    super.didUpdateWidget(old);
    if (_index >= widget.reminders.length) _index = 0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reminders.isEmpty) return const SizedBox.shrink();
    final r = widget.reminders[_index.clamp(0, widget.reminders.length - 1)];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.tileBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reminderTitle(r),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dueLabel(r.nextAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            if (r.rule['mode'] != 'medication')
              IconButton(
                tooltip: L.t('today.snooze'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _snooze(r.id),
                icon: const Icon(Icons.schedule_rounded,
                    size: 19, color: AppColors.textSecondary),
              ),
            FilledButton(
              onPressed: () => r.rule['mode'] == 'medication'
                  ? showReminderDueSheet(context, reminderId: r.id)
                  : _complete(r),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(L.t('today.done')),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _complete(Reminder reminder) async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(appActionsProvider)
          .completeReminder(reminder.id, expectedDueAt: reminder.nextAt);
      if (!mounted) return;
      final next = result.nextAt;
      final msg = next == null
          ? L.t('today.doneFinal')
          : L.tp('today.doneToast', {'next': compactDateTime(next)});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L.error(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _snooze(String id) async {
    setState(() => _busy = true);
    try {
      await ref.read(appActionsProvider).snoozeReminder(id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ------------------------------------------------------------------ 遛狗条

/// 遛狗入口。参考稿没有这一块，但它是「每天打开」的理由，必须保留。
///
/// 有进行中的散步 → 换成主色渐变大卡，一键结束。
class _WalkBanner extends ConsumerStatefulWidget {
  const _WalkBanner({required this.activeWalk, required this.pet});

  final WalkSession? activeWalk;
  final Pet? pet;

  @override
  ConsumerState<_WalkBanner> createState() => _WalkBannerState();
}

class _WalkBannerState extends ConsumerState<_WalkBanner> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final pet = widget.pet;
    if (pet == null) return const SizedBox.shrink();

    final active = widget.activeWalk;

    if (active != null) {
      return Container(
        margin: const EdgeInsets.only(bottom: AppSpace.gapM),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          gradient: AppGradients.activeWalk,
          borderRadius: AppRadius.cardBorder,
        ),
        child: Row(
          children: [
            const Icon(Icons.directions_walk_rounded,
                size: 26, color: Colors.white),
            const SizedBox(width: AppSpace.gapM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L.t('today.walking'),
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${pet.name} · ${compactDateTime(active.startedAt)}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _busy ? null : () => _endWalk(active),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                backgroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 34),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(L.t('today.endWalk')),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.gapM),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.directions_walk_rounded,
                size: 19, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpace.gapM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${L.t('today.startWalk')} · ${pet.name}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  AppRegion.current.mapRenderingEnabled
                      ? (L.isZh ? '记录轨迹与距离' : 'Track route and distance')
                      : L.t('walk.noMapHint'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _busy ? null : () => _startWalk(pet.id),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(L.t('walk.start')),
          ),
        ],
      ),
    );
  }

  Future<void> _startWalk(String petId) async {
    setState(() => _busy = true);
    try {
      await ref.read(appActionsProvider).startWalk(petId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _endWalk(WalkSession session) async {
    setState(() => _busy = true);
    try {
      final done = await ref.read(appActionsProvider).endWalk(session.id);
      if (!mounted) return;

      // 结果页负责展示距离时长并收心情/备注，所以这里不再弹 SnackBar ——
      // 同一个信息弹两遍是噪音。
      showWalkResultSheet(
        context,
        ref,
        session: done,
        petName: widget.pet?.name ?? '',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ------------------------------------------------------------------ 宠物条

/// 多宠家庭在主卡下方的切换条。只有一只时不显示。
class _PetStrip extends ConsumerWidget {
  const _PetStrip({required this.pets, required this.current});

  final List<Pet> pets;
  final Pet? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(L.t('me.section.pets')),
        SizedBox(
          height: 74,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: pets.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpace.gapM),
            itemBuilder: (context, i) {
              if (i == pets.length) {
                return _AddPetTile(onTap: () => showAddPetSheet(context, ref));
              }
              final pet = pets[i];
              final selected = pet.id == current?.id;
              return _PetTile(
                pet: pet,
                selected: selected,
                onTap: () =>
                    ref.read(selectedPetIdProvider.notifier).state = pet.id,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PetTile extends StatelessWidget {
  const _PetTile({
    required this.pet,
    required this.selected,
    required this.onTap,
  });

  final Pet pet;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.tile),
      onTap: onTap,
      child: Container(
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.tile),
          color: selected ? AppColors.primaryLight : Colors.white,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PetAvatar(pet: pet, size: 34),
            const SizedBox(height: 4),
            Text(
              pet.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddPetTile extends StatelessWidget {
  const _AddPetTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.tile),
      onTap: onTap,
      child: Container(
        width: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_rounded, color: AppColors.primary, size: 22),
            const SizedBox(height: 4),
            Text(
              L.t('action.add'),
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 弹层

class _PetSwitcherSheet extends StatelessWidget {
  const _PetSwitcherSheet({
    required this.pets,
    required this.currentId,
    required this.onPick,
  });

  final List<Pet> pets;
  final String? currentId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          AppSpace.gapS,
          AppSpace.page,
          AppSpace.gapL,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.gapL),
            Text(
              L.t('home.switchPet'),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpace.gapS),
            ...pets.map((p) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: PetAvatar(pet: p, size: 38),
                  title: Text(p.name),
                  subtitle: Text(
                    (p.breed ?? '').trim().isEmpty
                        ? L.t('profile.field.breed')
                        : p.breed!,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: p.id == currentId
                      ? const Icon(Icons.check_rounded,
                          color: AppColors.primary)
                      : null,
                  onTap: () => onPick(p.id),
                )),
          ],
        ),
      ),
    );
  }
}

/// 铃铛点开：所有待办按到期日排一遍。
class _NotificationSheet extends StatelessWidget {
  const _NotificationSheet({required this.reminders});

  final List<Reminder> reminders;

  @override
  Widget build(BuildContext context) {
    final sorted = [...reminders]..sort((a, b) => a.nextAt.compareTo(b.nextAt));
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          children: [
            const SizedBox(height: AppSpace.gapS),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpace.gapL),
              child: Row(
                children: [
                  Text(
                    L.t('home.todo'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${sorted.length}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: sorted.isEmpty
                  ? Center(
                      child: Text(
                        L.t('home.todoEmpty'),
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpace.page),
                      itemCount: sorted.length,
                      separatorBuilder: (_, __) => const RowDivider(),
                      itemBuilder: (_, i) {
                        final r = sorted[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: AppColors.tileTints[
                                      i % AppColors.tileTints.length],
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(
                                  recordTypeIcon(_typeOf(r)),
                                  size: 15,
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(width: AppSpace.gapM),
                              Expanded(
                                child: Text(
                                  reminderTitle(r),
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Text(
                                dueLabel(r.nextAt),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static RecordType _typeOf(Reminder r) => switch (r.type) {
        'vaccine' => RecordType.vaccine,
        'dewormInternal' => RecordType.dewormInternal,
        'dewormExternal' => RecordType.dewormExternal,
        'medication' => RecordType.medication,
        'medical' => RecordType.medical,
        'feeding' => RecordType.feeding,
        _ => RecordType.note,
      };
}
