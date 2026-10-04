/// 法律文本资产测试。
///
/// 存在的原因：英文版 `privacy.en.md` / `terms.en.md` 是**上架硬要求**
/// （商店审核会检查「App 内能否打开隐私政策」，海外版还要求与网页版一致）。
/// 而「文件存在」这件事**编译期不校验** —— assets 声明成通配目录，
/// 少一个文件照样能构建成功，只是运行期打开隐私政策时白屏。
///
/// 这类问题在提交审核前是发现不了的：包能出、能装、点开才炸。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 用项目内的相对路径，不依赖 flutter_test 的包根目录解析。
  final legalDir = Directory('assets/legal');

  group('法律文本资产', () {
    test('四个文件都在（中英 × 隐私/协议）', () {
      expect(legalDir.existsSync(), isTrue, reason: '缺少 assets/legal 目录');
      for (final f in const [
        'privacy.zh.md',
        'privacy.en.md',
        'terms.zh.md',
        'terms.en.md',
      ]) {
        expect(
          File('${legalDir.path}/$f').existsSync(),
          isTrue,
          reason: '缺少 $f —— 缺了编译照过，运行期打开该页才白屏',
        );
      }
    });

    test('pubspec 声明了 legal 资源目录', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('assets/legal/'), isTrue);
    });
  });

  group('中英文本内容一致性', () {
    /// 取 Markdown 的章节标题（`#` / `##` 开头行）。
    List<String> sections(String text) => text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('#'))
        .map((l) => l.replaceAll(RegExp(r'^#+\s*'), '').trim())
        .toList();

    late String zhPrivacy, enPrivacy, zhTerms, enTerms;

    setUpAll(() {
      zhPrivacy = File('${legalDir.path}/privacy.zh.md').readAsStringSync();
      enPrivacy = File('${legalDir.path}/privacy.en.md').readAsStringSync();
      zhTerms = File('${legalDir.path}/terms.zh.md').readAsStringSync();
      enTerms = File('${legalDir.path}/terms.en.md').readAsStringSync();
    });

    test('隐私政策章节数一致', () {
      // 少一节 = 有内容没翻。商店审核会认为政策不完整。
      expect(
        sections(enPrivacy).length,
        sections(zhPrivacy).length,
        reason: '隐私政策英文版章节数与中文版不符：\n'
            '  中：${sections(zhPrivacy)}\n  英：${sections(enPrivacy)}',
      );
    });

    test('用户协议章节数一致', () {
      expect(
        sections(enTerms).length,
        sections(zhTerms).length,
        reason: '用户协议英文版章节数与中文版不符：\n'
            '  中：${sections(zhTerms)}\n  英：${sections(enTerms)}',
      );
    });

    test('隐私政策关键承诺在英文版里也在', () {
      // 这几条是 App 的实际设计（本地优先、不上传照片、双区域隔离、
      // 不接广告 SDK），也是最容易在翻译时被"顺手删掉"的。
      // 少一条就等于对海外用户做了不同的承诺。
      for (final phrase in const [
        'never uploaded',
        'on your phone',
        'no cross-border',
        'advertising SDK',
      ]) {
        expect(
          enPrivacy.toLowerCase().contains(phrase.toLowerCase()),
          isTrue,
          reason: '英文隐私政策缺少关键承诺：$phrase',
        );
      }
    });

    test('两份英文文本都没有残留中文（标题/正文）', () {
      // 漏翻的地方最直观的症状就是中文残留，海外用户一眼看出来。
      final cjk = RegExp(r'[\u4e00-\u9fff]');
      expect(cjk.hasMatch(enPrivacy), isFalse,
          reason: 'privacy.en.md 里有中文残留');
      expect(cjk.hasMatch(enTerms), isFalse,
          reason: 'terms.en.md 里有中文残留');
    });

    test('英文政策含 App 商店要求的必备要素', () {
      // 审核清单：运营方、联系方式、联系方式生效期、数据收集说明、
      // 权限用途、第三方服务。缺哪项都可能被拒或被要求补材料。
      for (final phrase in const [
        'Linyi Weiyuan Tools',      // 运营方
        'zhuruipeng@weiyuantool.com', // 联系邮箱
        '15 working days',          // 响应时限
        'Camera',                   // 权限说明
        'GDPR',                     // 海外合规提及
      ]) {
        expect(
          enPrivacy.contains(phrase),
          isTrue,
          reason: '英文隐私政策缺少 App 商店要求的要素：$phrase',
        );
      }
    });
  });
}
