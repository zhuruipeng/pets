/// 「问题反馈」页。
///
/// ## 设计前提
///
/// 用户遇到 bug 时**说不清技术细节**。让他回答「哪里坏了、什么现象、
/// 什么机型」会得到「用不了」这种无效答案 —— 这是所有反馈功能失效
/// 的根本原因：把描述的负担给了最没有能力描述的人。
///
/// 所以这个页做三件事：
/// 1. **把最近的崩溃记录直接列出来**，用户点一下就带上，不用描述；
/// 2. 附上**环境信息**（版本、系统、区域），这是复现的前提；
/// 3. 文字描述作为**补充**，可填可不填。
///
/// ## 为什么不上传到服务器自动提交
///
/// 见 `crash_log.dart` 的文件头：隐私政策明确承诺不做埋点，
/// 且海外用户访问境外服务不可控。用户主动复制给你，
/// 反而更符合「数据不出设备」这个承诺。
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/region.dart';
import '../core/theme.dart';
import '../data/sync/sync_api.dart';
import '../services/crash_log.dart';
import '../providers.dart';
import 'widgets.dart';

/// 打开反馈页。
Future<void> showFeedbackSheet(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const _FeedbackPage()),
  );
}

class _FeedbackPage extends ConsumerStatefulWidget {
  const _FeedbackPage();

