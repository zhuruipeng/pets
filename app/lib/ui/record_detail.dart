/// 记录详情页 —— 把一条记录完整摊开，并提供照片附件、改时间与删除。
///
/// 为什么需要单独一页：时间线那一行只能塞下「类型 + 数值 + 一行备注」，
/// 补录类记录的真实信息往往更多（剂量、给药方式、品牌、当时的备注）。
/// 列表负责扫，详情负责看和改。
///
/// 这里**不做**「健康评价」—— 只把用户自己填的东西原样摆出来。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../providers.dart';
import 'widgets.dart';

/// 从列表进详情。返回被删/改后需要刷新哪些 provider 由列表自己处理，
/// 所以这里只需要把记录传进去。
Future<void> showRecordDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required PetRecord record,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _RecordDetailSheet(record: record),
  );
}

class _RecordDetailSheet extends ConsumerStatefulWidget {
  const _RecordDetailSheet({required this.record});

  final PetRecord record;

  @override
  ConsumerState<_RecordDetailSheet> createState() => _RecordDetailSheetState();
}

class _RecordDetailSheetState extends ConsumerState<_RecordDetailSheet> {
  late PetRecord _record = widget.record;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    const region = AppRegion.current;
    final unit = Units.defaultWeightUnit(region, region.name);
    final r = _record;

    final valueLine = recordValueLine(r, unit);
    final summary = recordPayloadSummary(r);
    final backfilled =
        r.createdAt.difference(r.recordedAt).abs() > const Duration(hours: 1);

