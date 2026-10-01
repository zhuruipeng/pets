/// 把 [PetReport] 画成一张**彩色长图**（PNG）。
///
/// 为什么用手绘画布而不是截现有页面：
/// - 截屏只能截到**屏幕可见**的部分，报告比屏幕长得多；
/// - `RepaintBoundary` 也不是办法，它在 ScrollView 里同样只画可见区。
/// 用 `PictureRecorder` + `Canvas` 自己排一遍版，高度想要多少有多少。
///
/// 为什么不用 PDF：中文 PDF 必须内嵌字体（包体 +5MB 起），而长图直接用系统
/// 字体渲染，没有这个问题；分享到微信/WhatsApp 也是图片最顺手。
///
/// 两遍布局：先 `measure()` 量出总高，才知道画布要开多高；再 `paint()` 真画。
/// 两遍走的是同一份布局代码，canvas 为 null 时只推进 y 不落笔。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../domain/pet_report.dart';

/// 成图宽度。1080 ≈ 三倍于常见手机宽度，微信里放大也清楚。
const double kReportWidth = 1080;

const double _pad = 56;

/// 画一张报告图，返回 PNG 字节。
Future<Uint8List> renderPetReportPng(
  PetReport report, {
  double width = kReportWidth,
}) async {
  final layout = _ReportLayout(report, width);
  layout.measure();
  final height = layout.height;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // 底色在知道总高之后铺，一次到位（不在 paint 里猜一个大高度）。
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = AppColors.surface,
  );
  layout.paint(canvas);

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.round(), height.ceil());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

class _ReportLayout {
  _ReportLayout(this.report, this.width);

  final PetReport report;
  final double width;

  /// 当前绘制/测量的纵向位置。
  double _y = 0;

  double get contentWidth => width - _pad * 2;
  double get height => _y;

  // ---------------------------------------------------------------- 文字工具

