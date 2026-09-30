/// 走失协查卡片（M5）。
///
/// 一张能被转发的图片：宠物照片 + 关键特征 + 走失时间地点 + 联系方式。
/// 做成图片而不是纯文字，是因为它要被转到微信群、朋友圈、小区群 ——
/// 那些地方图片的触达率远高于一段文字。
///
/// 实现方式：把卡片渲染在 [RepaintBoundary] 里，`toImage` 截图，
/// 落成临时 PNG 再交给 share_plus。**不需要服务端参与**，也不需要
/// 任何图片生成服务 —— 卡片长什么样就是屏幕上看到的样子。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/traits.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../providers.dart';
import 'widgets.dart';

Future<void> showLostCardSheet(BuildContext context, Pet pet) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _LostCardSheet(pet: pet),
  );
}

class _LostCardSheet extends ConsumerStatefulWidget {
  const _LostCardSheet({required this.pet});

  final Pet pet;

  @override
  ConsumerState<_LostCardSheet> createState() => _LostCardSheetState();
}

class _LostCardSheetState extends ConsumerState<_LostCardSheet> {
  final GlobalKey _cardKey = GlobalKey();

  late final TextEditingController _where;
  late DateTime _lostAt;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _where = TextEditingController();
    _lostAt = DateTime.now();
  }

  @override
  void dispose() {
    _where.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pet = widget.pet;
    final user = ref.watch(currentUserProvider).valueOrNull;
    final series = ref.watch(weightSeriesProvider(pet.id)).valueOrNull;
    final latestWeight = (series == null || series.isEmpty) ? null : series.last.kg;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.t('lost.title'),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _sharing ? null : _share,
                    icon: const Icon(Icons.ios_share_rounded, size: 17),
                    label: Text(L.t('lost.share')),
                  ),
                ],
              ),
            ),

            // ---- 卡片本体。截图截的就是这块。 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                AppSpace.gapS,
                AppSpace.page,
                AppSpace.gapL,
              ),
              child: RepaintBoundary(
                key: _cardKey,
                child: _LostCard(
                  pet: pet,
                  lostAt: _lostAt,
                  where: _where.text.trim().isEmpty
                      ? L.t('lost.unknownWhere')
                      : _where.text.trim(),
                  weightLabel: latestWeight == null
                      ? null
                      : Units.formatWeight(
                          latestWeight,
                          Units.defaultWeightUnit(AppRegion.current, AppRegion.current.name),
                        ),
                  user: user,
                ),
              ),
            ),

            // ---- 可填的两项。默认值就是能用的，不强迫用户填。 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                0,
                AppSpace.page,
                AppSpace.gapXl,
              ),
              child: Column(
                children: [
                  InkWell(
                    onTap: _pickDate,
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
                              '${L.t('lost.since').replaceAll('{n}', '${_daysSinceLost()}')}'
                              ' · ${_lostAt.year}-${_p(_lostAt.month)}-${_p(_lostAt.day)}',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded,
                              size: 18, color: AppColors.textTertiary),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.gapM),
                  TextField(
                    controller: _where,
                    decoration: InputDecoration(
                      labelText: L.t('lost.lastSeen'),
                      hintText: L.isZh
                          ? '如：临沂市兰山区某小区'
                          : 'e.g. near the park on 5th street',
                      prefixIcon: const Icon(Icons.place_outlined, size: 18),
                    ),
                    // 输入即刷新预览 —— 截图截的是屏幕上那块，不刷新的话
                    // 用户会分享出一张没带上新地点的旧图。
                    onChanged: (_) => setState(() {}),
                  ),
                  if (user != null && !user.hasContact) ...[
                    const SizedBox(height: AppSpace.gapM),
                    Row(
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: AppSpace.gapS),
                        Expanded(
                          child: Text(
                            L.t('contact.missing'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                      ],
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

  int _daysSinceLost() {
    final now = DateTime.now();
    final a = DateTime(now.year, now.month, now.day);
    final b = DateTime(_lostAt.year, _lostAt.month, _lostAt.day);
    final d = a.difference(b).inDays;
    return d < 0 ? 0 : d;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _lostAt,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      helpText: L.t('lost.lastSeen'),
    );
    if (picked != null) setState(() => _lostAt = picked);
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final boundary = _cardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('卡片还没渲染出来');

      // pixelRatio 3 是为了转发到手机上看清楚字：截图是给人在聊天窗口里
      // 放大看电话号码用的，按屏幕密度截会糊。
      final image = await boundary.toImage(pixelRatio: 3.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('截图失败');
      image.dispose();

      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'lost_${widget.pet.id}.png'));
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        subject: L.tp('lost.shareSubject', {'name': widget.pet.name}),
      );
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(L.t('lost.failed'))));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  static String _p(int v) => v.toString().padLeft(2, '0');
}

