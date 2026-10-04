/// 隐私政策 / 用户协议阅读页。
///
/// 文本以 Markdown 形式打进 assets 里（`assets/legal/`），这里做一个**极简渲染**：
/// 只认标题、列表、分隔线和普通段落。
///
/// 为什么不引 markdown 渲染包：正文里有表格和长段落，引包要连带调样式，
/// 而这段文本一年也就改一两次。**为它加一个依赖不划算**。
///
/// 为什么要把文本打进包里而不是打开网页：应用商店审核会检查「App 内能否
/// 打开隐私政策」，而且用户在地铁里没网时也该能看到自己签的是什么。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
// 文档打不开时的兜底：打开网页版。只用到两个符号，所以用 show 收窄。
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;

import '../core/l10n.dart';
import '../core/theme.dart';

enum LegalDoc { privacy, terms }

Future<void> showLegalPage(BuildContext context, LegalDoc doc) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => _LegalPage(doc: doc)),
  );
}

class _LegalPage extends StatelessWidget {
  const _LegalPage({required this.doc});

  final LegalDoc doc;

  /// 按当前语言选文本：中文区中文，海外区英文。
  ///
  /// 以前这里海外版也用中文，注释的理由是「英文译文未定稿前，打开空白页
  /// 比显示中文更糟」。现在 `privacy.en.md` / `terms.en.md` 已定稿，
  /// 那条理由不再成立 —— 继续给海外用户看中文，商店审核会判为
  /// 「未提供本地化隐私政策」而拒审。
  ///
  /// 落回中文的兜底：万一打包时漏了 .en 文件（资源被打进包是编译期的事，
  /// 漏了运行期才发现），至少还能显示中文而不是崩在空白页。
  String get _asset {
    final suffix = L.isZh ? 'zh' : 'en';
    return switch (doc) {
      LegalDoc.privacy => 'assets/legal/privacy.$suffix.md',
      LegalDoc.terms => 'assets/legal/terms.$suffix.md',
    };
  }

  /// 文档打不开时的兜底链接。
  ///
  /// **必须带 `?lang=en`**：不带的话海外用户点过去看到的是中文页，
  /// 跟他刚才在 App 里看的英文对不上，反而更困惑。
  String get _webFallback => switch (doc) {
        LegalDoc.privacy =>
          'https://api.pet.weiyuantool.com/legal/privacy${L.isZh ? '' : '?lang=en'}',
        LegalDoc.terms =>
          'https://api.pet.weiyuantool.com/legal/terms${L.isZh ? '' : '?lang=en'}',
      };

  String get _title => switch (doc) {
        LegalDoc.privacy => L.isZh ? '隐私政策' : 'Privacy Policy',
        LegalDoc.terms => L.isZh ? '用户协议' : 'Terms of Service',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(_asset),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      L.isZh ? '文档暂时打不开，请稍后重试。' : 'The document could not be opened.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 网址做成可点的：写「请到某某网站查看」而没有链接，
                    // 用户得自己抄进浏览器 —— 兜底提示的价值折半。
                    TextButton(
                      onPressed: () => _openWebFallback(context),
                      child: const Text('weiyuantool.com'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return _MarkdownLite(source: snapshot.data!);
        },
      ),
    );
  }

  /// 打开网页版的对应文档。
  ///
  /// 用 `launchUrl` 而不是让用户复制：兜底提示的价值就在于「一键看到」。
  /// 失败（没装 url_launcher 之外的东西 / 系统拒绝）时**静默**：
  /// 这已经在错误兜底路径上了，再弹一个错误只会套娃。
  Future<void> _openWebFallback(BuildContext context) async {
    final uri = Uri.tryParse(_webFallback);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 兜底路径里再报错只会让用户更困惑，静默即可。
    }
  }
}

/// 极简 Markdown 渲染：够读就行，不追求完整语法支持。
class _MarkdownLite extends StatelessWidget {
  const _MarkdownLite({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final buffer = StringBuffer();

    void flushParagraph() {
      final text = buffer.toString().trim();
      buffer.clear();
      if (text.isEmpty) return;
      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.gapM),
        child: Text(
          // 段内的软换行原样保留：隐私政策里大量用换行来表达层级。
          _stripInline(text),
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.75,
            color: AppColors.textPrimary,
          ),
        ),
      ));
    }

    for (final raw in source.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        flushParagraph();
        continue;
      }
      // 代码块围栏与引用符号在阅读页里没有意义，去掉即可。
      if (trimmed.startsWith('```') || trimmed.startsWith('---')) {
        flushParagraph();
        continue;
      }
      if (trimmed.startsWith('#')) {
        flushParagraph();
        final level = trimmed.split(' ').first.length;
        blocks.add(Padding(
          padding: EdgeInsets.only(
            top: level <= 1 ? AppSpace.gapL : AppSpace.gapM,
            bottom: AppSpace.gapS,
          ),
          child: Text(
            _stripInline(trimmed.replaceFirst(RegExp(r'^#+\s*'), '')),
            style: TextStyle(
              fontSize: level <= 1 ? 18 : (level == 2 ? 16 : 14.5),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ));
        continue;
      }
      // 表格：转成等宽的清单行，比丢掉好 —— 隐私政策里权限、数据存放
      // 这两张表是核心内容，不能因为「渲染麻烦」就不显示。
      if (trimmed.startsWith('|')) {
        flushParagraph();
        if (RegExp(r'^\|[\s\-:|]+\|$').hasMatch(trimmed)) continue; // 分隔行
        final cells = trimmed
            .split('|')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < cells.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpace.gapS),
                Expanded(
                  flex: i == 0 ? 3 : 4,
                  child: Text(
                    _stripInline(cells[i]),
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ));
        continue;
      }

      buffer.writeln(trimmed);
    }
    flushParagraph();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.gapM,
        AppSpace.page,
        AppSpace.gapXl * 2,
      ),
      children: blocks,
    );
  }

  /// 去掉行内的强调符号。应用内不做富文本，`**` 和 `` ` `` 只会变成噪音。
  static String _stripInline(String s) =>
      s.replaceAll('**', '').replaceAll('`', '').replaceAll('> ', '');
}
