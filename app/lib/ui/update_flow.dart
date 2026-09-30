/// 自动更新的界面流程。
///
/// 一个入口函数 [runUpdateCheck] 管两种场景：
/// - `interactive: false`（启动时静默检查）：只有当真的有新版才弹框，
///   检查失败/已是最新**什么都不做** —— 启动路径上不能有任何打扰。
/// - `interactive: true`（「我的」页手动点）：无论结果如何都给一句反馈，
///   用户主动问了就得知答案。
///
/// 强制更新（本机 build < 清单 minBuild）没有「稍后」，只能更新或退出应用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/l10n.dart';
import '../core/theme.dart';
import '../providers.dart';
import '../services/app_update_service.dart';

/// 检查并处理更新。
Future<void> runUpdateCheck(
  BuildContext context, {
  required bool interactive,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final service = container.read(appUpdateServiceProvider);

  final info = await PackageInfo.fromPlatform();
  final currentBuild = int.tryParse(info.buildNumber) ?? 0;

  final outcome = await service.check(
    currentBuild: currentBuild,
    currentVersion: info.version,
  );
  if (!context.mounted) return;

  switch (outcome.status) {
    case UpdateCheckStatus.hasUpdate:
      await _showUpdateDialog(
        context,
        result: outcome.result!,
        service: service,
        currentVersion: '${info.version}+$currentBuild',
      );
    case UpdateCheckStatus.upToDate:
      if (interactive) _toast(context, L.t('update.upToDate'));
    case UpdateCheckStatus.unsupported:
      if (interactive) _toast(context, L.t('update.noApk'));
    case UpdateCheckStatus.failed:
      // 静默检查失败不打扰用户；手动检查要说一句，否则像是点了没反应。
      if (interactive) _toast(context, L.t('update.checkFailed'));
  }
}

Future<void> _showUpdateDialog(
  BuildContext context, {
  required UpdateCheckResult result,
  required AppUpdateService service,
  required String currentVersion,
}) async {
  final manifest = result.manifest;

  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: !result.forced,
    builder: (ctx) => PopScope(
      // 强制更新时屏蔽返回键，否则用户可以绕过。
      canPop: !result.forced,
      child: AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        title: Text(L.t(result.forced ? 'update.mustTitle' : 'update.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.forced) ...[
              Text(
                L.t('update.mustBody'),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpace.gapM),
            ],
            _kv(L.t('update.current'), currentVersion),
            const SizedBox(height: 4),
            _kv(L.t('update.latest'), manifest.version, highlight: true),
            if ((manifest.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: AppSpace.gapM),
              Text(
                L.t('update.notes'),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                manifest.notes!,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (!result.forced)
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L.t('update.later')),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L.t('update.now')),
          ),
        ],
      ),
    ),
  );

  if (go != true || !context.mounted) return;
  await _downloadAndInstall(context, service: service, manifest: manifest);
}

Future<void> _downloadAndInstall(
  BuildContext context, {
  required AppUpdateService service,
  required UpdateManifest manifest,
}) async {
  final progress = ValueNotifier<double?>(0);
  final status = ValueNotifier<String>(L.tp('update.downloading', {'percent': 0}));

  // 用不可关的对话框承载进度。下载中途被划掉会留下半个 APK，
  // 下次安装直接失败 —— 不如不让关。
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, text, __) => Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
            const SizedBox(height: AppSpace.gapL),
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, value, __) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                backgroundColor: AppColors.divider,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  var failed = false;
  var needsPermission = false;
  try {
    final path = await service.download(
      manifest,
      onProgress: (v) {
        progress.value = v;
        status.value = v == null
            ? L.t('update.downloading').replaceAll('{percent}', '…')
            : L.tp('update.downloading', {'percent': (v * 100).round()});
      },
    );
    status.value = L.t('update.installing');
    final installed = await service.installApk(path);
    if (!installed) needsPermission = true;
  } catch (_) {
    failed = true;
  }

  if (!context.mounted) return;
  // 关掉进度框。用 rootNavigator，避免被页内嵌套 Navigator 吃掉。
  Navigator.of(context, rootNavigator: true).pop();

  if (failed) {
    _toast(context, L.t('update.failed'));
    return;
  }
  if (needsPermission && context.mounted) {
    _toast(context, L.t('update.permissionHint'));
    // 顺手把用户送到授权页，省得自己去翻设置。
    await service.openInstallPermissionSettings();
  }
}

Widget _kv(String label, String value, {bool highlight = false}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
      ),
      Text(
        value,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
          color: highlight ? AppColors.primary : AppColors.textPrimary,
        ),
      ),
    ],
  );
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));
}
