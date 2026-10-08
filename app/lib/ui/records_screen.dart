/// 记录页 —— 时间线 + 搜索 + 类型筛选 + 体重曲线。
///
/// 时间线按 recordedAt 排，不是 createdAt。
/// 补录的上个月疫苗，会出现在它该出现的位置，而不是插在列表顶部。
///
/// 搜索与筛选是**与**关系：先按类型圈定，再在圈定结果里搜文本。
/// 只搜三个地方 —— 备注、类型名、payload 摘要。不搜数值，
/// 因为「搜 12」会把 12kg 和 12g 混在一起，没人这么找记录。
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../providers.dart';
import 'record_detail.dart';
import 'sheets.dart';
import 'widgets.dart';

class RecordsScreen extends ConsumerStatefulWidget {
  const RecordsScreen({super.key});

  @override
  ConsumerState<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends ConsumerState<RecordsScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pet = ref.watch(currentPetProvider);

    if (pet == null) {
      return EmptyState(
        icon: Icons.pets_outlined,
        title: L.t('records.noPet'),
        action: FilledButton.icon(
          onPressed: () => showAddPetSheet(context, ref),
          icon: const Icon(Icons.add),
          label: Text(L.t('action.add')),
        ),
      );
    }

    final records = ref.watch(petRecordsProvider(pet.id));
    final filter = ref.watch(recordFilterProvider);

