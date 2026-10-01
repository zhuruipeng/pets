/// 通用小组件。四个页面共用，避免各写一套导致视觉漂移。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/reminder_text.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../domain/immunization.dart';

// 提醒文案的解析与类型表在 core 里（通知服务也要用），
// 这里再导出一次，免得所有界面文件都要多 import 一个。
export '../core/reminder_text.dart' show kManualReminderTypes, reminderTypeLabel;

// 类型 → 文案的纯映射搬去了 domain/labels.dart（那边不引 Flutter，
// 纯逻辑层如「导出报告」的内容组装也能用）。这里转发一次，界面文件不必改 import。
export '../domain/labels.dart'
    show
        careKindLabel,
        feedKindLabel,
        medRouteLabel,
        planTypeLabel,
        petAgeLabel,
        recordPayloadSummary,
        recordTypeLabel,
        recordValueLine;

/// 统计格之间那道竖线。今日页的主卡、本周概览、遛狗结果都在用它。
class StatDivider extends StatelessWidget {
  const StatDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 34,
        color: AppColors.divider,
      );
}

/// 空态。四个页面都有「还没有数据」的场景，统一这一种表达。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 34, color: cs.primary),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.outline),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 区域色标（左竖条）+ 内容，用于今日待办卡片。
class AccentCard extends StatelessWidget {
  const AccentCard({
    super.key,
    required this.child,
    this.accent,
    this.onTap,
  });

  final Widget child;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = accent ?? cs.primary;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 章节标题。
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 档案页的「标签 - 值」行。
///
/// 参考稿里标签靠左、值靠右，中间留白，行高比默认列表更松。
class InfoRow extends StatelessWidget {
  const InfoRow(
    this.label,
    this.value, {
    super.key,
    this.valueColor,
    this.trailing,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: valueColor ?? AppColors.textPrimary,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 行内分隔线。比 Divider 更淡，用于卡片内的条目之间。
class RowDivider extends StatelessWidget {
  const RowDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: AppColors.divider);
}

/// 带图标的统计小块。参考稿的「体重 / 状态 / 活跃度」三格用的就是这个。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.unit,
    this.tint,
  });

