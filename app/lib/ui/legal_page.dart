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

  /// 中文区用中文文本；海外版暂时也用它（英文译文未定稿前，
  /// 打开一个空白页比显示中文更糟 —— 商店审核会当成「未提供」）。
  String get _asset => switch (doc) {
        LegalDoc.privacy => 'assets/legal/privacy.zh.md',
        LegalDoc.terms => 'assets/legal/terms.zh.md',
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
                child: Text(
                  L.isZh
                      ? '文档暂时打不开，请稍后重试。\n也可以到 weiyuantool.com 查看。'
                      : 'Document unavailable. Please try again later.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.7,
                    color: AppColors.textSecondary,
                  ),
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
