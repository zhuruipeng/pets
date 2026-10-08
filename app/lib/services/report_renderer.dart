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

import 'dart:io' show BytesBuilder, ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../core/units.dart';
import '../domain/pet_report.dart';

/// 成图宽度。1080 ≈ 三倍于常见手机宽度，微信里放大也清楚。
const double kReportWidth = 1080;

const double _pad = 56;

/// 画一张报告图，返回 PNG 字节。
///
/// ## 为什么必须分条渲染
///
/// `Picture.toImage` 有单张图的**像素总量**上限。Skia 在 iOS 上通常能分配到
/// 约 1600 万像素（约 4096×4096）就接近极限，超了直接抛异常。
/// 本报告宽 1080，所以总高超过约 **1480 像素**就可能失败。
///
/// 记了十几条记录 + 体重曲线 + 排期之后，长图到 3000-5000 像素很常见 ——
/// 于是「导出失败，请重试」。更糟的是它**不随记录条数给出任何提示**，
/// 用户只当功能坏了。
///
/// ## 做法
///
/// 把长图横向分成若干条，**每条独立录制一张 Picture**：
/// 用 `clipRect` 把画布裁到本条的纵向区间，再 `translate` 把内容整体上移，
/// 于是本条 Picture 里只有这一段内容，`toImage` 的像素量就落在上限内。
/// 最后把各条 PNG 在**字节层**拼成一张长图。
///
/// ⚠️ 不要试图「先画成一张长图再切条」—— `Picture` 不是 `Image`，
/// 没有 drawImageRect 可用，`toImage` 出来就已经超限了。裁剪必须发生在**录制时**。
Future<Uint8List> renderPetReportPng(
  PetReport report, {
  double width = kReportWidth,
}) async {
  final layout = _ReportLayout(report, width);
  layout.measure();
  final height = layout.height;
  final w = width.round();
  final h = height.ceil();

  // 略低于 iOS 实测上限，留出余量避免踩线。
  const kMaxImagePixels = 15000000;
  final stripHeight = (kMaxImagePixels / w).floor();

  if (h <= stripHeight) {
    // 短报告走单张路径，不付额外开销。
    return _paintStrip(layout, width, height, 0, height);
  }

  final strips = <Uint8List>[];
  for (var top = 0.0; top < height; top += stripHeight) {
    final thisH = math.min(stripHeight.toDouble(), height - top);
    strips.add(await _paintStrip(layout, width, height, top, thisH));
  }
  return _concatPng(strips);
}

/// 录制并渲染一条（纵向区间 [top] 起、高 [clipHeight]）。
///
/// 关键两步，顺序不能反：
/// 1. `clipRect`  把画布裁到本条区间 —— 之后画到区间外的内容不会被记录；
/// 2. `translate`  把区间起点平移到画布原点 —— 于是本条图像从 y=0 开始。
Future<Uint8List> _paintStrip(
  _ReportLayout layout,
  double width,
  double totalHeight,
  double top,
  double clipHeight,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  // 底色只铺本条范围，拼接后各条无缝相接。
  canvas.clipRect(Rect.fromLTWH(0, top, width, clipHeight));
  canvas.translate(0, -top);
  canvas.drawRect(
    Rect.fromLTWH(0, top, width, totalHeight),
    Paint()..color = AppColors.surface,
  );
  layout.paint(canvas);

  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width.round(), clipHeight.round());
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('报告渲染结果为空（toByteData 返回 null）');
      }
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// 把若干条**同宽、纵向相邻**的 PNG 拼成一张 PNG。
///
/// ## 为什么在字节层拼
///
/// 中转画布也不行 —— 画一张总高的中间图等于又撞一次同一个像素上限。
///
/// ## 怎么做
///
/// PNG 的 IDAT 里是一整条 zlib 流，逐行扫描线依次排列。所以把各条**解压**得到
/// 原始扫描线（每条自带 1 字节行首 filter 字节），首尾相接，再用**一个** deflate
/// 流重新压回去，就是一张合法的长图。
///
/// 像素一个都没重编码，不引任何第三方依赖，也不损失画质。
Uint8List _concatPng(List<Uint8List> strips) {
  if (strips.length == 1) return strips.first;

  final parsed = strips.map(_parsePngHeader).toList();
  final first = parsed.first;

  // 各条必须格式一致，否则拼出来的图是坏的 —— 宁可报错也不要静默出坏图。
  for (final p in parsed) {
    if (p.width != first.width) {
      throw StateError('报告分条宽度不一致（${p.width} ≠ ${first.width}）');
    }
    if (p.bitDepth != first.bitDepth || p.colorType != first.colorType) {
      throw StateError('报告分条的像素格式不一致，无法拼接');
    }
  }

  final raw = BytesBuilder();
  for (final p in parsed) {
    raw.add(ZLibCodec().decode(p.idat));
  }
  final totalHeight = parsed.fold<int>(0, (sum, p) => sum + p.height);

  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  // IHDR：宽不变，高改成总高。
  final ihdr = BytesBuilder()
    ..add(_be32(first.width))
    ..add(_be32(totalHeight))
    ..addByte(first.bitDepth)
    ..addByte(first.colorType)
    ..addByte(0) // compression
    ..addByte(0) // filter
    ..addByte(0); // interlace
  _writeChunk(out, 'IHDR', ihdr.toBytes());

  // IDAT：所有扫描线用单个 deflate 流重压。
  _writeChunk(out, 'IDAT', ZLibCodec(level: 6).encode(raw.toBytes()));
  _writeChunk(out, 'IEND', const <int>[]);
  return out.toBytes();
}

