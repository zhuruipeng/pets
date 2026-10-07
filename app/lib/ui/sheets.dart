/// 添加宠物 / 记一笔 / 添加提醒 —— 三个底部弹层。
///
/// 都放在这里：它们都是「表单类」交互，共用同一套校验和提交节奏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/species.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../domain/expense_stats.dart';
import '../domain/symptom_observation.dart';
import '../providers.dart';
import 'symptom_fields.dart';
import 'widgets.dart';

// ------------------------------------------------------------------ 添加宠物

Future<void> showAddPetSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _AddPetSheet(),
  );
}

/// 已打过的疫苗档位。映射到 immunization.dart 的 RuleSpec.code。
///
/// 为什么是这三档而不是「逐条勾疫苗」：规则集里疫苗只有两个 code
/// （vaccine_core / vaccine_rabies），逐条勾选徒增操作却不改变输出。
enum _VaccineStatus { none, core, coreRabies }

class _AddPetSheet extends ConsumerStatefulWidget {
  const _AddPetSheet();

  @override
  ConsumerState<_AddPetSheet> createState() => _AddPetSheetState();
}

/// 建档三步向导：Step1 物种 + 名字 / Step2 资料 / Step3 属地 + 疫苗。
///
/// 为什么切成三步而不是一整页表单：一次性表单最劝退的是「不知道要填多久」，
/// 拆开后每屏只有一个决策，顶部有进度条，用户随时知道还剩多少。
///
/// 为什么物种在第 1 步而不是塞进资料里：它决定后面整份排期走哪套规则集，
/// 是唯一一个「填错就得重来」的字段，必须最先确定。
///
/// 为什么生日在第 2 步而不是第 3 步：它直接改变第 3 步要问的东西
/// （不知道月龄就推不出该打哪一针），顺序不能反过来。
class _AddPetSheetState extends ConsumerState<_AddPetSheet> {
  static const _stepCount = 3;

  final _name = TextEditingController();
  final _breed = TextEditingController();

  Species _species = Species.dog;
  DateTime? _birthday;
  bool _estimated = false;

  /// Step3：已打过哪些疫苗。决定哪些建议排期不再生成。
  _VaccineStatus _vaccines = _VaccineStatus.none;

