/// 遛狗详情（M5）：轨迹地图 + 统计 + 心情备注 + 分享。
///
/// 地图的合规分叉（见 core/region.dart）：**中国区不渲染底图**，只画自绘轨迹
/// 折线 —— 境内展示地图底图涉及测绘资质。所以下面 `<intl>` 分支才有 TileLayer，
/// 中文区那块换成一块中性底 + 坐标文字。
/// 两个分支画的是**同一份坐标**，切换区域只影响底图，不影响轨迹本身。
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `hide Path`：latlong2 里也有个 `class Path<T extends LatLng>`（画线用的
// 路径容器），它和 dart:ui 的 `Path` 同名。不挡掉的话，下面 CustomPaint 里
// 的 `Path()` 会被解析成 latlong2 那个，`moveTo`/`lineTo` 全部找不到。
import 'package:latlong2/latlong.dart' hide Path;

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../data/models.dart';
import '../providers.dart';
import '../services/share_helper.dart';
import 'widgets.dart';

Future<void> showWalkDetailSheet(
  BuildContext context, {
  required WalkSession session,
  String? petName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _WalkDetailSheet(session: session, petName: petName),
  );
}

class _WalkDetailSheet extends ConsumerWidget {
  const _WalkDetailSheet({required this.session, this.petName});

  final WalkSession session;
  final String? petName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(walkPointsProvider(session.id));
    const region = AppRegion.current;
    final distUnit = Units.defaultDistanceUnit(region);

    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Column(
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
                    L.t('walk.detail'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: L.t('lost.share'),
                  onPressed: () => _share(context, distUnit),
                  icon: const Icon(Icons.ios_share_rounded, size: 19),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: points.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (pts) => ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  AppSpace.gapL,
                  AppSpace.page,
                  AppSpace.gapXl,
                ),
                children: [
                  _TrackMap(points: pts),
                  if (!region.mapRenderingEnabled) ...[
                    const SizedBox(height: AppSpace.gapS),
                    Text(
                      L.t('walk.noMapHint'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],

                  const SizedBox(height: AppSpace.gapL),
                  _Stats(session: session, unit: distUnit),

                  const SizedBox(height: AppSpace.gapL),
                  if ((session.mood ?? '').isNotEmpty)
                    _Row(
                      icon: Icons.mood_rounded,
                      label: L.t('walk.mood'),
                      value:
                          '${walkMoodEmoji(session.mood!)} ${L.t('walk.mood.${session.mood}')}',
                    ),
                  if ((session.note ?? '').isNotEmpty)
                    _Row(
                      icon: Icons.sticky_note_2_outlined,
                      label: L.t('detail.note'),
                      value: session.note!,
                    ),
                  _Row(
                    icon: Icons.route_outlined,
                    label: L.t('walk.track'),
                    value: pts.isEmpty
                        ? L.t('walk.noTrack')
                        : L.tp('walk.points', {'n': pts.length}),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _share(BuildContext context, DistanceUnit unit) async {
    final duration = durationLabel(session.durationS);
    await shareText(
      text: L.tp('walk.shareText', {
        'name': petName ?? '',
        'distance': Units.formatDistance(session.distanceM, unit),
        'duration': duration,
      }),
      context: context,
    );
  }
}

/// 轨迹地图。
///
/// 两个区域分支画的都是同一份 [points]：
/// - 海外（mapRenderingEnabled）：flutter_map + OSM 瓦片 + 折线 + 起终点标记
/// - 中国区：不拉瓦片，只在地图坐标空间里画折线（CustomPaint）
///
/// 为什么中国区还要画：轨迹形状本身是用户自己的数据，不涉及底图资质。
class _TrackMap extends StatelessWidget {
  const _TrackMap({required this.points});

  final List<WalkPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.cardBorder,
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          L.t('walk.noTrack'),
          style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
        ),
      );
    }

    final latLngs = [
      for (final p in points) LatLng(p.lat, p.lng),
    ];
    final center = _center(points);

    return ClipRRect(
      borderRadius: AppRadius.cardBorder,
      child: SizedBox(
        height: 240,
        child: AppRegion.current.mapRenderingEnabled
            ? FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  // 缩放写死 16：算「适配整条轨迹」的度数很绕，
                  // 而用户看轨迹时放大一点反而更清楚。
                  initialZoom: 16,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.weiyuantool.pet',
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: latLngs,
                        strokeWidth: 4,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: latLngs.first,
                        width: 22,
                        height: 22,
                        child: const _Dot(color: AppColors.success),
                      ),
                      Marker(
                        point: latLngs.last,
                        width: 22,
                        height: 22,
                        child: const _Dot(color: AppColors.danger),
                      ),
                    ],
                  ),
                ],
              )
            : _PlainTrack(points: points),
      ),
    );
  }

  /// 轨迹中心：取首尾的中点。比算包围盒简单，视觉上也够用 ——
  /// 遛狗轨迹不会是 L 形绕半个城市。
  static LatLng _center(List<WalkPoint> pts) => LatLng(
        (pts.first.lat + pts.last.lat) / 2,
        (pts.first.lng + pts.last.lng) / 2,
      );
}

