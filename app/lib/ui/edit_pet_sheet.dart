/// 档案编辑弹层（M2.2）。
///
/// 为什么是弹层而不是新页面：编辑是「进档案页 → 改几项 → 回档案页」的短回路，
/// 单开一页会多一次返回动作，而且离开档案页后顶部那只头像就看不见了 ——
/// 改档案时最该一直看得见的就是它。
///
/// 只做「用户自己填的东西」。体型（Build）不在表单里：它是由体重基线推出来的，
/// 让用户再选一次等于埋一个「和体重对不上」的矛盾。
library;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/species.dart';
import '../core/theme.dart';
import '../core/traits.dart';
import '../data/models.dart';
import '../providers.dart';
import 'sheet_scaffold.dart';

Future<void> showEditPetSheet(BuildContext context, {required Pet pet}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _EditPetSheet(pet: pet),
  );
}

class _EditPetSheet extends ConsumerStatefulWidget {
  const _EditPetSheet({required this.pet});

  final Pet pet;

  @override
  ConsumerState<_EditPetSheet> createState() => _EditPetSheetState();
}

class _EditPetSheetState extends ConsumerState<_EditPetSheet> {
  late final TextEditingController _name;
  late final TextEditingController _breed;
  late final TextEditingController _chipNo;
  late final TextEditingController _color;
  late final TextEditingController _weight;
  late final TextEditingController _allergy;
  late final TextEditingController _note;

  late Species _species;
  late String _gender;
  late DateTime? _birthday;
  late bool _estimated;
  late bool _neutered;
  late Set<String> _traits;

  String? _nameError;
  bool _saving = false;
  bool _allowClose = false;
  bool _confirmingClose = false;
  late final List<Object?> _initialDraft;
  final _textFocus = List.generate(7, (_) => FocusNode());
  final _nameFieldKey = GlobalKey();
  final _birthdayFieldKey = GlobalKey();
  bool _pickingBirthday = false;

  String? get _birthdayError => _birthday != null &&
          DateUtils.dateOnly(_birthday!)
              .isAfter(DateUtils.dateOnly(DateTime.now()))
      ? L.t('editPet.birthdayFuture')
      : null;