  int _step = 0;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _breed.dispose();
    super.dispose();
  }

  /// 把疫苗档位翻成要跳过排期的 code 集合。
  Set<String> get _skipCodes => switch (_vaccines) {
        _VaccineStatus.none => const <String>{},
        _VaccineStatus.core => const {'vaccine_core'},
        _VaccineStatus.coreRabies => const {'vaccine_core', 'vaccine_rabies'},
      };

  bool get _isLast => _step == _stepCount - 1;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.t('addPet.title'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  L.tp('addPet.progress', {'a': _step + 1, 'b': _stepCount}),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            _StepProgress(step: _step, count: _stepCount),
            const SizedBox(height: 18),

            _StepHeader(
              title: _stepTitle,
              hint: _stepHint,
            ),
            const SizedBox(height: 16),

            switch (_step) {
              0 => _stepIdentity(),
              1 => _stepBasics(),
              _ => _stepVaccines(),
            },

            const SizedBox(height: 22),
            Row(
              children: [
                if (_step > 0)
                  Expanded(
                    child: TextButton(
                      onPressed: _submitting
                          ? null
                          : () => setState(() {
                                _step--;
                                _error = null;
                              }),
                      child: Text(L.t('action.back')),
                    ),
                  ),
                if (_step > 0) const SizedBox(width: AppSpace.gapM),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _submitting ? null : _advance,
                      child: _submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _isLast
                                  ? L.t('addPet.submit')
                                  : L.t('action.next'),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String get _stepTitle => switch (_step) {
        0 => L.t('addPet.step1.title'),
        1 => L.t('addPet.step2.title'),
        _ => L.t('addPet.step3.title'),
      };

  String get _stepHint => switch (_step) {
        0 => L.t('addPet.step1.hint'),
        1 => L.t('addPet.step2.hint'),
        _ => L.t('addPet.step3.hint'),
      };

  // ---------------------------------------------------------------- Step 1

  /// 物种 + 名字。名字是唯一的必填项，卡在这一步不让走。
  Widget _stepIdentity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<Species>(
          segments: [
            ButtonSegment(
              value: Species.dog,
              label: Text(L.t('addPet.species.dog')),
              icon: const Text('🐶'),
            ),
            ButtonSegment(
              value: Species.cat,
              label: Text(L.t('addPet.species.cat')),
              icon: const Text('🐱'),
            ),
            ButtonSegment(
              value: Species.other,
              label: Text(L.t('addPet.species.other')),
              icon: const Text('🐾'),
            ),
          ],
          selected: {_species},
          onSelectionChanged: (s) => setState(() => _species = s.first),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _name,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: L.t('addPet.name'),
            hintText: L.t('addPet.name.hint'),
            border: const OutlineInputBorder(),
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- Step 2

  Widget _stepBasics() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _breed,
          decoration: InputDecoration(
            labelText: L.t('addPet.breed'),
            hintText: L.isZh ? '如：金毛、英短蓝猫' : 'e.g. Golden Retriever',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),

        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _pickBirthday,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: L.t('addPet.birthday'),
              hintText: L.t('addPet.birthday.hint'),
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.calendar_today, size: 18),
            ),
            child: Text(
              _birthday == null
                  ? '—'
                  : '${_birthday!.year}-${_birthday!.month}-${_birthday!.day}',
            ),
          ),
        ),

        if (_birthday != null)
          CheckboxListTile(
            value: _estimated,
            onChanged: (v) => setState(() => _estimated = v ?? false),
            title: Text(
              L.t('addPet.birthday.estimated'),
              style: const TextStyle(fontSize: 13.5),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- Step 3

  /// 属地只读展示：它由构建时的 REGION 决定，问一遍用户也不能改。
  /// 但要说清它为什么影响结果，否则用户会以为排期是凭空来的。
  Widget _stepVaccines() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SoftTag(
              AppRegion.current == Region.cn
                  ? L.t('addPet.region.cn')
                  : L.t('addPet.region.intl'),
              color: AppColors.primary,
              bg: AppColors.primaryLight,
              icon: Icons.public_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),

        _VaccineOption(
          label: L.t('addPet.vaccine.none'),
          selected: _vaccines == _VaccineStatus.none,
          onTap: () => setState(() => _vaccines = _VaccineStatus.none),
        ),
        const SizedBox(height: 8),
        _VaccineOption(
          label: L.t('addPet.vaccine.core'),
          selected: _vaccines == _VaccineStatus.core,
          onTap: () => setState(() => _vaccines = _VaccineStatus.core),
        ),
        const SizedBox(height: 8),
        _VaccineOption(
          label: L.t('addPet.vaccine.coreRabies'),
          selected: _vaccines == _VaccineStatus.coreRabies,
          onTap: () => setState(() => _vaccines = _VaccineStatus.coreRabies),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 流转

  /// 「下一步」/「创建」。最后一步才真正落库。
  Future<void> _advance() async {
    // 只有最后一步才落库，前两步纯粹是校验 + 翻页。
    // 中途退出什么都不会写进数据库，不留半成品宠物。
    if (!_isLast) {
      if (_step == 0 && _name.text.trim().isEmpty) {
        setState(() => _error = L.t('addPet.nameRequired'));
        return;
      }
      setState(() {
        _step++;
        _error = null;
      });
      return;
    }
    await _submit();
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? now.subtract(const Duration(days: 365)),
      firstDate: DateTime(now.year - 30),
      lastDate: now,
      helpText: L.t('addPet.birthday'),
    );
    if (picked != null) setState(() => _birthday = picked);
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      // 理论上走不到这里（Step1 已挡），但保个底，别让库里出现无名宠物。
      setState(() {
        _step = 0;
        _error = L.t('addPet.nameRequired');
      });
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final actions = ref.read(appActionsProvider);

      // 计划生成放在 addPet 内部（它要按 skipPlanCodes 过滤），
      // 所以这里不能再调一次 generatePlanFor —— 第二次不带 skip，
      // 会把刚跳过的疫苗又排回来。
      await actions.addPet(
        name: name,
        species: _species,
        birthday: _birthday,
        birthdayEstimated: _estimated,
        breed: _breed.text.trim().isEmpty ? null : _breed.text.trim(),
        skipPlanCodes: _skipCodes,
      );

      // 冷启动顺序：先给价值，再要权限。
      // 到这一步用户已经看到「已生成 N 项提醒」，此时再请求通知授权。
      final created = actions.lastPlanCount;
      if (_birthday != null && created > 0) {
        await ref.read(notificationServiceProvider).requestPermission();
      }

      if (!mounted) return;
      Navigator.of(context).pop();

      if (created > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L.tp('addPet.created', {'n': created})),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }
}

/// 三步进度条。比 LinearProgressIndicator 好在它能明确告诉用户「一共三段」。
class _StepProgress extends StatelessWidget {
  const _StepProgress({required this.step, required this.count});

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              margin: EdgeInsets.only(right: i == count - 1 ? 0 : 6),
              height: 4,
              decoration: BoxDecoration(
                color: i <= step ? AppColors.primary : AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }
}

/// 每一步的题干 + 说明。说明写成为什么需要这条信息，而不是重复题干。
class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          hint,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.textTertiary,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// 疫苗档位的单选项。用整行可点的卡片而不是 Radio，拇指好按。
class _VaccineOption extends StatelessWidget {
  const _VaccineOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: AppRadius.cardBorder,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          borderRadius: AppRadius.cardBorder,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 19,
              color: selected ? AppColors.primary : AppColors.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color:
                      selected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 记一笔

Future<void> showAddRecordSheet(
  BuildContext context,
  WidgetRef ref, {
  required String petId,
  RecordType initialType = RecordType.weight,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AddRecordSheet(petId: petId, initialType: initialType),
  );
}

class _AddRecordSheet extends ConsumerStatefulWidget {
  const _AddRecordSheet({required this.petId, required this.initialType});

  final String petId;
  final RecordType initialType;

  @override
  ConsumerState<_AddRecordSheet> createState() => _AddRecordSheetState();
}

class _AddRecordSheetState extends ConsumerState<_AddRecordSheet> {
  late RecordType _type = widget.initialType;
  SymptomObservation _symptom = const SymptomObservation();
  final _value = TextEditingController();
  final _note = TextEditingController();

  // 用药
  final _medName = TextEditingController();
  final _medDose = TextEditingController();
  String _medRoute = 'oral';

  /// 就诊记录的四个字段。
  ///
  /// 为什么加这些：`RecordType.medical`（就诊）以前**在提交时根本没有 case**，
  /// 走 default 只存一句自由文本 —— 也就是说「带去看医生」这件事在 App 里
  /// 完全没留下可复用的信息。而下次复诊时，医生问「上次怎么处理的」，
  /// 用户根本答不上来。
  ///
  /// 这四个字段对应就诊时医生真正会问的顺序：
  /// 主诉（为什么来）→ 医院/医生（在哪看的）→ 诊断（结论是什么）→ 医嘱（怎么办）。
  final _visitComplaint = TextEditingController();
  final _visitClinic = TextEditingController();
  final _visitDiagnosis = TextEditingController();
  final _visitAdvice = TextEditingController();

  // 喂食
  final _feedGrams = TextEditingController();
  final _feedBrand = TextEditingController();
  String _feedKind = 'dry';

  /// 体重滑块的当前值，**展示单位**（kg 或 lb），提交时才转公制。
  ///
  /// null = 还没拖过，此时回落到「上次体重」或默认值。
  double? _weightDisplay;

  /// 点大数字进入的「直接输入」态。见 _weightField 的注释。
  bool _weightEditing = false;
  final _weightText = TextEditingController();

  /// recordedAt 默认「现在」，但用户可改 —— 补录上个月的疫苗是高频操作。
  late DateTime _recordedAt = DateTime.now();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    _medName.dispose();
    _medDose.dispose();
    _visitComplaint.dispose();
    _visitClinic.dispose();
    _visitDiagnosis.dispose();
    _visitAdvice.dispose();
    _feedGrams.dispose();
    _feedBrand.dispose();
    _weightText.dispose();
    super.dispose();
  }

  static const _types = [
    RecordType.weight,
    RecordType.vaccine,
    RecordType.dewormInternal,
    RecordType.dewormExternal,
    RecordType.medication,
    RecordType.medical,
    RecordType.symptom,
    RecordType.grooming,
    RecordType.feeding,
    RecordType.water,
    RecordType.toilet,
    RecordType.sleep,
    RecordType.note,
  ];

  static const _medRoutes = ['oral', 'topical', 'injection'];
  static const _feedKinds = ['dry', 'wet', 'treat'];

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    const region = AppRegion.current;
    final unit = Units.defaultWeightUnit(region);

    // 体重滑块默认落在「上次体重」上，用户拖动的距离就是这次的变化量。
    final series = ref.watch(weightSeriesProvider(widget.petId)).valueOrNull;
    final lastKg = (series == null || series.isEmpty) ? null : series.last.kg;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.t('addRecord.title'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _types.map((t) {
              final selected = t == _type;
              return ChoiceChip(
                selected: selected,
                onSelected: (_) => setState(() {
                  _type = t;
                  _error = null;
                }),
                avatar: Icon(recordTypeIcon(t), size: 16),
                label: Text(recordTypeLabel(t)),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),

          // 时间选择。默认现在，可回拨 —— 这就是补录入口。
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDateTime,
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(compactDateTime(_recordedAt)),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _recordedAt = DateTime.now()),
                child: Text(L.t('addRecord.when.now')),
              ),
            ],
          ),
          const SizedBox(height: 16),

          _typeFields(unit, lastKg),
          if (_error != null && _type == RecordType.symptom)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ),

          const SizedBox(height: 16),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: L.t('addRecord.note'),
              border: const OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 14),
          // 合规提示：免疫计划是建议性的，不能出现诊断性表述。
          Text(
            L.t('me.disclaimer.short'),
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textTertiary,
            ),
          ),

          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: _submitting ? null : () => _submit(unit),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(L.t('addRecord.save')),
            ),
          ),
        ],
      ),
    );
  }

  /// 按类型切表单。体重 / 用药 / 喂食 / 就诊各有自己的字段，其余落回通用文本框。
  ///
  /// 为什么不每种类型开一屏：这只是个底部弹层，十种类型开十屏会把
  /// 「记一笔」变成导航迷宫。高频四类给专用字段，剩下的够用就行。
  ///
  /// 就诊（medical）为什么值得专用字段：它是**唯一为「别人看」而记的类型** ——
  /// 用户记完会导出报告给医生。通用文本框只能存一句话，而医生要看的是
  /// 「为什么来 / 诊断是什么 / 怎么办」这三件事。
  Widget _typeFields(WeightUnit unit, double? lastKg) => switch (_type) {
        RecordType.weight => _weightField(unit, lastKg),
        RecordType.medication => _medicationFields(),
        RecordType.medical => _medicalFields(),
        RecordType.symptom => SymptomFields(
            petId: widget.petId,
            initial: _symptom,
            onChanged: (v) => _symptom = v,
          ),
        RecordType.feeding => _feedingFields(),
        // 饮水与睡眠填的是「数值 + 固定单位」。走通用文本框但要补单位后缀 ——
        // 否则用户不知道那个 200 是毫升还是口数，也没法参与「今天喝了多少」的统计。
        RecordType.water => _amountField('ml'),
        RecordType.sleep => _amountField('h'),
        _ => TextField(
            controller: _value,
            decoration: InputDecoration(
              labelText: L.t('addRecord.value'),
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
      };

  /// 数值 + 固定单位的小输入框（饮水 ml / 睡眠 h）。
  Widget _amountField(String suffix) => TextField(
        controller: _value,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: L.t('addRecord.value'),
          suffixText: suffix,
          border: const OutlineInputBorder(),
          errorText: _error,
        ),
      );

  /// 体重：大数字（可点按直接输入）+ −/＋ 步进 + 滑块。
  ///
  /// 三种输入各有分工：滑块负责「拖两下就完」的高频微调；−/＋ 按 0.1 步进，
  /// 适合「比上次重一点」的场景；点大数字直接敲键盘，负责精确值
  /// （宠物医院称出来是 4.35，就得能敲 4.35）。滑块不再是很久以前那种
  /// 「唯一输入方式」—— 只能拖不能敲，用户就只能记个约数。
  Widget _weightField(WeightUnit unit, double? lastKg) {
    final minW = unit == WeightUnit.kg ? 0.5 : 1.0;
    final maxW = unit == WeightUnit.kg ? 80.0 : 176.0;
    // clamp 返回 num，Slider 只吃 double —— 这里必须 toDouble。
    final value =
        (_weightDisplay ?? _fallbackWeight(unit, lastKg)).clamp(minW, maxW).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _weightStepButton(Icons.remove_rounded, -0.1, value, minW, maxW),
            const SizedBox(width: 14),
            GestureDetector(
              onTap: () => setState(() {
                _weightEditing = true;
                _weightText.text = value.toStringAsFixed(1);
              }),
              child: _weightEditing
                  ? SizedBox(
                      width: 150,
                      child: TextField(
                        controller: _weightText,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                          height: 1.1,
                        ),
                        decoration: const InputDecoration.collapsed(
                          hintText: '0.0',
                        ),
                        onSubmitted: (_) =>
                            _commitWeightEdit(unit, minW, maxW),
                        // 点输入框外面 = 确认。不写这个，键盘收起后
                        // 还停在编辑态，滑块就一直是旧值。
                        onTapOutside: (_) =>
                            _commitWeightEdit(unit, minW, maxW),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          value.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          Units.weightSymbol(unit),
                          style: const TextStyle(
                            fontSize: 15,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 14),
            _weightStepButton(Icons.add_rounded, 0.1, value, minW, maxW),
          ],
        ),
        Slider(
          value: value,
          min: minW,
          max: maxW,
          onChanged: (v) => setState(() {
            _weightDisplay = v;
            _error = null;
          }),
        ),
        if (lastKg != null)
          Center(
            child: Text(
              L.tp('addRecord.weight.last',
                  {'v': Units.formatWeight(lastKg, unit)}),
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textTertiary,
              ),
            ),
          ),
      ],
    );
  }

  /// −/＋ 步进钮。步长 0.1，钳制在滑块的量程内 —— 负数和离谱值
  /// 从构造上就进不来，不需要保存时再拦一遍。
  Widget _weightStepButton(
    IconData icon,
    double step,
    double value,
    double minW,
    double maxW,
  ) {
    return SizedBox(
      width: 42,
      height: 42,
      child: OutlinedButton(
        onPressed: () => setState(() {
          _weightDisplay = (value + step).clamp(minW, maxW).toDouble();
          _error = null;
        }),
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
          side: const BorderSide(color: AppColors.border),
        ),
        child: Icon(icon, size: 20, color: AppColors.primary),
      ),
    );
  }

  /// 提交键盘输入。合法才生效并退出编辑；非法（空、负数、乱码）静默
  /// 回退到原值 —— 这里的体重永远有值（默认值兜底），不存在「空值
  /// 要不要保存」的问题，也就不必为非法输入弹错误打断用户。
  void _commitWeightEdit(WeightUnit unit, double minW, double maxW) {
    if (!_weightEditing) return;
    final raw = _weightText.text.replaceAll(',', '.').trim();
    final v = double.tryParse(raw);
    setState(() {
      if (v != null && v > 0) {
        _weightDisplay = v.clamp(minW, maxW).toDouble();
        _error = null;
      }
      _weightEditing = false;
    });
  }

  static double _fallbackWeight(WeightUnit unit, double? lastKg) {
    if (lastKg != null) return Units.toDisplayWeight(lastKg, unit);
    return unit == WeightUnit.kg ? 10.0 : 22.0;
  }

  /// 用药：药品名 + 剂量 + 给药方式。
  ///
  /// 剂量是自由文本而不是数字 —— 「1 片」「0.5 ml」「半包」都是合法答案，
  /// 硬拆成数字 + 单位只会逼用户瞎填。
  Widget _medicationFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _medName,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: L.t('addRecord.med.name'),
            hintText: L.t('addRecord.med.nameHint'),
            border: const OutlineInputBorder(),
            errorText: _error,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _medDose,
          decoration: InputDecoration(
            labelText: L.t('addRecord.med.dose'),
            hintText: L.t('addRecord.med.doseHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          L.t('addRecord.med.route'),
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _medRoutes
              .map(
                (r) => ChoiceChip(
                  selected: _medRoute == r,
                  onSelected: (_) => setState(() => _medRoute = r),
                  label: Text(medRouteLabel(r)),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  /// 就诊：主诉 + 医院/医生 + 诊断 + 医嘱。
  ///
  /// 字段顺序按就诊时医生实际问诊的顺序排，不是按数据结构排 ——
  /// 用户是照着医生问的顺序填的，照着「数据结构」排会让人跳来跳去。
  ///
  /// 全部可空，但**主诉建议填**：它是「为什么来」的答案，也是复诊时医生
  /// 第一个要确认的事。诊断和医嘱很多人记不清，留空比乱填好。
  Widget _medicalFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _visitComplaint,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: L.t('addRecord.med.complaint'),
            hintText: L.t('addRecord.med.complaintHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _visitClinic,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: L.t('addRecord.med.clinic'),
            hintText: L.t('addRecord.med.clinicHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _visitDiagnosis,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: L.t('addRecord.med.diagnosis'),
            hintText: L.t('addRecord.med.diagnosisHint'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _visitAdvice,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: L.t('addRecord.med.advice'),
            hintText: L.t('addRecord.med.adviceHint'),
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }


  /// 喂食：类型 + 克数 + 品牌。
  Widget _feedingFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L.t('addRecord.feed.kind'),
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _feedKinds
              .map(
                (k) => ChoiceChip(
                  selected: _feedKind == k,
                  onSelected: (_) => setState(() => _feedKind = k),
                  label: Text(feedKindLabel(k)),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _feedGrams,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: L.t('addRecord.feed.grams'),
            suffixText: 'g',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _feedBrand,
          decoration: InputDecoration(
            labelText: L.t('addRecord.feed.brand'),
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _recordedAt,
      firstDate: DateTime(DateTime.now().year - 20),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_recordedAt),
    );
    if (!mounted) return;

    setState(() {
      _recordedAt = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? _recordedAt.hour,
        time?.minute ?? _recordedAt.minute,
      );
    });
  }

  /// 滑块当前值（展示单位）。没拖过就取上次体重，再没有就用默认中值。
  double _currentWeight(WeightUnit unit) {
    final v = _weightDisplay;
    if (v != null) return v;
    final series = ref.read(weightSeriesProvider(widget.petId)).valueOrNull;
    final lastKg = (series == null || series.isEmpty) ? null : series.last.kg;
    return _fallbackWeight(unit, lastKg);
  }

  Future<void> _submit(WeightUnit unit) async {
    double? num_;
    String? text;
    String? unitWire;
    Map<String, dynamic> payload = const {};

    switch (_type) {
      case RecordType.symptom:
        try {
          payload = _symptom.toPayload();
          text = _symptom.symptom;
        } on ArgumentError catch (e) {
          setState(() => _error = L.error(e));
          return;
        }
        break;
      case RecordType.weight:
        // 输入按展示单位，存储统一公制。
        num_ = Units.fromDisplayWeight(_currentWeight(unit), unit);
        unitWire = 'kg';
        break;

      case RecordType.medication:
        final name = _medName.text.trim();
        if (name.isEmpty) {
          setState(() => _error = L.t('addRecord.med.nameRequired'));
          return;
        }
        text = name;
        payload = {'dose': _medDose.text.trim(), 'route': _medRoute};
        break;

      // ⚠️ 这个 case 以前**不存在** —— medical 落到 switch 的 default 分支，
      // 只存一句自由文本。而 medical 是**唯一为「给医生看」而记的类型**，
      // 结果导出报告时医生看到的是一句没有结构的话，
      // 「主诉 / 诊断 / 医嘱」这三件最关键的信息全都没留下。
      case RecordType.medical:
        // 四个字段都可不填：记不清就空着，比编一句强。
        // 但**全空**时给一句话兜底，否则时间线上会出现一条完全空白的就诊记录，
        // 让人以为「去了医院但什么都没记」。
        final complaint = _visitComplaint.text.trim();
        final clinic = _visitClinic.text.trim();
        final diagnosis = _visitDiagnosis.text.trim();
        final advice = _visitAdvice.text.trim();

        if (complaint.isEmpty && clinic.isEmpty && diagnosis.isEmpty && advice.isEmpty) {
          setState(() => _error = L.t('addRecord.med.oneRequired'));
          return;
        }

        // text 用「诊断」优先，其次医院名 —— 这条会显示在时间线上，
        // 是用户在列表里一眼扫过时看到的那句话，所以优先给信息量最大的。
        text = diagnosis.isNotEmpty
            ? diagnosis
            : (complaint.isNotEmpty
                ? complaint
                : (clinic.isNotEmpty ? clinic : advice));
        payload = {
          if (complaint.isNotEmpty) 'complaint': complaint,
          if (clinic.isNotEmpty) 'clinic': clinic,
          if (diagnosis.isNotEmpty) 'diagnosis': diagnosis,
          if (advice.isNotEmpty) 'advice': advice,
        };
        break;

      case RecordType.feeding:
        final g = double.tryParse(_feedGrams.text.trim());
        if (g != null && g > 0) {
          num_ = g;
          unitWire = 'g';
        }
        final brand = _feedBrand.text.trim();
        payload = {
          'kind': _feedKind,
          if (brand.isNotEmpty) 'brand': brand,
        };
        break;

      // 饮水与睡眠：填的是数字就存成数值（参与汇总），填的是文字就存文本。
      // 单位固定，用户不用选。
      case RecordType.water:
        final ml = double.tryParse(_value.text.trim());
        if (ml != null && ml > 0) {
          num_ = ml;
          unitWire = 'ml';
        } else if (_value.text.trim().isNotEmpty) {
          text = _value.text.trim();
        }
        break;

      case RecordType.sleep:
        final h = double.tryParse(_value.text.trim());
        if (h != null && h > 0) {
          num_ = h;
          unitWire = 'h';
        } else if (_value.text.trim().isNotEmpty) {
          text = _value.text.trim();
        }
        break;

      default:
        final raw = _value.text.trim();
        if (raw.isNotEmpty) text = raw;
        break;
    }

    final note = _note.text.trim();

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref.read(appActionsProvider).addRecord(
            petId: widget.petId,
            type: _type,
            // 关键：事件时间用用户选的，不是 DateTime.now()。
            recordedAt: _recordedAt,
            valueNum: num_,
            valueText: text,
            unit: unitWire,
            payload: payload,
            note: note.isEmpty ? null : note,
          );

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('addRecord.saved'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }
}

// ------------------------------------------------------------------ 遛狗结果

/// 遛狗结果页（参考稿屏 12）。结束后立刻弹，趁印象还热把心情和备注收上来。
///
/// **不画地图**：地图渲染是按市场开关的（见 [AppRegion.mapRenderingEnabled]），
/// 海外版有、中国版没有。为了一个占位图壳写两套绘制代码不划算，也不诚实 ——
/// 没有轨迹的地方硬摆一张地图，等于告诉用户「我们记录了路线」，其实没有。
///
/// **不显示千卡**：热量消耗要靠 MET 系数 × 体重才估得出来，两个数据源我们都没有。
/// 硬摆一个数字就是编数据，跟当初删掉的「健康评分」是同一类毛病。
Future<void> showWalkResultSheet(
  BuildContext context,
  WidgetRef ref, {
  required WalkSession session,
  required String petName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _WalkResultSheet(session: session, petName: petName),
  );
}

class _WalkResultSheet extends ConsumerStatefulWidget {
  const _WalkResultSheet({required this.session, required this.petName});

  final WalkSession session;
  final String petName;

  @override
  ConsumerState<_WalkResultSheet> createState() => _WalkResultSheetState();
}

class _WalkResultSheetState extends ConsumerState<_WalkResultSheet> {
  String? _mood;
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    const region = AppRegion.current;
    final dUnit = Units.defaultDistanceUnit(region);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.t('walk.result'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpace.gapXs),
          Text(
            widget.petName,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpace.gapL),

          // 距离 / 时长：两个真算出来的数，不是估的。
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.gapL,
              vertical: AppSpace.gapL,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.cardBorder,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: StatTile(
                    icon: Icons.straighten_rounded,
                    value: Units.metersToDisplay(
                      widget.session.distanceM,
                      dUnit,
                    ).toStringAsFixed(2),
                    unit: Units.distanceSymbol(dUnit),
                    label: L.t('walk.distance'),
                    tint: AppColors.tileTints[3],
                  ),
                ),
                const StatDivider(),
                Expanded(
                  child: StatTile(
                    icon: Icons.schedule_rounded,
                    value: durationLabel(widget.session.durationS),
                    label: L.t('walk.duration'),
                    tint: AppColors.tileTints[1],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpace.gapL),
          Text(
            L.t('walk.mood'),
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpace.gapS),
          Row(
            children: [
              // 五个表情等分一行。selected 再点一次可以取消 —— 心情可以不选，
              // 强制选一个就是在制造假数据。
              for (final code in kWalkMoods)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.gapXs),
                    child: _MoodTile(
                      code: code,
                      selected: _mood == code,
                      onTap: () => setState(
                        () => _mood = _mood == code ? null : code,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: AppSpace.gapL),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: L.t('addRecord.note'),
              border: const OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: AppSpace.gapL),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(L.t('action.save')),
            ),
          ),
          Center(
            child: TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: Text(L.t('walk.result.skip')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final note = _note.text.trim();
    try {
      await ref.read(appActionsProvider).saveWalkFeedback(
            widget.session.id,
            mood: _mood,
            note: note.isEmpty ? null : note,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _MoodTile extends StatelessWidget {
  const _MoodTile({
    required this.code,
    required this.selected,
    required this.onTap,
  });

  final String code;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryLight : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(
              walkMoodEmoji(code),
              style: const TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 3),
            Text(
              walkMoodLabel(code),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 记一笔花费

/// 记一笔花费。
///
/// 与「记一笔记录」分开弹层，而不是在记录表单里加个金额框：
/// 一是**不是每件事都花钱**（朋友给的药、自己剪的指甲），硬塞金额框会让
/// 每次记记录都要面对一个填不填的抉择；二是**不是每笔钱都有对应事件**
/// （一袋粮吃一个月），反过来塞也塞不进去。
///
/// 金额用数字键盘 + 只允许一个小数点，不接单位换算 —— 汇率是外部数据，
/// 我们没有来源，硬给一个换算出来的数字就是编数据。
Future<void> showAddExpenseSheet(
  BuildContext context,
  WidgetRef ref, {
  required String petId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AddExpenseSheet(petId: petId),
  );
}

class _AddExpenseSheet extends ConsumerStatefulWidget {
  const _AddExpenseSheet({required this.petId});

  final String petId;

  @override
  ConsumerState<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends ConsumerState<_AddExpenseSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  ExpenseCategory _category = ExpenseCategory.food;

  /// 消费日期。默认今天 —— 大多数人记的是刚刚花掉的钱。
  /// 可以回拨（补录上周的账单），但**不能选未来**：那不是支出，是预算，
  /// 混在一起会让「本月支出」变成一个可以随便改的数字。
  late DateTime _spentAt = DateTime.now();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final currency = AppRegion.current.defaultCurrency;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.t('expense.add'),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: L.t('expense.amount'),
              prefixText: '${currencySymbolOf(currency)} ',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          const SizedBox(height: 18),

          Text(
            L.t('expense.category'),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ExpenseCategory.values.map((c) {
              return ChoiceChip(
                selected: c == _category,
                onSelected: (_) => setState(() => _category = c),
                avatar: Icon(expenseCategoryIcon(c), size: 16),
                label: Text(expenseCategoryLabel(c)),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(compactDate(_spentAt)),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _spentAt = DateTime.now()),
                child: Text(L.t('expense.when.today')),
              ),
            ],
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: L.t('expense.note'),
              border: const OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(L.t('expense.save')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _spentAt,
      firstDate: DateTime(DateTime.now().year - 20),
      // 不许选未来：那是预算，不是支出。
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    setState(() => _spentAt = date);
  }

  Future<void> _submit() async {
    // 用户可能输入带空格或全角字符，先规整再解析。
    final raw = _amount.text.replaceAll(RegExp(r'[,\s]'), '').trim();
    final amount = double.tryParse(raw);

    if (amount == null || amount <= 0) {
      setState(() => _error = L.t('expense.amountRequired'));
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref.read(appActionsProvider).addExpense(
            petId: widget.petId,
            amount: amount,
            category: _category,
            spentAt: _spentAt,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('expense.saved'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }
}
