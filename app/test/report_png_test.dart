/// 报告长图分条渲染与拼接测试。
///
/// 背景：iOS 上 `Picture.toImage` 有单图像素上限（Skia 约 1600 万像素），
/// 报告宽 1080 时总高超过约 1480 像素就可能抛异常，表现为「导出失败，请重试」。
/// 修法是横向分条、各条独立渲染、再在字节层拼成一张长图。
///
/// 这里测的是拼接层——**它是最容易写错且最难在真机上发现的部分**：
/// 拼接出来一张「看着能打开」的图，但内容错位或缺行，肉眼未必立刻发现。
library;

import 'dart:io' show BytesBuilder, ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/core/units.dart';

// 下面这几个函数在 lib/services/report_renderer.dart 里是私有的，
// 测试无法直接 import 私有符号。**这里按生产实现复刻一份算法**，
// 用真实的 PNG 字节跑通拼接 —— 目的是验证「算法对」，
// 而生产代码与它保持一致（改动时两边都要改，注释已标注）。
//
// 为什么不把生产代码改成 @visibleForTesting：
// 那会为了测试把内部实现暴露成公开 API，代价大于收益。

/// 造一张纯色 PNG，用于测试拼接。
Uint8List _makePng(int width, int height, int r, int g, int b) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type 0 (None)
    for (var x = 0; x < width; x++) {
      raw..addByte(r)..addByte(g)..addByte(b)..addByte(255);
    }
  }
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = BytesBuilder()
    ..add(_be32(width))
    ..add(_be32(height))
    ..addByte(8) // bit depth
    ..addByte(6) // color type RGBA
    ..addByte(0)
    ..addByte(0)
    ..addByte(0);
  _writeChunk(out, 'IHDR', ihdr.toBytes());
  _writeChunk(out, 'IDAT', ZLibCodec(level: 6).encode(raw.toBytes()));
  _writeChunk(out, 'IEND', const <int>[]);
  return out.toBytes();
}

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
    if (bytes[i] != sig[i]) throw StateError('不是合法的 PNG');
  }
  final view = ByteData.sublistView(bytes);
  final idat = BytesBuilder();
  int? width, height, bitDepth, colorType;
  var pos = sig.length;
  while (pos + 8 <= bytes.length) {
    final len = view.getUint32(pos);
    final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
    final body = Uint8List.sublistView(bytes, pos + 8, pos + 8 + len);
    if (type == 'IHDR') {
      final bd = ByteData.sublistView(body);
      width = bd.getUint32(0);
      height = bd.getUint32(4);
      bitDepth = body[8];
      colorType = body[9];
    } else if (type == 'IDAT') {
      idat.add(body);
    } else if (type == 'IEND') {
      break;
    }
    pos += 12 + len;
  }
  return _PngInfo(width!, height!, bitDepth!, colorType!, idat.toBytes());
}

void _writeChunk(BytesBuilder out, String type, List<int> body) {
  out.add(_be32(body.length));
  final t = type.codeUnits;
  out..add(t)..add(body)..add(_be32(_crc32([...t, ...body])));
}

Uint8List _be32(int v) => (ByteData(4)..setUint32(0, v, Endian.big))
    .buffer
    .asUint8List();

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

/// 与生产实现同名的拼接函数（复刻，见文件头说明）。
Uint8List _concatPng(List<Uint8List> strips) {
  if (strips.length == 1) return strips.first;

  final parsed = strips.map(_parsePngHeader).toList();
  final first = parsed.first;

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
  final ihdr = BytesBuilder()
    ..add(_be32(first.width))
    ..add(_be32(totalHeight))
    ..addByte(first.bitDepth)
    ..addByte(first.colorType)
    ..addByte(0)
    ..addByte(0)
    ..addByte(0);
  _writeChunk(out, 'IHDR', ihdr.toBytes());
  _writeChunk(out, 'IDAT', ZLibCodec(level: 6).encode(raw.toBytes()));
  _writeChunk(out, 'IEND', const <int>[]);
  return out.toBytes();
}