  void _showInvalidField(GlobalKey key, {FocusNode? focus}) {
    if (focus == null) {
      FocusManager.instance.primaryFocus?.unfocus();
    } else {
      focus.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final fieldContext = key.currentContext;
      if (fieldContext == null) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: 0.1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
      );
    });
  }

  List<TextEditingController> get _controllers =>
      [_name, _breed, _chipNo, _color, _weight, _allergy, _note];

  List<Object?> get _draftValues => [
        for (final c in _controllers)
          c == _weight
              ? double.tryParse(c.text.trim()) ?? c.text.trim()
              : c.text.trim(),
        _species,
        _gender,
        _birthday?.year,
        _birthday?.month,
        _birthday?.day,
        _estimated,
        _neutered,
        (_traits.toList()..sort()).join(','),
      ];

  bool get _hasChanges => !listEquals(_initialDraft, _draftValues);

  void _draftChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    final p = widget.pet;
    _name = TextEditingController(text: p.name);
    _breed = TextEditingController(text: p.breed ?? '');
    _chipNo = TextEditingController(text: p.chipNo ?? '');
    _color = TextEditingController(text: p.color ?? '');
    _weight = TextEditingController(
      text: p.weightBaseline == null ? '' : _trimNum(p.weightBaseline!),
    );
    _allergy = TextEditingController(text: p.allergy ?? '');
    _note = TextEditingController(text: p.note ?? '');

    _species = p.species;
    _gender = _normalizeGender(p.gender);
    _birthday = p.birthday?.toLocal();
    _estimated = p.birthdayEstimated;
    _neutered = p.neutered;
    _traits = knownPersonalities(p.personality).toSet();
    _initialDraft = _draftValues;
    for (final c in _controllers) {
      c.addListener(_draftChanged);
    }
  }

  @override
  void dispose() {
    for (final node in _textFocus) {
      node.dispose();
    }
    for (final c in _controllers) {
      c.removeListener(_draftChanged);
      c.dispose();
    }
    super.dispose();
  }

  static String _normalizeGender(String? raw) {
    final g = (raw ?? '').trim().toLowerCase();
    return switch (g) {
      'male' || 'm' || '公' || '雄' => 'male',
      'female' || 'f' || '母' || '雌' => 'female',
      _ => 'unknown',
    };
  }

  /// `23.0` 显示成 `23`，避免编辑一次多出一串小数尾巴。
  static String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    // 固定高度可拖拽形态：骨架交给 [SheetScaffold]，把 DraggableScrollableSheet
    // 的 controller 透传下去 —— 不接的话拖拽手柄和列表滚动会各走各的。
    return PopScope<void>(
      canPop: !_saving && (!_hasChanges || _allowClose),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: DraggableScrollableSheet(
        expand: false,
        shouldCloseOnMinExtent: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) => SheetScaffold(
          title: L.t('editPet.title'),
          scrollable: false,
          bodyController: controller,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed:
                    _saving || _allowClose || !_hasChanges ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(L.t('editPet.save')),
              ),
              IconButton(
                tooltip: L.t('editPet.close'),
                onPressed: _saving ? null : _requestClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          child: AbsorbPointer(
            absorbing: _saving,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel(L.t('editPet.section.basic')),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  key: _nameFieldKey,
                  controller: _name,
                  readOnly: _saving,
                  focusNode: _textFocus[0],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _textFocus[1].requestFocus(),
                  decoration: InputDecoration(
                    labelText: L.t('editPet.nameRequired'),
                    errorText: _nameError,
                  ),
                  onChanged: (_) {
                    if (_nameError != null) {
                      setState(() => _nameError = null);
                    }
                  },
                ),
                const SizedBox(height: AppSpace.gapM),
                _FieldLabel(L.t('editPet.species')),
                const SizedBox(height: AppSpace.gapS),
                _ChoiceRow<Species>(
                  value: _species,
                  options: const [
                    (Species.dog, 'addPet.species.dog', Icons.pets),
                    (Species.cat, 'addPet.species.cat', Icons.pets),
                    (Species.other, 'addPet.species.other', Icons.cruelty_free),
                  ],
                  labelOf: (v) => L.t(v.$2),
                  iconOf: (v) => v.$3,
                  onChanged: (v) => setState(() => _species = v),
                ),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  controller: _breed,
                  readOnly: _saving,
                  focusNode: _textFocus[1],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _textFocus[2].requestFocus(),
                  decoration: InputDecoration(
                    labelText: L.t('editPet.breed'),
                    hintText: L.t('editPet.breedHint'),
                  ),
                ),
                const SizedBox(height: AppSpace.gapM),
                _FieldLabel(L.t('editPet.gender')),
                const SizedBox(height: AppSpace.gapS),
                _ChoiceRow<String>(
                  value: _gender,
                  options: const [
                    ('male', 'profile.gender.male', Icons.male_rounded),
                    ('female', 'profile.gender.female', Icons.female_rounded),
                    ('unknown', 'profile.gender.unknown', Icons.help_outline),
                  ],
                  labelOf: (v) => L.t(v.$2),
                  iconOf: (v) => v.$3,
                  onChanged: (v) => setState(() => _gender = v),
                ),
                const SizedBox(height: AppSpace.gapM),
                _BirthdayField(
                  key: _birthdayFieldKey,
                  birthday: _birthday,
                  errorText: _birthdayError,
                  estimated: _estimated,
                  onPick: _pickBirthday,
                  onClear: () => setState(() {
                    _birthday = null;
                    _estimated = false;
                  }),
                  onEstimatedChanged: (v) => setState(() => _estimated = v),
                ),
                const SizedBox(height: AppSpace.gapXl),
                _SectionLabel(L.t('editPet.section.traits')),
                const SizedBox(height: 4),
                Text(
                  L.t('editPet.traitsHint'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: AppSpace.gapM),
                Wrap(
                  spacing: AppSpace.gapS,
                  runSpacing: AppSpace.gapS,
                  children: [
                    for (final code in kPersonalityCodes)
                      FilterChip(
                        label: Text(personalityLabel(code)),
                        selected: _traits.contains(code),
                        onSelected: (on) => setState(() {
                          if (on) {
                            _traits.add(code);
                          } else {
                            _traits.remove(code);
                          }
                        }),
                        showCheckmark: false,
                        selectedColor: AppColors.primaryLight,
                        labelStyle: TextStyle(
                          fontSize: 12.5,
                          fontWeight: _traits.contains(code)
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: _traits.contains(code)
                              ? AppColors.primary
                              : AppColors.textSecondary,
                        ),
                        side: BorderSide(
                          color: _traits.contains(code)
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.gapXl),
                _SectionLabel(L.t('editPet.section.health')),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  controller: _weight,
                  readOnly: _saving,
                  focusNode: _textFocus[2],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _textFocus[3].requestFocus(),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: L.t('editPet.weightBaseline'),
                    hintText: L.t('editPet.weightBaselineHint'),
                    suffixText: L.t('editPet.kg'),
                  ),
                ),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  controller: _color,
                  readOnly: _saving,
                  focusNode: _textFocus[3],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _textFocus[4].requestFocus(),
                  decoration: InputDecoration(
                    labelText: L.t('editPet.color'),
                    hintText: L.t('editPet.colorHint'),
                  ),
                ),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  controller: _allergy,
                  readOnly: _saving,
                  focusNode: _textFocus[4],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _textFocus[5].requestFocus(),
                  decoration: InputDecoration(
                    labelText: L.t('editPet.allergy'),
                    hintText: L.t('editPet.allergyHint'),
                  ),
                ),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  controller: _chipNo,
                  readOnly: _saving,
                  focusNode: _textFocus[5],
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _textFocus[6].requestFocus(),
                  decoration: InputDecoration(
                    labelText: L.t('editPet.chipNo'),
                    hintText: L.t('editPet.chipNoHint'),
                  ),
                ),
                const SizedBox(height: AppSpace.gapM),
                _SwitchRow(
                  label: L.t('editPet.neutered'),
                  value: _neutered,
                  onChanged: (v) => setState(() => _neutered = v),
                ),
                const SizedBox(height: AppSpace.gapM),
                TextField(
                  controller: _note,
                  readOnly: _saving,
                  focusNode: _textFocus[6],
                  textInputAction: TextInputAction.newline,
                  maxLines: 3,
                  decoration: InputDecoration(labelText: L.t('editPet.note')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _requestClose() async {
    if (_saving || _confirmingClose) return;
    if (_hasChanges) {
      _confirmingClose = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L.t('editPet.unsavedTitle')),
          content: Text(L.t('editPet.unsavedHint')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('editPet.keepEditing')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L.t('editPet.discard')),
            ),
          ],
        ),
      );
      _confirmingClose = false;
      if (!mounted || discard != true) return;
    }
    if (!mounted) return;
    setState(() => _allowClose = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _pickBirthday() async {
    if (_saving || _pickingBirthday) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _pickingBirthday = true;
    final today = DateUtils.dateOnly(DateTime.now());
    final firstDate = DateTime(today.year - 40);
    final current = DateUtils.dateOnly(_birthday ?? today);
    final initial = current.isAfter(today)
        ? today
        : current.isBefore(firstDate)
            ? firstDate
            : current;
    try {
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: firstDate,
        lastDate: today,
        helpText: L.t('editPet.birthdayPick'),
      );
      // Clamping the picker viewport must never change the draft on cancel.
      if (mounted && picked != null) setState(() => _birthday = picked);
    } finally {
      _pickingBirthday = false;
    }
  }

  Future<void> _save() async {
    if (_saving || _allowClose || !_hasChanges) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = L.t('editPet.nameEmpty'));
      _showInvalidField(_nameFieldKey, focus: _textFocus[0]);
      return;
    }
    if (_birthdayError != null) {
      setState(() {});
      _showInvalidField(_birthdayFieldKey);
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _saving = true);
    final pet = widget.pet;

    // 空字符串在库里应该是 NULL 而不是 ''：两种「没填」混着存，
    // 以后做同步比对会把同一条数据判成有冲突。
    String? orNull(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    final updated = pet.copyWith(
      name: name,
      species: _species,
      breed: orNull(_breed),
      clearBreed: orNull(_breed) == null,
      gender: _gender,
      birthday: _birthday,
      clearBirthday: _birthday == null,
      birthdayEstimated: _estimated,
      neutered: _neutered,
      chipNo: orNull(_chipNo),
      clearChipNo: orNull(_chipNo) == null,
      color: orNull(_color),
      clearColor: orNull(_color) == null,
      allergy: orNull(_allergy),
      clearAllergy: orNull(_allergy) == null,
      note: orNull(_note),
      clearNote: orNull(_note) == null,
      weightBaseline: double.tryParse(_weight.text.trim()),
      clearWeightBaseline: double.tryParse(_weight.text.trim()) == null,
      personality: _traits.toList(growable: false),
    );

    // 弹层自己的 context 在 pop 之后就失效了，提示得挂在更上层的
    // ScaffoldMessenger 上，而且要**先取出来**再 pop。
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      await ref.read(appActionsProvider).updatePet(updated);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _allowClose = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        navigator.pop();
        messenger.showSnackBar(SnackBar(content: Text(L.t('editPet.saved'))));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(L.t('editPet.saveFailed'))),
      );
    }
  }
}

