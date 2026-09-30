/// 提醒的新建 / 编辑 / 到期操作（M4）。
///
/// 两个入口：
/// - [showReminderSheet]：新建或编辑一条提醒。档案页的「添加提醒」和
///   点某条提醒都走它。
/// - [showReminderDueSheet]：**点通知进来时**弹的操作卡。
///   通知直达的价值就在这一下 —— 用户点通知的目的通常是「我做了，划掉」
///   或「一会儿再说」，而不是打开 App 再从列表里找那条。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../providers.dart';
import 'widgets.dart';

/// 周期预设。单位统一折算成「天」存库，与 ReminderRepository 的 rule 格式一致。
const List<({String labelKey, int days})> _repeatPresets = [
  (labelKey: 'reminder.repeat.once', days: 0),
  (labelKey: 'reminder.repeat.monthly', days: 30),
  (labelKey: 'reminder.repeat.quarterly', days: 90),
  (labelKey: 'reminder.repeat.halfYearly', days: 180),
  (labelKey: 'reminder.repeat.yearly', days: 365),
];

/// 新建 / 编辑提醒弹层。
Future<void> showReminderSheet(
  BuildContext context, {
  required Pet pet,
  Reminder? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ReminderSheet(pet: pet, existing: existing),
  );
}

class _ReminderSheet extends ConsumerStatefulWidget {
  const _ReminderSheet({required this.pet, this.existing});

  final Pet pet;
  final Reminder? existing;