    return records.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (all) {
        final visible = all.where((r) {
          if (filter != null && r.type != filter) return false;
          return _matches(r, _q);
        }).toList();

        final searching = _q.trim().isNotEmpty;

        return Column(
          children: [
            _Header(pet: pet),
            _SearchField(
              controller: _search,
              onChanged: (v) => setState(() => _q = v),
            ),
            _FilterBar(
                current: filter,
                onChanged: (t) {
                  ref.read(recordFilterProvider.notifier).state = t;
                }),
            Expanded(
              child: all.isEmpty
                  ? EmptyState(
                      icon: Icons.timeline_rounded,
                      title: L.t('records.empty.title'),
                      hint: L.t('records.empty.hint'),
                      action: FilledButton.icon(
                        onPressed: () => showAddRecordSheet(
                          context,
                          ref,
                          petId: pet.id,
                        ),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(L.t('today.quickAdd')),
                      ),
                    )
                  : Stack(
                      children: [
                        ListView(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpace.page,
                            AppSpace.gapXs,
                            AppSpace.page,
                            96,
                          ),
                          children: [
                            // 搜索时不画曲线 —— 曲线是全量的，跟搜索结果不匹配，
                            // 一起显示会让人误以为曲线也在跟着筛。
                            if (!searching &&
                                (filter == null || filter == RecordType.weight))
                              WeightChartCard(petId: pet.id),
                            if (visible.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 48),
                                child: Center(
                                  child: Text(
                                    searching
                                        ? L.t('records.search.none')
                                        : L.t('records.empty.title'),
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              )
                            else
                              RecordTimeline(records: visible),
                          ],
                        ),
                        Positioned(
                          right: AppSpace.page,
                          bottom: AppSpace.gapL,
                          child: FloatingActionButton(
                            onPressed: () => showAddRecordSheet(
                              context,
                              ref,
                              petId: pet.id,
                              initialType: filter ?? RecordType.weight,
                            ),
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            elevation: 2,
                            shape: const CircleBorder(),
                            child: const Icon(Icons.add_rounded),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 一条记录是否命中搜索词。
  ///
  /// 只看「用户自己写下的字」+ 类型名：备注、数值文本、payload 摘要。
  /// 大小写不敏感，方便搜英文药名。
  static bool _matches(PetRecord r, String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return true;

    final hay = <String>[
      r.note ?? '',
      r.valueText ?? '',
      recordTypeLabel(r.type),
      recordPayloadSummary(r),
    ].join(' ').toLowerCase();

    return hay.contains(needle);
  }
}

// ------------------------------------------------------------------ 页头

class _Header extends StatelessWidget {
  const _Header({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapS,
        AppSpace.page,
        0,
      ),
      child: Row(
        children: [
          Text(
            L.t('records.title'),
            style: AppText.pageTitle,
          ),
          const Spacer(),
          SoftTag(
            pet.name,
            color: AppColors.textSecondary,
            bg: AppColors.divider,
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 搜索

/// 搜索框。自带清除按钮 —— 搜完不清会让列表一直停在被筛过的状态，
/// 用户会以为自己丢了几十条记录。
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapM,
        AppSpace.page,
        0,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: L.t('records.search.hint'),
          hintStyle: const TextStyle(
            fontSize: 14,
            color: AppColors.textTertiary,
          ),
          prefixIcon: const Icon(Icons.search_rounded,
              size: 19, color: AppColors.textTertiary),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: AppColors.textTertiary,
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              );
            },
          ),
          isDense: true,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.tile),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.tile),
            borderSide: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 筛选条

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.current, required this.onChanged});

  final RecordType? current;
  final ValueChanged<RecordType?> onChanged;

  static const _options = <RecordType?>[
    null,
    RecordType.weight,
    RecordType.vaccine,
    RecordType.dewormInternal,
    RecordType.dewormExternal,
    RecordType.medication,
    RecordType.medical,
    RecordType.feeding,
    RecordType.toilet,
    RecordType.note,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56 + (MediaQuery.textScalerOf(context).scale(13) - 13),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.page,
          vertical: AppSpace.gapXs,
        ),
        itemCount: _options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final opt = _options[i];
          final selected = current == opt;
          final label =
              opt == null ? L.t('records.filter.all') : recordTypeLabel(opt);

          return ChoiceChip(
            label: Text(label),
            selected: selected,
            showCheckmark: false,
            onSelected: (_) => onChanged(opt),
            selectedColor: AppColors.primaryLight,
            backgroundColor: AppColors.surface,
            labelStyle: AppText.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.primaryText : AppColors.textSecondary,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            side: BorderSide(
              color: selected ? AppColors.primaryLight : AppColors.border,
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ 体重曲线

class WeightChartCard extends ConsumerWidget {
  const WeightChartCard({super.key, required this.petId});

  final String petId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = ref.watch(weightSeriesProvider(petId));
    const region = AppRegion.current;
    final unit = Units.defaultWeightUnit(region);

    return series.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (points) {
        if (points.length < 2) {
          return Container(
            margin: const EdgeInsets.only(bottom: AppSpace.gapS),
            padding: const EdgeInsets.all(AppSpace.gapL),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadius.cardBorder,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.show_chart_rounded,
                    color: AppColors.textTertiary, size: 19),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Text(
                    L.t('records.weight.empty'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        // 存储层是 kg，展示层换算。
        final values =
            points.map((p) => Units.toDisplayWeight(p.kg, unit)).toList();
        final minV = values.reduce((a, b) => a < b ? a : b);
        final maxV = values.reduce((a, b) => a > b ? a : b);
        final pad = ((maxV - minV) * 0.25).clamp(0.2, 10.0);

        return Container(
          margin: const EdgeInsets.only(bottom: AppSpace.gapM),
          padding: const EdgeInsets.fromLTRB(
            AppSpace.gapM,
            AppSpace.gapM,
            AppSpace.gapM,
            AppSpace.gapM,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(
                      L.t('records.weight.title'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                    )),
                    const SizedBox(width: AppSpace.gapM),
                    Text(
                      Units.formatWeight(points.last.kg, unit),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.gapM),
              SizedBox(
                height: 128,
                child: LineChart(
                  LineChartData(
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: ((maxV - minV) / 3).clamp(0.5, 20),
                      getDrawingHorizontalLine: (_) => const FlLine(
                        color: AppColors.divider,
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 40,
                          getTitlesWidget: (v, meta) => Text(
                            v.toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 26,
                          interval:
                              (points.length / 3).ceilToDouble().clamp(1, 999),
                          getTitlesWidget: (v, meta) {
                            final i = v.round();
                            if (i < 0 || i >= points.length) {
                              return const SizedBox.shrink();
                            }
                            final d = points[i].at;
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '${d.month}/${d.day}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    minY: (minV - pad).clamp(0, double.infinity),
                    maxY: maxV + pad,
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (spots) => spots.map((s) {
                          final d = points[s.x.round()].at;
                          return LineTooltipItem(
                            '${_ds(d)}  '
                            '${s.y.toStringAsFixed(2)} ${Units.weightSymbol(unit)}',
                            const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < values.length; i++)
                            FlSpot(i.toDouble(), values[i]),
                        ],
                        isCurved: true,
                        curveSmoothness: 0.22,
                        barWidth: 2.4,
                        color: AppColors.primary,
                        dotData: FlDotData(
                          show: true,
                          getDotPainter: (_, __, ___, ____) =>
                              FlDotCirclePainter(
                            radius: 3,
                            color: AppColors.primary,
                            strokeWidth: 1.5,
                            strokeColor: Colors.white,
                          ),
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          color: AppColors.primary.withValues(alpha: 0.10),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _ds(DateTime d) => '${d.year}-${_p(d.month)}-${_p(d.day)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}

// ------------------------------------------------------------------ 时间线

class RecordTimeline extends StatelessWidget {
  const RecordTimeline({super.key, required this.records});

  final List<PetRecord> records;

  @override
  Widget build(BuildContext context) {
    // 已按 recordedAt DESC 排好，直接按天分组。
    final groups = <String, List<PetRecord>>{};
    for (final r in records) {
      groups.putIfAbsent(relativeDay(r.recordedAt), () => []).add(r);
    }

    // 体重差值：相邻两条体重相减，挂到后一条上。
    final deltas = _weightDeltas(records);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in groups.entries) ...[
          SectionHeader(entry.key),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.gapL,
                vertical: AppSpace.gapXs,
              ),
              child: Column(
                children: [
                  for (var i = 0; i < entry.value.length; i++) ...[
                    if (i > 0) const RowDivider(),
                    RecordRow(
                      record: entry.value[i],
                      weightDelta: deltas[entry.value[i].id],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 按时间升序把相邻两条体重相减，差值记在后一条的 id 上。
  ///
  /// 第一条没有「上次」，不入表 —— 它显示不出差值就别显示。
  static Map<String, double> _weightDeltas(List<PetRecord> records) {
    final weights = records
        .where((r) => r.type == RecordType.weight && r.valueNum != null)
        .toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

    final out = <String, double>{};
    for (var i = 1; i < weights.length; i++) {
      out[weights[i].id] = weights[i].valueNum! - weights[i - 1].valueNum!;
    }
    return out;
  }
}

class RecordRow extends ConsumerWidget {
  const RecordRow({
    super.key,
    required this.record,
    this.weightDelta,
  });

  final PetRecord record;

  /// 与上一次体重的差（kg，存储单位）。null = 算不出来（首条或非体重）。
  final double? weightDelta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const region = AppRegion.current;
    final wUnit = Units.defaultWeightUnit(region);
    final r = record;

    // 补录判定：事件时间与入库时间差超过 1 小时。
    final backfilled =
        r.createdAt.difference(r.recordedAt).abs() > const Duration(hours: 1);

    final valueLine = recordValueLine(r, wUnit);
    final summary = recordPayloadSummary(r);
    final deltaLine = _deltaLine(wUnit);

    return InkWell(
      borderRadius: AppRadius.tileBorder,
      onTap: () => showRecordDetailSheet(context, ref, record: r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors
                    .tileTints[r.type.index % AppColors.tileTints.length],
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(recordTypeIcon(r.type),
                  size: 17, color: AppColors.primary),
            ),
            const SizedBox(width: AppSpace.gapS),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: AppSpace.gapXs,
                    children: [
                      Text(
                        recordTypeLabel(r.type),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (backfilled) ...[
                        SoftTag(
                          L.t('timeline.backfilled'),
                          color: AppColors.warning,
                          bg: AppColors.warningBg,
                        ),
                      ],
                    ],
                  ),
                  if (valueLine != null) ...[
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: AppSpace.gapXs,
                      children: [
                        Text(
                          valueLine,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                        if (deltaLine != null) ...[
                          Text(
                            deltaLine,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (summary.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                  if ((r.note ?? '').isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      r.note!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpace.gapS),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _hm(r.recordedAt),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => _delete(ref),
                  tooltip: L.t('action.delete'),
                  constraints: const BoxConstraints(
                    minWidth: AppSpace.tapTarget,
                    minHeight: AppSpace.tapTarget,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close_rounded,
                      size: 18, color: AppColors.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「较上次 +0.4 kg」。只报差值，不评价胖瘦 —— 那是兽医的活。
  ///
  /// 差值小于 0.05 视为持平，这时整段不出现，免得列表里飘一串「+0.0」。
  String? _deltaLine(WeightUnit unit) {
    final d = weightDelta;
    if (d == null || record.type != RecordType.weight) return null;

    final v = Units.toDisplayWeight(d, unit);
    if (v.abs() < 0.05) return null;

    final sign = v > 0 ? '+' : '-';
    return '${L.t('home.vsLast')} $sign'
        '${v.abs().toStringAsFixed(1)} ${Units.weightSymbol(unit)}';
  }

  Future<void> _delete(WidgetRef ref) async {
    await ref.read(recordRepositoryProvider).softDelete(record.id);
    ref.invalidate(petRecordsProvider(record.petId));
    ref.invalidate(weightSeriesProvider(record.petId));
  }

  static String _hm(DateTime d) => '${_p(d.hour)}:${_p(d.minute)}';

  static String _p(int v) => v.toString().padLeft(2, '0');
}