/// 中国区用的无底图轨迹图。把经纬度线性映射到画布，保持长宽比。
class _PlainTrack extends StatelessWidget {
  const _PlainTrack({required this.points});

  final List<WalkPoint> points;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.primaryLight,
      child: CustomPaint(
        painter: _TrackPainter(points: points),
        size: Size.infinite,
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({required this.points});

  final List<WalkPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    var minLat = points.first.lat, maxLat = points.first.lat;
    var minLng = points.first.lng, maxLng = points.first.lng;
    for (final p in points) {
      minLat = p.lat < minLat ? p.lat : minLat;
      maxLat = p.lat > maxLat ? p.lat : maxLat;
      minLng = p.lng < minLng ? p.lng : minLng;
      maxLng = p.lng > maxLng ? p.lng : maxLng;
    }

    final spanLat = (maxLat - minLat).abs();
    final spanLng = (maxLng - minLng).abs();
    // 起终点重合（原地打转）时给一个极小跨度，避免除零把线画到无穷远。
    final safeLat = spanLat < 1e-6 ? 1e-6 : spanLat;
    final safeLng = spanLng < 1e-6 ? 1e-6 : spanLng;

    const pad = 24.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    // 等比缩放，否则轨迹会被拉成横长条，形状就失真了。
    final scale = (w / safeLng) < (h / safeLat) ? (w / safeLng) : (h / safeLat);
    final dx = (w - safeLng * scale) / 2 + pad;
    final dy = (h - safeLat * scale) / 2 + pad;

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = dx + (points[i].lng - minLng) * scale;
      // 纬度往上增大，屏幕 y 往下增大，所以取反。
      final y = dy + (maxLat - points[i].lat) * scale;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    void dot(Offset o, Color c) => canvas.drawCircle(o, 5, Paint()..color = c);
    dot(
      Offset(dx + (points.first.lng - minLng) * scale,
          dy + (maxLat - points.first.lat) * scale),
      AppColors.success,
    );
    dot(
      Offset(dx + (points.last.lng - minLng) * scale,
          dy + (maxLat - points.last.lat) * scale),
      AppColors.danger,
    );
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) => old.points != points;
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
        ),
      );
}

class _Stats extends StatelessWidget {
  const _Stats({required this.session, required this.unit});

  final WalkSession session;
  final DistanceUnit unit;

  @override
  Widget build(BuildContext context) {
    final (h, m) = Units.splitDuration(session.durationS);
    final dur = h > 0 ? '${h}h ${m}m' : '${m}m';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.gapL),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _StatCell(
              label: L.t('walk.distance'),
              value: Units.formatDistance(session.distanceM, unit),
            ),
          ),
          const SizedBox(
            height: 32,
            child: VerticalDivider(width: 1, color: AppColors.divider),
          ),
          Expanded(
            child: _StatCell(label: L.t('walk.duration'), value: dur),
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.gapM),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 17, color: AppColors.textTertiary),
            const SizedBox(width: AppSpace.gapM),
            Text(
              '$label：',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textPrimary,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );
}
