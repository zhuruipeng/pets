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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/species.dart';
import '../core/theme.dart';
import '../core/traits.dart';
import '../data/models.dart';
import '../providers.dart';

Future<void> showEditPetSheet(BuildContext context, {required Pet pet}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
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
    _birthday = p.birthday;
    _estimated = p.birthdayEstimated;
    _neutered = p.neutered;
    _traits = knownPersonalities(p.personality).toSet();
  }

  @override
  void dispose() {
    for (final c in [_name, _breed, _chipNo, _color, _weight, _allergy, _note]) {
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
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) => Column(
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
                      L.t('editPet.title'),
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
                      L.t('editPet.save'),
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
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  AppSpace.gapL,
                  AppSpace.page,
                  AppSpace.gapXl,
                ),
                children: [
                  _SectionLabel(L.t('editPet.section.basic')),
                  const SizedBox(height: AppSpace.gapM),

                  TextField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: L.t('editPet.name'),
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
                    textInputAction: TextInputAction.next,
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
                    birthday: _birthday,
                    estimated: _estimated,
                    onPick: _pickBirthday,
                    onClear: () => setState(() {
                      _birthday = null;
                      _estimated = false;
                    }),
                    onEstimatedChanged: (v) =>
                        setState(() => _estimated = v),
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
                    decoration: InputDecoration(
                      labelText: L.t('editPet.color'),
                      hintText: L.t('editPet.colorHint'),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapM),

                  TextField(
                    controller: _allergy,
                    decoration: InputDecoration(
                      labelText: L.t('editPet.allergy'),
                      hintText: L.t('editPet.allergyHint'),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapM),

                  TextField(
                    controller: _chipNo,
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
                    maxLines: 3,
                    decoration: InputDecoration(labelText: L.t('editPet.note')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? now,
      firstDate: DateTime(now.year - 40),
      lastDate: now,
      helpText: L.t('editPet.birthdayPick'),
    );
    if (picked != null) setState(() => _birthday = picked);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = L.t('editPet.nameEmpty'));
      return;
    }

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
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(L.t('editPet.saved'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpace.gapS),
          Expanded(
            child: _ChoiceTile(
              label: labelOf(options[i]),
              icon: iconOf(options[i]),
              selected: options[i].$1 == value,
              onTap: () => onChanged(options[i].$1),
            ),
          ),
        ],
      ],
    );
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
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
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BirthdayField extends StatelessWidget {
  const _BirthdayField({
    required this.birthday,
    required this.estimated,
    required this.onPick,
    required this.onClear,
    required this.onEstimatedChanged,
  });

  final DateTime? birthday;
  final bool estimated;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final ValueChanged<bool> onEstimatedChanged;

  @override
  Widget build(BuildContext context) {
    final has = birthday != null;
    final label = has
        ? '${birthday!.year}-${_p(birthday!.month)}-${_p(birthday!.day)}'
        : L.t('editPet.birthdayPick');

    return Column(
      children: [
        InkWell(
          onTap: onPick,
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
                const Icon(Icons.cake_outlined,
                    size: 18, color: AppColors.textTertiary),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Text(
                    L.t('editPet.birthday'),
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                    color: has ? AppColors.textPrimary : AppColors.textTertiary,
                  ),
                ),
                if (has) ...[
                  const SizedBox(width: AppSpace.gapS),
                  GestureDetector(
                    onTap: onClear,
                    child: const Icon(Icons.close_rounded,
                        size: 16, color: AppColors.textTertiary),
                  ),
                ],
              ],
            ),
          ),
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

  static String _p(int v) => v.toString().padLeft(2, '0');
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
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13.5, color: AppColors.textPrimary),
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