  final IconData icon;
  final String value;
  final String label;
  final String? unit;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                height: 1.1,
              ),
            ),
            if (unit != null) ...[
              const SizedBox(width: 2),
              Text(
                unit!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: tint ?? AppColors.primaryLight,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(icon, size: 10, color: AppColors.primary),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 小圆角标签。参考稿的「健康良好」「友善」「活泼」都是这种。
class SoftTag extends StatelessWidget {
  const SoftTag(
    this.text, {
    super.key,
    this.color,
    this.bg,
    this.icon,
  });

  final String text;
  final Color? color;
  final Color? bg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg ?? AppColors.primaryLight,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// 头像。有图显示图，没图用种类 emoji 占位。
///
/// [borderWidth] > 0 时加白色描边 —— 参考稿在渐变背景上用了这个效果。
class PetAvatar extends StatelessWidget {
  const PetAvatar({
    super.key,
    required this.pet,
    this.size = 44,
    this.borderWidth = 0,
  });

  final Pet pet;
  final double size;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final emoji = switch (pet.species) {
      Species.dog => '🐶',
      Species.cat => '🐱',
      Species.other => '🐾',
    };

    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.primaryLight,
        shape: BoxShape.circle,
      ),
      child: Text(emoji, style: TextStyle(fontSize: size * 0.48)),
    );

    final inner = _localAvatar(size) ?? fallback;

    if (borderWidth <= 0) return inner;

    return Container(
      padding: EdgeInsets.all(borderWidth),
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: inner,
    );
  }

  /// 本地头像文件。三种情况都回落到 emoji：
  /// - 没设置
  /// - 值是远端 URL（同步功能写入的，本机还没下载）
  /// - 文件被系统/用户清了
  ///
  /// 用 `errorBuilder` 兜住「文件存在但解不开」（半个文件、格式坏了），
  /// 否则头像会变成一个红叉，比没头像更难看。
  Widget? _localAvatar(double size) {
    final path = (pet.avatarUrl ?? '').trim();
    if (path.isEmpty || path.startsWith('http')) return null;
    final file = File(path);
    if (!file.existsSync()) return null;

    return ClipOval(
      child: Image.file(
        file,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          color: AppColors.primaryLight,
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 文案工具

IconData recordTypeIcon(RecordType type) => switch (type) {
      RecordType.weight => Icons.monitor_weight_outlined,
      RecordType.vaccine => Icons.vaccines_outlined,
      RecordType.dewormInternal => Icons.medication_outlined,
      RecordType.dewormExternal => Icons.bug_report_outlined,
      RecordType.medication => Icons.medication_liquid_outlined,
      RecordType.medical => Icons.local_hospital_outlined,
      RecordType.grooming => Icons.shower_outlined,
      RecordType.feeding => Icons.restaurant_outlined,
      // 注意 toilet 已经占了 water_drop，饮水另用一个杯子图标。
      RecordType.water => Icons.local_drink_outlined,
      RecordType.toilet => Icons.water_drop_outlined,
      RecordType.sleep => Icons.bedtime_outlined,
      RecordType.note => Icons.sticky_note_2_outlined,
    };

/// 秒数 → 「1 小时 23 分」/「1h 23m」。
///
/// 遛狗结果、档案页的遛狗列表都要这一段，各写一份迟早会长出两个格式。
String durationLabel(int seconds) {
  final (h, m) = Units.splitDuration(seconds);
  if (h > 0) return L.isZh ? '$h 小时 $m 分' : '${h}h ${m}m';
  return L.isZh ? '$m 分钟' : '${m}m';
}

/// 遛狗心情的五种取值。存 code，不存 emoji —— emoji 有可能变，code 不会。
const List<String> kWalkMoods = ['great', 'good', 'tired', 'anxious', 'sick'];

String walkMoodEmoji(String code) => switch (code) {
      'good' => '🙂',
      'tired' => '😴',
      'anxious' => '😟',
      'sick' => '🤒',
      _ => '😄',
    };

String walkMoodLabel(String code) => switch (code) {
      'good' => L.t('walk.mood.good'),
      'tired' => L.t('walk.mood.tired'),
      'anxious' => L.t('walk.mood.anxious'),
      'sick' => L.t('walk.mood.sick'),
      _ => L.t('walk.mood.great'),
    };

/// 提醒标题：库里存的是 i18n key，展示时才翻。
/// 提醒标题。解析规则见 core/reminder_text.dart —— 通知服务也要用同一套，
/// 所以那边才是实现，这里是给界面用的薄封装。
String reminderTitle(Reminder r) => reminderTitleFrom(r.title, r.type);

/// 相对时间：今天 / 昨天 / N 天前 / 具体日期。
String relativeDay(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(that).inDays;

  if (diff == 0) return L.t('timeline.today');
  if (diff == 1) return L.t('timeline.yesterday');
  if (diff > 1 && diff < 30) return L.tp('timeline.daysAgo', {'n': diff});
  return '${dt.year}-${_p(dt.month)}-${_p(dt.day)}';
}

/// 提醒倒计时：「还有 3 天」/「已过期 2 天」/「今天」
String dueLabel(DateTime dueAt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dueAt.year, dueAt.month, dueAt.day);
  final diff = that.difference(today).inDays;

  if (diff == 0) return L.t('timeline.today');
  if (diff == 1) return L.t('due.tomorrow');
  if (diff > 1) return L.tp('due.inDays', {'n': diff});
  return L.tp('due.overdueBy', {'n': -diff});
}

String _p(int v) => v.toString().padLeft(2, '0');

/// 日期时间紧凑格式。
String compactDateTime(DateTime dt) =>
    '${_p(dt.month)}-${_p(dt.day)} ${_p(dt.hour)}:${_p(dt.minute)}';

/// 台账分类 → 图标。转发给 [reminderTypeIcon]，同一件事在两处不能长两个样。
IconData careKindIcon(PlanItemType kind) => reminderTypeIcon(kind.wireName);

/// 提醒类型 → 小图标。类型是 wire 字符串，不是 RecordType 枚举。
///
/// 提升为顶层函数是为了让 Upcoming 行也能复用同一套图标映射，
/// 免得今日卡和未来列表对同一个类型画出两个不同的图标。
/// 提醒类型 → 图标。
///
/// 同时认两种写法：**库里存的是下划线式**（`deworm_internal`，来自
/// PlanItemType.wireName），而早年这里只匹配驼峰式，导致驱虫和体检
/// 一直显示成默认的小铃铛。别把下划线那组删掉。
IconData reminderTypeIcon(String type) => switch (type) {
      'vaccine' => Icons.vaccines_outlined,
      'dewormInternal' || 'deworm_internal' => Icons.medication_outlined,
      'dewormExternal' || 'deworm_external' => Icons.bug_report_outlined,
      'checkup' => Icons.health_and_safety_outlined,
      'grooming' => Icons.shower_outlined,
      'medication' => Icons.medication_liquid_outlined,
      'medical' => Icons.local_hospital_outlined,
      'feeding' => Icons.restaurant_outlined,
      'toilet' => Icons.water_drop_outlined,
      _ => Icons.notifications_none_rounded,
    };

/// 待办小卡（今日页横向滚动用）。
///
/// 版式取自参考稿：图标底 + 标题 + 时间/倒计时两行。
/// 每张卡按类型配不同底色，扫一眼就能分出维生素、晚餐、驱虫。
///
/// 卡片只负责「看」，操作按钮在卡片外的操作条上（见 today_screen 的 _TodoActions）。
/// 原因：横向卡固定 132px 高，塞不下按钮；而「一键完成」不能丢。
class TodoTile extends StatelessWidget {
  const TodoTile({
    super.key,
    required this.reminder,
    this.petName,
    this.overdue = false,
  });

  final Reminder reminder;
  final String? petName;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    // 按类型散列到一组底色，保证同一类型每次拿到的颜色一致。
    final tint = overdue
        ? AppColors.dangerBg
        : AppColors.tileTints[reminder.type.hashCode.abs() %
            AppColors.tileTints.length];
    final fg = overdue ? AppColors.danger : AppColors.primary;

    return Container(
      width: 152,
      padding: const EdgeInsets.all(AppSpace.gapM),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(reminderTypeIcon(reminder.type), size: 17, color: fg),
          ),
          const SizedBox(height: AppSpace.gapM),
          Text(
            reminderTitle(reminder),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _when(reminder),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: overdue ? AppColors.danger : AppColors.textSecondary,
            ),
          ),
          if (petName != null) ...[
            const Spacer(),
            Text(
              petName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 参考稿这里显示「08:00」这样的具体时刻，过期项显示「已过期 N 天」。
  static String _when(Reminder r) {
    final now = DateTime.now();
    final sameDay = r.nextAt.year == now.year &&
        r.nextAt.month == now.month &&
        r.nextAt.day == now.day;

    if (sameDay) {
      return '${_p(r.nextAt.hour)}:${_p(r.nextAt.minute)}';
    }
    return dueLabel(r.nextAt);
  }
}