  @override
  ConsumerState<_FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends ConsumerState<_FeedbackPage> {
  /// 勾选要一并带上的崩溃记录。默认全选 ——
  /// 用户要的是「帮我修」，帮他筛选日志不是他的义务。
  late Set<String> _selected;
  final _text = TextEditingController();

  bool _submitting = false;

  /// 提交中的错误。**不弹 SnackBar** ——
  /// 提交失败时用户最该看到的是「还没发出去」，而不是一个转瞬即逝的提示。
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _selected = {for (final e in CrashLog.instance.recent) e.at.toIso8601String()};
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// 拼一段可以直接发给开发者的文本。
  String _compose() {
    final log = CrashLog.instance;
    final picked = log.recent
        .where((e) => _selected.contains(e.at.toIso8601String()))
        .toList();

    final buf = StringBuffer()
      ..writeln(L.isZh ? '【问题反馈】' : '【Feedback】')
      ..writeln(L.isZh
          ? '描述：${_text.text.trim().isEmpty ? "（未填写）" : _text.text.trim()}'
          : 'Description: ${_text.text.trim().isEmpty ? "(none)" : _text.text.trim()}')
      ..writeln(L.isZh ? 'App 版本：${_appVersion()}' : 'App version: ${_appVersion()}')
      ..writeln('---');

    if (picked.isEmpty) {
      buf.writeln(L.isZh
          ? '（无崩溃记录。说明这次是功能异常，不是崩溃。）'
          : '(No crash records. So this is a functional issue, not a crash.)');
    } else {
      buf.writeln(L.isZh
          ? '崩溃记录（${picked.length} 条）：'
          : 'Crash records (${picked.length}):');
      for (final e in picked.reversed) {
        // 倒序输出：最早的在前，对方按时间线看更顺
        buf
          ..writeln('=====')
          ..writeln(e.toDisplayText());
      }
    }
    return buf.toString();
  }

  static String _appVersion() {
    final e = CrashLog.instance.recent;
    for (final x in e) {
      final v = x.context['appVersion'];
      if (v != null && v.isNotEmpty) return v;
    }
    return 'unknown';
  }

  @override
  Widget build(BuildContext context) {
    final log = CrashLog.instance;
    final entries = log.recent;

    return Scaffold(
      appBar: AppBar(title: Text(L.t('me.feedback'))),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.page),
        children: [
          // ---- 说明 ----
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(AppRadius.tile),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 18, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    L.t('feedback.hint'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.gapM),

          // ---- 崩溃记录 ----
          Row(
            children: [
              Text(
                L.t('feedback.logs'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (entries.isNotEmpty)
                TextButton(
                  onPressed: _clearAll,
                  child: Text(
                    L.t('feedback.clear'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.gapS),

          if (entries.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24),
              alignment: Alignment.center,
              child: Text(
                L.t('feedback.noLogs'),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textTertiary,
                ),
              ),
            )
          else
            ...entries.map((e) {
              final id = e.at.toIso8601String();
              return CheckboxListTile(
                value: _selected.contains(id),
                dense: true,
                contentPadding: EdgeInsets.zero,
                // 标题只显示首行消息 —— 堆栈动辄几十行，
                // 铺开会让这一屏全是栈，用户根本不想看。
                title: Text(
                  e.message.split('\n').first,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  '${e.kind} · ${e.at.toIso8601String().substring(0, 19)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textTertiary,
                  ),
                ),
                onChanged: (v) => setState(() {
                  if (v ?? false) {
                    _selected.add(id);
                  } else {
                    _selected.remove(id);
                  }
                }),
              );
            }),

          const SizedBox(height: AppSpace.gapM),
          const RowDivider(),
          const SizedBox(height: AppSpace.gapM),

          // ---- 补充描述 ----
          Text(
            L.t('feedback.describe'),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpace.gapS),
          TextField(
            controller: _text,
            maxLines: 4,
            maxLength: 500,
            decoration: InputDecoration(
              hintText: L.t('feedback.describeHint'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpace.gapS),

          // ---- 提交失败提示 ----
          if (_submitError != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerBg,
                borderRadius: BorderRadius.circular(AppRadius.tile),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline,
                      size: 18, color: AppColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _submitError!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.gapS),
          ],

          // ---- 提交 ----
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined, size: 18),
            label: Text(_submitting ? L.t('feedback.sending') : L.t('feedback.send')),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              backgroundColor: AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpace.gapS),

          // ---- 复制（保留为兜底）----
          // 为什么保留：提交要联网，可能在没网的地方失败。
          // 复制出来发微信不依赖网络，是那种「最原始但永远能用」的办法。
          OutlinedButton.icon(
            onPressed: _copy,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: Text(L.t('feedback.copy')),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// 提交反馈到服务端（服务端转发到开发者邮箱）。
  Future<void> _submit() async {
    final picked = _pickedEntries();
    final text = _text.text.trim();

    // 什么都没选也没写 → 没什么可提的。
    if (picked.isEmpty && text.isEmpty) {
      setState(() => _submitError = L.t('feedback.nothingToSend'));
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      await ref.read(syncApiProvider).submitFeedback(
            message: text.isEmpty
                ? L.t('feedback.autoSummary')
                : text,
            // 有崩溃记录时带上堆栈 —— 那才是真正能定位问题的信息，
            // 用户写的「用不了」帮不上忙。
            kind: picked.isEmpty ? 'manual' : picked.first.kind,
            appVersion: _appVersion(),
            region: AppRegion.current.name,
            platform: Platform.operatingSystem,
            stack: picked.isEmpty
                ? null
                : picked.map((e) => e.toDisplayText()).join('\n\n'),
          );
      if (!mounted) return;
      // 提交成功后**清掉已提交的崩溃记录** ——
      // 它们已经到邮箱了，继续留着只会让用户下次以为「上次还没发出去」。
      await CrashLog.instance.clear();
      if (!mounted) return;
      setState(() {
        _selected = {};
        _submitting = false;
        _text.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('feedback.sent'))),
      );
    } on SyncApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 401 说明没登录。海外区反馈接口不要求登录，
        // 若真出现多半是服务端问题，如实告诉用户「网络或服务问题」，
        // 别让他以为自己操作错了。
        _submitError = e.isUnauthorized
            ? L.t('feedback.sendFailedAuth')
            : L.t('feedback.sendFailed');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = L.t('feedback.sendFailed');
      });
    }
  }

  List<CrashEntry> _pickedEntries() {
    return CrashLog.instance.recent
        .where((e) => _selected.contains(e.at.toIso8601String()))
        .toList();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _compose()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('feedback.copied'))),
    );
  }

  Future<void> _clearAll() async {
    await CrashLog.instance.clear();
    if (!mounted) return;
    setState(() => _selected = {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L.t('feedback.cleared'))),
    );
  }
}