  @override
  ConsumerState<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends ConsumerState<_ReminderSheet> {
  late final TextEditingController _name;
  late final TextEditingController _days;

  late String _type;
  late int _repeatDays;
  late DateTime _firstAt;
  bool _customDays = false;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;

    _name = TextEditingController(
      // 系统生成的提醒 title 是 i18n key，不该回填到输入框里让用户看到
      // 'plan.vaccine.core' 这种内部串；那种情况留空，保存时保持原值。
      text: (r == null || r.title.contains('.')) ? '' : r.title,
    );
    _days = TextEditingController(text: '${r?.everyDays ?? 0}');
    _type = r?.type ?? kManualReminderTypes.first;
    _repeatDays = r?.everyDays ?? 0;
    _customDays = r != null &&
        _repeatDays > 0 &&
        !_repeatPresets.any((p) => p.days == _repeatDays);

    // 默认下次提醒：明天早上 9 点。直接给「现在」会让提醒立刻弹出，
    // 用户还没来得及退出设置页。
    final now = DateTime.now();
    _firstAt = r?.nextAt ??
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1, hours: 9));
  }

  @override
  void dispose() {
    _name.dispose();
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Handle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                0,
                AppSpace.page,
                AppSpace.gapS,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t(_isEdit ? 'reminder.edit' : 'reminder.new'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : _save,
                    child: Text(
                      L.t('reminder.save'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                AppSpace.gapL,
                AppSpace.page,
                AppSpace.gapXl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label(L.t('reminder.type')),
                  const SizedBox(height: AppSpace.gapS),
                  Wrap(
                    spacing: AppSpace.gapS,
                    runSpacing: AppSpace.gapS,
                    children: [
                      for (final t in kManualReminderTypes)
                        _PickChip(
                          label: reminderTypeLabel(t),
                          icon: reminderTypeIcon(t),
                          selected: _type == t,
                          onTap: () => setState(() => _type = t),
                        ),
                    ],
                  ),

                  const SizedBox(height: AppSpace.gapL),
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(
                      labelText: L.t('reminder.name'),
                      hintText: reminderTypeLabel(_type),
                      helperText: L.t('reminder.nameHint'),
                      suffixIcon: _name.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => setState(_name.clear),
                            ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),

                  const SizedBox(height: AppSpace.gapL),
                  _Label(L.t('reminder.repeat')),
                  const SizedBox(height: AppSpace.gapS),
                  Wrap(
                    spacing: AppSpace.gapS,
                    runSpacing: AppSpace.gapS,
                    children: [
                      for (final p in _repeatPresets)
                        _PickChip(
                          label: L.t(p.labelKey),
                          selected: !_customDays && _repeatDays == p.days,
                          onTap: () => setState(() {
                            _customDays = false;
                            _repeatDays = p.days;
                          }),
                        ),
                      _PickChip(
                        label: L.t('reminder.repeat.custom'),
                        selected: _customDays,
                        onTap: () => setState(() {
                          _customDays = true;
                          if (_repeatDays <= 0) _repeatDays = 14;
                          _days.text = '$_repeatDays';
                        }),
                      ),
                    ],
                  ),

                  if (_customDays) ...[
                    const SizedBox(height: AppSpace.gapM),
                    TextField(
                      controller: _days,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: L.t('reminder.days'),
                        hintText: L.t('reminder.daysHint'),
                      ),
                      onChanged: (v) =>
                          setState(() => _repeatDays = int.tryParse(v) ?? 0),
                    ),
                  ],

                  const SizedBox(height: AppSpace.gapL),
                  _Label(L.t('reminder.firstAt')),
                  const SizedBox(height: AppSpace.gapS),
                  _DateRow(
                    value: _firstAt,
                    onTap: _pickDate,
                  ),

                  const SizedBox(height: AppSpace.gapL),
                  Text(
                    _summary(),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),

                  if (_isEdit) ...[
                    const SizedBox(height: AppSpace.gapL),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _saving ? null : _delete,
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text(L.t('reminder.delete')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          side: const BorderSide(color: AppColors.border),
                          minimumSize: const Size(0, 42),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一句话说清「这条提醒以后会怎么弹」。周期型最容易让人搞不清
  /// 「下次」和「间隔」的关系，直接写出来比让人自己推强。
  String _summary() {
    if (_repeatDays <= 0) {
      return L.isZh
          ? '只在 ${_fmt(_firstAt)} 提醒一次，完成后不再提醒。'
          : 'Reminds once on ${_fmt(_firstAt)}, then stops.';
    }
    return L.isZh
        ? '从 ${_fmt(_firstAt)} 开始，每 $_repeatDays 天提醒一次。'
        : 'Starts ${_fmt(_firstAt)}, repeats every $_repeatDays days.';
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${_p(d.month)}-${_p(d.day)} ${_p(d.hour)}:${_p(d.minute)}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _firstAt,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: L.t('reminder.firstAt'),
    );
    if (date == null) return;
    // 只让用户选日期，时间固定早上 9 点：兽医门诊、喂药这类事
    // 精确到分钟没有意义，反而多两步操作。
    setState(() => _firstAt = DateTime(date.year, date.month, date.day, 9));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    // 名称留空就用类型名（存 i18n key，换语言能跟着变）。
    final typed = _name.text.trim();
    final title = typed.isEmpty ? 'reminder.type.$_type' : typed;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final actions = ref.read(appActionsProvider);

    try {
      final existing = widget.existing;
      if (existing == null) {
        await actions.createReminder(
          petId: widget.pet.id,
          type: _type,
          title: title,
          everyDays: _repeatDays,
          firstAt: _firstAt,
        );
      } else {
        await actions.updateReminder(existing.copyWith(
          type: _type,
          title: title,
          rule: {'mode': 'interval', 'days': _repeatDays},
          nextAt: _firstAt,
          enabled: true,
        ));
      }

      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(L.t('reminder.saved'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;

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
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await ref.read(appActionsProvider).deleteReminder(existing);
    if (!mounted) return;
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(L.t('reminder.deleted'))));
  }

  static String _p(int v) => v.toString().padLeft(2, '0');
}

// ------------------------------------------------------------------ 通知直达

/// 点通知进来时弹的操作卡。
///
/// 为什么是弹层而不是跳页面：用户在通知上点一下的全部诉求就是
/// 「这条我处理了」。跳进某个页签再让他自己找那条待办是多余动作。
Future<void> showReminderDueSheet(
  BuildContext context, {
  required String reminderId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final reminder = await container.read(reminderRepositoryProvider).findById(reminderId);

  if (!context.mounted) return;
  if (reminder == null || reminder.deletedAt != null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(L.t('reminder.due.unknown'))));
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    builder: (_) => _ReminderDueSheet(reminder: reminder),
  );
}

class _ReminderDueSheet extends ConsumerStatefulWidget {
  const _ReminderDueSheet({required this.reminder});

  final Reminder reminder;

  @override
  ConsumerState<_ReminderDueSheet> createState() => _ReminderDueSheetState();
}

class _ReminderDueSheetState extends ConsumerState<_ReminderDueSheet> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.reminder;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          AppSpace.gapL,
          AppSpace.page,
          AppSpace.gapL,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(reminderTypeIcon(r.type),
                      size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminderTitle(r),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${compactDateTime(r.nextAt)} · ${dueLabel(r.nextAt)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.gapL),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _snooze,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.border),
                      minimumSize: const Size(0, 44),
                    ),
                    child: Text(L.t('today.snooze')),
                  ),
                ),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _complete,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    child: Text(L.t('today.done')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _complete() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final result =
          await ref.read(appActionsProvider).completeReminder(widget.reminder.id);
      if (!mounted) return;
      final next = result.nextAt;
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(next == null
            ? L.t('today.doneFinal')
            : L.tp('today.doneToast', {'next': compactDateTime(next)})),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _snooze() async {
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    try {
      await ref.read(appActionsProvider).snoozeReminder(widget.reminder.id);
      if (!mounted) return;
      navigator.pop();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ------------------------------------------------------------------ 小组件

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.divider,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
      );
}

class _PickChip extends StatelessWidget {
  const _PickChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.primary : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({required this.value, required this.onTap});

  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.gapM,
          vertical: 14,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.event_outlined,
                size: 18, color: AppColors.textTertiary),
            const SizedBox(width: AppSpace.gapM),
            Expanded(
              child: Text(
                L.t('reminder.firstAtHint'),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
            Text(
              '${value.year}-${_p(value.month)}-${_p(value.day)}',
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _p(int v) => v.toString().padLeft(2, '0');
}