// ------------------------------------------------------------------ 小组件

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

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

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
      );
}

/// 分段选择。用泛型 + 记录元组承载选项，省掉为每个枚举各写一个组件。
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.iconOf,
    required this.onChanged,
  });

  final T value;
  final List<(T, String, IconData)> options;
  final String Function((T, String, IconData)) labelOf;
  final IconData Function((T, String, IconData)) iconOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final stacked = constraints.maxWidth < 240 ||
          MediaQuery.textScalerOf(context).scale(12) > 18;
      final width = stacked
          ? constraints.maxWidth
          : (constraints.maxWidth - AppSpace.gapS * (options.length - 1)) /
              options.length;
      return Wrap(
        spacing: AppSpace.gapS,
        runSpacing: AppSpace.gapS,
        children: [
          for (var i = 0; i < options.length; i++)
            SizedBox(
              width: width,
              child: _ChoiceTile(
                label: labelOf(options[i]),
                icon: iconOf(options[i]),
                selected: options[i].$1 == value,
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  onChanged(options[i].$1);
                },
              ),
            ),
        ],
      );
    });
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
            vertical: AppSpace.gapM,
            horizontal: AppSpace.gapS,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryLight : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? AppColors.primary : AppColors.textTertiary,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BirthdayField extends StatelessWidget {
  const _BirthdayField({
    super.key,
    required this.birthday,
    this.errorText,
    required this.estimated,
    required this.onPick,
    required this.onClear,
    required this.onEstimatedChanged,
  });

  final DateTime? birthday;
  final String? errorText;
  final bool estimated;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final ValueChanged<bool> onEstimatedChanged;

  @override
  Widget build(BuildContext context) {
    final has = birthday != null;
    final label = has
        ? '${birthday!.year}-${pad2(birthday!.month)}-${pad2(birthday!.day)}'
        : L.t('editPet.birthdayPick');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onPick,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
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
                const Icon(Icons.cake_outlined,
                    size: 18, color: AppColors.textTertiary),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L.t('editPet.birthday'), style: AppText.caption),
                      const SizedBox(height: AppSpace.gapXs),
                      Text(label,
                          style: AppText.body.copyWith(
                            fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                            color: has
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                          )),
                    ],
                  ),
                ),
                if (has) ...[
                  const SizedBox(width: AppSpace.gapS),
                  IconButton(
                    onPressed: onClear,
                    tooltip: L.t('editPet.birthdayClear'),
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.close_rounded,
                        size: 16, color: AppColors.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.gapS),
            child: Text(errorText!,
                style: AppText.caption.copyWith(color: AppColors.danger)),
          ),
        // 估算标记只在填了生日之后才有意义 —— 没生日谈不上「大概几号」。
        if (has)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _SwitchRow(
              label: L.t('editPet.birthdayEstimated'),
              value: estimated,
              onChanged: onEstimatedChanged,
            ),
          ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: AppText.body),
      value: value,
      onChanged: onChanged,
    );
  }
}