    // 体重差值：序列升序，取严格早于本记录的最后一条。
    // 时间相等视为自己（差值 0 没有意义），所以用 isBefore 而不是 <=。
    double? changeKg;
    if (r.type == RecordType.weight && r.valueNum != null) {
      final series = ref.watch(weightSeriesProvider(r.petId)).valueOrNull;
      if (series != null) {
        DateTime? prevAt;
        var prevKg = 0.0;
        for (final e in series) {
          if (!e.at.isBefore(r.recordedAt)) break;
          prevAt = e.at;
          prevKg = e.kg;
        }
        if (prevAt != null) changeKg = r.valueNum! - prevKg;
      }
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.tileTints[
                        r.type.index % AppColors.tileTints.length],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(recordTypeIcon(r.type),
                      size: 19, color: AppColors.primary),
                ),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recordTypeLabel(r.type),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (backfilled) ...[
                        const SizedBox(height: 4),
                        SoftTag(
                          L.t('timeline.backfilled'),
                          color: AppColors.warning,
                          bg: AppColors.warningBg,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            if (valueLine != null) ...[
              const SizedBox(height: 18),
              Text(
                valueLine,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
              // 体重记录带「与上次相比」。差值小于 0.05 视为持平不显示，
              // 和时间线同一把尺子。只报差值不评价胖瘦。
              if (changeKg != null && changeKg.abs() >= 0.05) ...[
                const SizedBox(height: 6),
                Text(
                  '${L.t('detail.change')} '
                  '${changeKg > 0 ? '+' : '-'}'
                  '${Units.toDisplayWeight(changeKg.abs(), unit).toStringAsFixed(1)} '
                  '${Units.weightSymbol(unit)}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],

            if (summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                summary,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
            ],

            const SizedBox(height: 20),
            _DetailRow(
              label: L.t('detail.recordedAt'),
              value: compactDateTime(r.recordedAt),
              hint: backfilled ? L.t('detail.backfilledHint') : null,
            ),
            const SizedBox(height: 10),
            _DetailRow(
              label: L.t('detail.createdAt'),
              value: compactDateTime(r.createdAt),
            ),
            if ((r.note ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              _DetailRow(
                label: L.t('detail.note'),
                value: r.note!,
              ),
            ],

            const SizedBox(height: 16),
            _PhotosSection(recordId: r.id),

            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _editTime,
                    icon: const Icon(Icons.schedule_rounded, size: 18),
                    label: Text(L.t('detail.editTime')),
                  ),
                ),
                const SizedBox(width: AppSpace.gapM),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _confirmDelete,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: Text(L.t('action.delete')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
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

  /// 只改 recordedAt —— 这是补录时最常记错的东西，
  /// 也是整条时间线的排序依据，比改数值更常用。
  ///
  /// createdAt 一律不动：它是「什么时候录进来的」的事实，改了就丢证据。
  Future<void> _editTime() async {
    final now = DateTime.now();
    final initial = _record.recordedAt.isAfter(now) ? now : _record.recordedAt;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 30),
      lastDate: now,
      helpText: L.t('detail.recordedAt'),
    );
    if (date == null) return;

    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: L.t('detail.recordedAt'),
    );
    if (time == null) return;

    final at = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    setState(() => _busy = true);
    try {
      final updated = await ref
          .read(recordRepositoryProvider)
          .updateRecordedAt(_record.id, at);
      if (!mounted) return;
      if (updated != null) {
        ref.invalidate(petRecordsProvider(updated.petId));
        ref.invalidate(weightSeriesProvider(updated.petId));
        setState(() {
          _record = updated;
          _busy = false;
        });
      } else {
        setState(() => _busy = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('detail.deleteConfirm')),
        content: Text(L.t('detail.deleteConfirm.hint')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.t('action.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(L.t('action.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    await ref.read(recordRepositoryProvider).softDelete(_record.id);
    ref.invalidate(petRecordsProvider(_record.petId));
    ref.invalidate(weightSeriesProvider(_record.petId));
    if (!mounted) return;
    Navigator.of(context).pop();
  }
}

/// 详情里的「标签 / 值」一行。hint 是值底下的浅色补充说明。
class _DetailRow extends StatelessWidget {  const _DetailRow({required this.label, required this.value, this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textTertiary,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                  height: 1.4,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(
                  hint!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 照片附件

/// 照片区：横向缩略图 + 添加格。长按缩略图删除（软删，物理文件保留）。
///
/// 只用 Image.file 读本地拷贝 —— 附件仓储保证入库前已把文件
/// 拷进应用文档目录，这里不处理相册临时路径。
class _PhotosSection extends ConsumerWidget {
  const _PhotosSection({required this.recordId});

  final String recordId;

  static const _thumbSize = 76.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachments =
        ref.watch(recordAttachmentsProvider(recordId)).valueOrNull ??
            const <RecordAttachment>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          L.t('detail.photos'),
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: _thumbSize,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            clipBehavior: Clip.none,
            children: [
              for (final att in attachments)
                if (att.localPath != null)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpace.gapS),
                    child: GestureDetector(
                      onLongPress: () => _confirmDelete(context, ref, att),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.tile),
                        child: Image.file(
                          File(att.localPath!),
                          width: _thumbSize,
                          height: _thumbSize,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: _thumbSize,
                            height: _thumbSize,
                            color: AppColors.divider,
                            child: const Icon(Icons.broken_image_outlined,
                                size: 20, color: AppColors.textTertiary),
                          ),
                        ),
                      ),
                    ),
                  ),
              _AddPhotoTile(onTap: () => _pickAndSave(context, ref)),
            ],
          ),
        ),
        if (attachments.isEmpty) ...[
          const SizedBox(height: 4),
          Text(
            L.t('detail.photos.empty'),
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ],
    );
  }

  /// 选图来源：拍照 / 相册。选完立刻拷贝落库，失败给 snackbar。
  Future<void> _pickAndSave(BuildContext context, WidgetRef ref) async {
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

      await ref
          .read(attachmentRepositoryProvider)
          .addPhoto(recordId: recordId, sourcePath: picked.path);
      // 新附件时间晚于旧附件，顺序无关紧要；invalidate 让缩略图立刻出现。
      ref.invalidate(recordAttachmentsProvider(recordId));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    RecordAttachment att,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L.t('detail.photos.delete')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L.t('action.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(L.t('action.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(attachmentRepositoryProvider).softDelete(att.id);
    ref.invalidate(recordAttachmentsProvider(recordId));
  }
}

/// 缩略图列表末尾的「+」格。
class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: _PhotosSection._thumbSize,
        height: _PhotosSection._thumbSize,
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.35),
          ),
        ),
        child: const Icon(Icons.add_photo_alternate_outlined,
            size: 24, color: AppColors.primary),
      ),
    );
  }
}