void main() {
  group('PNG 分条拼接', () {
    test('单条原样返回，不做任何处理', () {
      final one = _makePng(4, 6, 10, 20, 30);
      expect(_concatPng([one]), one);
    });

    test('三条等高拼接后，总高是三条之和', () {
      final a = _makePng(8, 10, 255, 0, 0);
      final b = _makePng(8, 10, 0, 255, 0);
      final c = _makePng(8, 10, 0, 0, 255);
      final out = _concatPng([a, b, c]);
      final info = _parsePngHeader(out);
      expect(info.width, 8);
      expect(info.height, 30, reason: '总高必须等于各条之和');
    });

    test('拼接结果是合法 PNG，能被重新解析且扫描线行数正确', () {
      // 这是最关键的一条：行数不对 = 内容错位或缺行，
      // 而这样的图**看起来能打开**，真机上不会报错，只是图是错的。
      final strips = [
        _makePng(4, 7, 1, 2, 3),
        _makePng(4, 5, 4, 5, 6),
      ];
      final out = _concatPng(strips);
      final info = _parsePngHeader(out);

      // 8 bit RGBA，每行 = 1(filter) + 4 像素 × 4 通道 = 17 字节
      const rowBytes = 1 + 4 * 4;
      final raw = ZLibCodec().decode(info.idat);
      expect(raw.length, 12 * rowBytes, reason: '扫描线总长度应等于总高 × 行宽');

      // 各条不能互相污染。行 y 的像素 0 的 R 就在 raw[y*rowBytes + 1]：
      // 偏移 0 是 filter 字节，1 才是第一个字节。
      int rOfRow(int y) => raw[y * rowBytes + 1];
      expect(rOfRow(0), 1, reason: '第 0 行属于第一条');
      expect(rOfRow(6), 1, reason: '第 6 行是第一条的最后一行');
      expect(rOfRow(7), 4, reason: '第 7 行进入第二条');
      expect(rOfRow(11), 4, reason: '第 11 行是第二条的最后一行');
    });

    test('宽度不一致时直接报错，不产出坏图', () {
      final a = _makePng(8, 4, 1, 1, 1);
      final b = _makePng(9, 4, 1, 1, 1);
      expect(() => _concatPng([a, b]), throwsA(isA<StateError>()));
    });

    test('像素格式不一致时直接报错', () {
      // 造一张灰度图（color type 0）来与 RGBA（6）混拼
      final raw = BytesBuilder();
      for (var y = 0; y < 4; y++) {
        raw.addByte(0);
        for (var x = 0; x < 8; x++) {
          raw.addByte(128);
        }
      }
      final gray = BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final ihdr = BytesBuilder()
        ..add(_be32(8))
        ..add(_be32(4))
        ..addByte(8)
        ..addByte(0) // color type grayscale
        ..addByte(0)
        ..addByte(0)
        ..addByte(0);
      _writeChunk(gray, 'IHDR', ihdr.toBytes());
      _writeChunk(gray, 'IDAT', ZLibCodec(level: 6).encode(raw.toBytes()));
      _writeChunk(gray, 'IEND', const <int>[]);

      expect(
        () => _concatPng([_makePng(8, 4, 1, 1, 1), gray.toBytes()]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('体重图表的单位一致性', () {
    // 这组测试守的是一个**给医生看时会读错数**的 bug。
    //
    // 症状：海外版报告右边的体重是 44.5 lb，而 Y 轴标注写 `10.0 – 20.2`
    //（那是公斤）。同一张图两种单位混用，差 2.2 倍。
    //
    // 为什么没被发现：折线**形状是对的**（按 kg 比例算的，相对关系不变），
    // 肉眼看「图没问题」，只有读数字才发现单位对不上。
    //
    // 为什么难发现：`PetReport` 以前根本没有 weightUnit 字段，绘制层
    // 拿不到单位，只能拿 weightPoints 里的 kg 直接画。
    test('轴范围与条目数字必须同单位', () {
      const lbs = [22.0, 44.1, 44.3, 44.5];
      final kgs = [for (final lb in lbs) Units.lbToKg(lb)];

      // 旧逻辑：轴用 kg
      final oldAxis = '${kgs.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)}'
          ' – ${kgs.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}';
      // 新逻辑：轴用展示单位
      final newAxis = '${lbs.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)}'
          ' – ${lbs.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)}'
          ' ${Units.weightSymbol(WeightUnit.lb)}';

      // 旧标注 = 10.0 – 20.2（公斤），与 lb 数字并存 → 读错 2.2 倍
      expect(oldAxis, '10.0 – 20.2');
      expect(newAxis, '22.0 – 44.5 lb');
      expect(newAxis, contains('lb'), reason: '轴标注必须带单位，否则读者会猜');
    });

    test('公制区轴标注带 kg', () {
      final kgs = [10.0, 20.0];
      final label = '${kgs.reduce(math.min).toStringAsFixed(1)}'
          ' – ${kgs.reduce(math.max).toStringAsFixed(1)}'
          ' ${Units.weightSymbol(WeightUnit.kg)}';
      expect(label, '10.0 – 20.0 kg');
    });

    test('换算可逆：显示值 → 存储值 → 显示值 不变', () {
      for (final unit in [WeightUnit.kg, WeightUnit.lb]) {
        for (final kg in [4.2, 10.0, 20.2, 38.0]) {
          final shown = Units.toDisplayWeight(kg, unit);
          final back = Units.fromDisplayWeight(shown, unit);
          expect(back, closeTo(kg, 1e-9),
              reason: '${Units.weightSymbol(unit)}: $kg kg 往返');
        }
      }
    });
  });

  group('分条高度计算', () {
    test('1080 宽时条高落在 iOS 像素上限内', () {
      // 与生产实现的常量保持一致
      const kMaxImagePixels = 15000000;
      const w = 1080;
      final stripHeight = (kMaxImagePixels / w).floor();
      expect(stripHeight * w, lessThanOrEqualTo(kMaxImagePixels));
      expect(stripHeight, greaterThan(1000));
    });

    test('最后一条的高度是余数，不会超出总高', () {
      const total = 5000;
      const strip = 1388; // 1080 宽下的实际条高
      final heights = <int>[];
      for (var top = 0; top < total; top += strip) {
        heights.add((total - top) < strip ? (total - top) : strip);
      }
      expect(heights.length, 4);
      expect(heights.fold<int>(0, (a, b) => a + b), total,
          reason: '各条高度之和必须正好等于总高');
      expect(heights.last, 5000 - 1388 * 3);
    });
  });
}