/// 卡片本体。**尺寸固定**（屏幕宽 - 页边距），因为它要被截图 ——
/// 让它随内容伸缩会导致不同宠物截出来的长宽比不一致，转发出去很难看。
class _LostCard extends StatelessWidget {
  const _LostCard({
    required this.pet,
    required this.lostAt,
    required this.where,
    required this.user,
    this.weightLabel,
  });

  final Pet pet;
  final DateTime lostAt;
  final String where;
  final LocalUser? user;
  final String? weightLabel;

  @override
  Widget build(BuildContext context) {
    final traits = pet.personality;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部警示条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.gapL,
              vertical: 10,
            ),
            color: AppColors.danger,
            child: Row(
              children: [
                const Icon(Icons.priority_high_rounded,
                    size: 18, color: Colors.white),
                const SizedBox(width: AppSpace.gapS),
                Text(
                  L.t('lost.title'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                Text(
                  L.tp('lost.since', {'n': _daysSince(lostAt)}),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(AppSpace.gapL),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PetAvatar(pet: pet, size: 92),
                    const SizedBox(width: AppSpace.gapL),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pet.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _breedLine(pet),
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: AppSpace.gapS),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (weightLabel != null)
                                _Chip(weightLabel!),
                              if ((pet.color ?? '').trim().isNotEmpty)
                                _Chip(pet.color!.trim()),
                              for (final t in traits.take(3))
                                _Chip(personalityLabel(t)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // 明显特征：只有用户自己写了才有。没写就不占位 ——
                // 一张空着「特征：」的卡片反而显得没准备。
                if ((pet.note ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpace.gapM),
                  _Line(
                    icon: Icons.star_outline_rounded,
                    label: L.isZh ? '明显特征' : 'Distinctive',
                    value: pet.note!.trim(),
                  ),
                ],

                const SizedBox(height: AppSpace.gapS),
                _Line(
                  icon: Icons.place_outlined,
                  label: L.t('lost.lastSeen'),
                  value: where,
                ),

                const SizedBox(height: AppSpace.gapM),
                Container(height: 1, color: AppColors.divider),
                const SizedBox(height: AppSpace.gapM),

                Text(
                  L.t('lost.contactMe'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 4),
                if (user == null || !user!.hasContact)
                  Text(
                    L.t('lost.noContact'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.danger,
                    ),
                  )
                else
                  Text(
                    _contactLine(user!),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static int _daysSince(DateTime d) {
    final now = DateTime.now();
    final a = DateTime(now.year, now.month, now.day);
    final b = DateTime(d.year, d.month, d.day);
    final n = a.difference(b).inDays;
    return n < 0 ? 0 : n;
  }

  static String _breedLine(Pet pet) {
    final months = pet.ageInMonths;
    final age = months == null
        ? null
        : (months < 12 ? '${months}mo' : '${months ~/ 12}y');
    return [
      if ((pet.breed ?? '').trim().isNotEmpty) pet.breed!.trim(),
      if (age != null) age,
      if ((pet.gender ?? '').isNotEmpty && pet.gender != 'unknown')
        pet.gender == 'male'
            ? (L.isZh ? '公' : 'Male')
            : (L.isZh ? '母' : 'Female'),
    ].join(' · ');
  }

  static String _contactLine(LocalUser u) => [
        if ((u.phone ?? '').trim().isNotEmpty) '${L.t('contact.phone')}：${u.phone!.trim()}',
        if ((u.wechat ?? '').trim().isNotEmpty) '${L.t('contact.wechat')}：${u.wechat!.trim()}',
        if ((u.email ?? '').trim().isNotEmpty) '${L.t('contact.email')}：${u.email!.trim()}',
        if ((u.contactNote ?? '').trim().isNotEmpty) u.contactNote!.trim(),
      ].join('\n');
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 11.5, color: AppColors.primary),
        ),
      );
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: AppColors.textTertiary),
            const SizedBox(width: 6),
            Text(
              '$label：',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textTertiary,
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );
}