  TextPainter _tp(String text, TextStyle style, {double? maxWidth}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? contentWidth);
    return tp;
  }

  /// 画（或只量）一行文字，返回占用的高度。
  double _text(
    String text,
    TextStyle style, {
    double x = _pad,
    double? maxWidth,
    double? gapAfter,
  }) {
    final tp = _tp(text, style, maxWidth: maxWidth);
    final c = _canvas;
    if (c != null) tp.paint(c, Offset(x, _y));
    final h = tp.height;
    _y += h + (gapAfter ?? 0);
    return h;
  }

  Canvas? _canvas;

  // ---------------------------------------------------------------- 各区块

  static const _h1 = TextStyle(
    fontSize: 52,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.2,
  );
  static const _sub = TextStyle(
    fontSize: 28,
    color: AppColors.textSecondary,
    height: 1.3,
  );
  static const _section = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    color: AppColors.primary,
    height: 1.3,
  );
  static const _label = TextStyle(
    fontSize: 26,
    color: AppColors.textSecondary,
    height: 1.35,
  );
  static const _value = TextStyle(
    fontSize: 26,
    color: AppColors.textPrimary,
    height: 1.35,
  );
  static const _mono = TextStyle(
    fontSize: 25,
    color: AppColors.textPrimary,
    height: 1.4,
  );
  static const _foot = TextStyle(
    fontSize: 22,
    color: AppColors.textTertiary,
    height: 1.5,
  );

  /// 顶部的品牌色带。
  void _header() {
    final c = _canvas;
    if (c != null) {
      final r = Rect.fromLTWH(0, 0, width, 12);
      c.drawRect(r, Paint()..color = AppColors.primary);
    }
    _y = 12 + 48;
  }

  void _title() {
    _text(report.petName, _h1, gapAfter: 10);
    if (report.subtitle.trim().isNotEmpty) {
      _text(report.subtitle, _sub, gapAfter: 6);
    }
    _text(
      '${L.t('report.generatedAt')} ${reportDate(report.generatedAt)}',
      _foot,
      gapAfter: 30,
    );
  }

  /// 区块标题 + 左侧一道短竖线，视觉上把几块内容分开。
  void _sectionTitle(String title) {
    final c = _canvas;
    final tp = _tp(title, _section);
    if (c != null) {
      final barTop = _y + 4;
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(_pad, barTop, 8, tp.height - 8),
          const Radius.circular(4),
        ),
        Paint()..color = AppColors.primary,
      );
      tp.paint(c, Offset(_pad + 22, _y));
    }
    _y += tp.height + 18;
  }

  /// 一条「上次 / 下次」的台账行。
  void _careRow(ReportCareRow row, {required bool first}) {
    if (!first) {
      final c = _canvas;
      if (c != null) {
        c.drawLine(
          Offset(_pad, _y + 6),
          Offset(width - _pad, _y + 6),
          Paint()
            ..color = AppColors.divider
            ..strokeWidth = 1.5,
        );
      }
      _y += 14;
    }
    // 复用页面上那套「上次 {v} / 下次 {v}」，不另起一套说法。
    final right =
        '${L.tp('profile.care.last', {'v': row.lastText})}    '
        '${L.tp('profile.care.next', {'v': row.nextText})}';
    final leftTp = _tp(row.label, _value, maxWidth: contentWidth * 0.3);
    final rightTp = _tp(right, _label, maxWidth: contentWidth * 0.68);

    final c = _canvas;
    if (c != null) {
      leftTp.paint(c, Offset(_pad, _y));
      rightTp.paint(c, Offset(width - _pad - rightTp.width, _y));
    }
    _y += math.max(leftTp.height, rightTp.height) + 14;
  }

  /// 一条记录。
  void _recordRow(ReportRecord r, {required bool first}) {
    if (!first) {
      final c = _canvas;
      if (c != null) {
        c.drawLine(
          Offset(_pad, _y + 6),
          Offset(width - _pad, _y + 6),
          Paint()
            ..color = AppColors.divider
            ..strokeWidth = 1.5,
        );
      }
      _y += 14;
    }

    final c = _canvas;
    final head = '${reportDate(r.when)}   ${r.typeLabel}';
    final headTp = _tp(head, _mono, maxWidth: contentWidth);
    if (c != null) headTp.paint(c, Offset(_pad, _y));
    _y += headTp.height + 6;

    // 数值 / 详情 / 备注各占一行，有才画。
    final extras = <String>[
      if (r.value != null) r.value!,
      if (r.detail != null) r.detail!,
      if (r.note != null) r.note!,
    ];
    for (final e in extras) {
      _text(e, _label, x: _pad + 18, gapAfter: 4);
    }
    _y += 10;
  }

  /// 体重趋势：画一条折线 + 最小/最大标注。
  void _weightChart() {
    final pts = report.weightPoints;
    if (pts.isEmpty) return;

    const chartH = 190.0;
    final c = _canvas;
    final minKg = pts.map((p) => p.kg).reduce(math.min);
    final maxKg = pts.map((p) => p.kg).reduce(math.max);
    final span = (maxKg - minKg) == 0 ? 1.0 : (maxKg - minKg);

    if (c != null) {
      // 背景
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(_pad, _y, contentWidth, chartH),
          const Radius.circular(16),
        ),
        Paint()..color = AppColors.pageBg,
      );

      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final x = pts.length == 1
            ? _pad + contentWidth / 2
            : _pad + contentWidth * (i / (pts.length - 1));
        final y = _y + chartH - 34 -
            (chartH - 68) * ((pts[i].kg - minKg) / span);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        c.drawCircle(Offset(x, y), 5, Paint()..color = AppColors.primary);
      }
      c.drawPath(
        path,
        Paint()
          ..color = AppColors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    _y += chartH + 8;

    // 最低 / 最高标注（画在图表下方，避免和线打架）
    final range = '${minKg.toStringAsFixed(1)} – ${maxKg.toStringAsFixed(1)}';
    _text(range, _foot, gapAfter: 26);
  }

  void _disclaimer() {
    _y += 10;
    _text(L.t('report.disclaimer'), _foot);
  }

  // ---------------------------------------------------------------- 入口

  void measure() {
    _canvas = null;
    _run();
  }

  void paint(Canvas canvas) {
    _canvas = canvas;
    _y = 0;
    _run();
  }

  void _run() {
    _header();
    _title();

    if (report.facts.isNotEmpty) {
      _sectionTitle(L.t('report.section.profile'));
      for (final f in report.facts) {
        final leftTp = _tp(f.label, _label, maxWidth: contentWidth * 0.38);
        final rightTp =
            _tp(f.value, _value, maxWidth: contentWidth * 0.58);
        final c = _canvas;
        if (c != null) {
          leftTp.paint(c, Offset(_pad, _y));
          rightTp.paint(c, Offset(width - _pad - rightTp.width, _y));
        }
        _y += math.max(leftTp.height, rightTp.height) + 12;
      }
      _y += 28;
    }

    final careRows = report.filledCareRows;
    if (careRows.isNotEmpty) {
      _sectionTitle(L.t('report.section.care'));
      for (var i = 0; i < careRows.length; i++) {
        _careRow(careRows[i], first: i == 0);
      }
      _y += 28;
    }

    if (report.weightPoints.isNotEmpty) {
      _sectionTitle(L.t('report.section.weight'));
      _weightChart();
      _y += 20;
    }

    if (report.records.isNotEmpty) {
      _sectionTitle(L.t('report.section.records'));
      for (var i = 0; i < report.records.length; i++) {
        _recordRow(report.records[i], first: i == 0);
      }
    }

    if (report.hasNothing) {
      _text(L.t('report.empty'), _label, gapAfter: 20);
    }

    _disclaimer();
    _y += 40;
  }
}