/// 从 PNG 字节里取出拼接需要的四样：宽、高、位深/颜色类型、IDAT 数据。
class _PngInfo {
  _PngInfo(this.width, this.height, this.bitDepth, this.colorType, this.idat);
  final int width;
  final int height;
  final int bitDepth;
  final int colorType;
  final Uint8List idat;
}

_PngInfo _parsePngHeader(Uint8List bytes) {
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < sig.length; i++) {
    if (bytes[i] != sig[i]) {
      throw StateError('不是合法的 PNG（签名不匹配）');
    }
  }
  final view = ByteData.sublistView(bytes);
  final idat = BytesBuilder();
  int? width, height, bitDepth, colorType;

  var pos = sig.length;
  while (pos + 8 <= bytes.length) {
    final len = view.getUint32(pos);
    final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
    final body = Uint8List.sublistView(bytes, pos + 8, pos + 8 + len);
    switch (type) {
      case 'IHDR':
        final bd = ByteData.sublistView(body);
        width = bd.getUint32(0);
        height = bd.getUint32(4);
        bitDepth = body[8];
        colorType = body[9];
      case 'IDAT':
        idat.add(body);
      case 'IEND':
        pos = bytes.length; // 跳出
        continue;
    }
    if (type == 'IEND') break;
    pos += 12 + len; // 8(长度+类型) + len + 4(CRC)
  }

  if (width == null || height == null || bitDepth == null || colorType == null) {
    throw StateError('PNG 缺少 IHDR');
  }
  return _PngInfo(width, height, bitDepth, colorType, idat.toBytes());
}

void _writeChunk(BytesBuilder out, String type, List<int> body) {
  out.add(_be32(body.length));
  final typeBytes = type.codeUnits;
  out.add(typeBytes);
  out.add(body);
  out.add(_be32(_crc32([...typeBytes, ...body])));
}

Uint8List _be32(int v) =>
    ByteData(4).buffer.asUint8List()..buffer.asByteData().setUint32(0, v, Endian.big);

final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
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
  //
  // 字号说明：成图宽 1080，微信里按屏宽缩放显示（约 0.45 倍），但**医生很可能
  // 打印出来、或者在电脑端打开**。原来 22px 的 _foot（脚注、次要信息）
  // 在手机上勉强能看，打印出来就糊了。
  // 医疗单据的信息可读性优先于紧凑，把 22/25/26 这三档各提 3-4px。
  // 层级关系不变（h1 > sub > section > value > label > foot），只是整体放大。

  static const _h1 = TextStyle(
    fontSize: 54,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.2,
  );
  static const _sub = TextStyle(
    fontSize: 30,
    color: AppColors.textSecondary,
    height: 1.3,
  );
  static const _section = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: AppColors.primary,
    height: 1.3,
  );
  static const _label = TextStyle(
    fontSize: 29,
    color: AppColors.textSecondary,
    height: 1.35,
  );
  static const _value = TextStyle(
    fontSize: 29,
    color: AppColors.textPrimary,
    height: 1.35,
  );
  static const _mono = TextStyle(
    fontSize: 28,
    color: AppColors.textPrimary,
    height: 1.4,
  );
  static const _foot = TextStyle(
    fontSize: 26,
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
  ///
  /// ⚠️ **这里必须换算单位，不能直接用 `p.kg`。**
  ///
  /// 踩过的坑：海外版报告右边的体重是 44.5 lb，而 Y 轴标注写的是
  /// `10.0 – 20.2`（那是公斤）。**同一张图两种单位混用**，兽医看到会直接
  /// 把数据读错 2.2 倍 —— 这比「没有图表」严重得多。
  /// 折线的**形状**当时是对的（按 kg 比例算的，相对关系不变），
  /// 所以一眼看过去「图是对的」，只有读数字才发现问题。
  ///
  /// 存储层永远是公制（kg），换算只在这一层做 —— 与 `units.dart` 的铁律一致。
  void _weightChart() {
    final pts = report.weightPoints;
    if (pts.isEmpty) return;

    const chartH = 190.0;
    final c = _canvas;
    final unit = report.weightUnit;
    // 先换算到展示单位，再取 min/max —— 顺序反了就会算出「轴用 kg、数用 lb」。
    final values = [
      for (final p in pts) Units.toDisplayWeight(p.kg, unit),
    ];
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final span = (maxV - minV) == 0 ? 1.0 : (maxV - minV);

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
      for (var i = 0; i < values.length; i++) {
        final x = values.length == 1
            ? _pad + contentWidth / 2
            : _pad + contentWidth * (i / (values.length - 1));
        final y = _y + chartH - 34 -
            (chartH - 68) * ((values[i] - minV) / span);
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

    // 最低 / 最高标注（画在图表下方，避免和线打架）。
    // 带上单位 —— 医生拿到这张图时，不知道 lb 还是 kg 会自己猜，猜错就完了。
    final sym = Units.weightSymbol(unit);
    final range = '${minV.toStringAsFixed(1)} – ${maxV.toStringAsFixed(1)} $sym';
    _text(range, _foot, gapAfter: 26);
  }

  void _disclaimer() {
    _y += 10;
    _text(L.t(report.footerKey), _foot);
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
      _sectionTitle(L.t(report.recordsSectionKey));
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
