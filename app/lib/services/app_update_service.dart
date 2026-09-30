/// 应用内自动更新（Android）。
///
/// 链路：
/// ```
/// 拉 version.json → 比 build 号 → 弹框 → 下载 APK（带进度）
///   → 交原生侧用 FileProvider 拉起系统安装器
/// ```
///
/// 三个必须知道的约束（改这块之前先读完）：
///
/// 1. **签名必须一致**。新包和手机上已装的包签名不同，系统会直接拒装
///    （报「应用未安装」）。所以 `android/app/build.gradle.kts` 里的签名配置
///    不能随便换；换 keystore 等于让老用户必须卸载重装。
///
/// 2. **普通 App 做不到静默安装**。安装界面一定会弹，用户要点「安装」。
///    凡是号称「无感更新」的，本质都是「后台先下好，再弹安装器」——这里也是。
///
/// 3. **iOS 走不通这条路**。Apple 不允许 App 自己下载安装包，只能跳到商店。
///    所以本文件在 iOS 上只做「查版本 + 提示」，不做下载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/region.dart';

/// 服务端版本清单。放一个静态 JSON 就够，不需要后端改代码 ——
/// 发版时只改这个文件，不用重新部署服务。
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.build,
    required this.url,
    this.notes,
    this.minBuild = 0,
    this.iosStoreUrl,
  });

  /// 展示用的版本名，如 `0.2.0`。
  final String version;

  /// 版本号（Android versionCode）。**比较以它为准** ——
  /// 版本名是给人看的字符串，没法可靠比较大小。
  final int build;

  /// APK 直链。可以是对象存储/CDN，不必和接口同域。
  final String url;

  /// 更新说明，纯文本，换行即分段。
  final String? notes;

  /// 低于这个 build 必须更新（强制）。用来推掉有严重 bug 的版本。
  final int minBuild;

  /// 海外区 iOS 跳商店用。国内不上 App Store，留空即可。
  final String? iosStoreUrl;

  static UpdateManifest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final version = '${raw['version'] ?? ''}'.trim();
    final build = raw['build'];
    final url = '${raw['url'] ?? ''}'.trim();
    if (version.isEmpty || url.isEmpty || build is! num) return null;
    return UpdateManifest(
      version: version,
      build: build.toInt(),
      url: url,
      notes: (raw['notes'] as String?)?.trim(),
      minBuild: (raw['minBuild'] as num?)?.toInt() ?? 0,
      iosStoreUrl: (raw['iosStoreUrl'] as String?)?.trim(),
    );
  }
}

/// 检查结果。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.manifest,
    required this.hasUpdate,
    required this.forced,
  });

  final UpdateManifest manifest;

  /// 服务端版本比本机新。
  final bool hasUpdate;

  /// 必须更新才能继续用（本机 build < manifest.minBuild）。
  final bool forced;
}

enum UpdateCheckStatus { hasUpdate, upToDate, unsupported, failed }

class UpdateCheckOutcome {
  const UpdateCheckOutcome(this.status, {this.result, this.error});

  final UpdateCheckStatus status;
  final UpdateCheckResult? result;
  final Object? error;
}

class AppUpdateService {
  AppUpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const MethodChannel _installer =
      MethodChannel('com.weiyuantool.pet_app/installer');

  /// 清单地址。默认打在区域后端上；联调/自测可以用
  /// `--dart-define=UPDATE_MANIFEST_URL=http://10.0.2.2:8000/app/version.json` 覆盖，
  /// 不必为了试一次更新去改代码。
  static String get manifestUrl {
    const override = String.fromEnvironment('UPDATE_MANIFEST_URL');
    if (override.isNotEmpty) return override;
    return '${AppRegion.current.apiBaseUrl}/app/version.json';
  }

  /// 拉清单并判断。**任何异常都返回 failed，不抛** ——
  /// 更新检查失败绝不能影响 App 正常启动。
  Future<UpdateCheckOutcome> check({
    required int currentBuild,
    String? currentVersion,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const UpdateCheckOutcome(UpdateCheckStatus.unsupported);
    }
    try {
      final resp = await _client
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        return UpdateCheckOutcome(UpdateCheckStatus.failed,
            error: 'HTTP ${resp.statusCode}');
      }
      final manifest =
          UpdateManifest.tryParse(jsonDecode(utf8.decode(resp.bodyBytes)));
      if (manifest == null) {
        return const UpdateCheckOutcome(UpdateCheckStatus.failed,
            error: '清单格式不对');
      }

      final newer = manifest.build > currentBuild ||
          (manifest.build == currentBuild &&
              compareVersion(manifest.version, currentVersion ?? '') > 0);
      if (!newer) {
        return UpdateCheckOutcome(
          UpdateCheckStatus.upToDate,
          result: UpdateCheckResult(
            manifest: manifest,
            hasUpdate: false,
            forced: false,
          ),
        );
      }
      return UpdateCheckOutcome(
        UpdateCheckStatus.hasUpdate,
        result: UpdateCheckResult(
          manifest: manifest,
          hasUpdate: true,
          forced: currentBuild < manifest.minBuild,
        ),
      );
    } catch (e) {
      return UpdateCheckOutcome(UpdateCheckStatus.failed, error: e);
    }
  }

  /// 下载 APK 到缓存目录，返回本地路径。
  ///
  /// 用流式写盘而不是先读进内存：APK 有 60 MB，一次性读进内存在小内存机型上
  /// 会被系统杀掉。`onProgress` 的入参是 0..1，总长拿不到时给 null。
  Future<String> download(
    UpdateManifest manifest, {
    void Function(double? progress)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'update'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 固定文件名：同一时间只会有一个待安装包，带时间戳只会攒垃圾。
    final dest = File(p.join(dir.path, 'app-update.apk'));
    if (dest.existsSync()) dest.deleteSync();

    final req = http.Request('GET', Uri.parse(manifest.url));
    final resp = await _client.send(req);
    if (resp.statusCode != 200) {
      throw HttpException('下载失败: HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength;
    var received = 0;

    final sink = dest.openWrite();
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total == null || total <= 0 ? null : received / total);
      }
    } finally {
      await sink.close();
    }

    if (received == 0) throw const HttpException('下载到的文件是空的');
    return dest.path;
  }

  /// 交给原生侧拉起安装器。返回 false 表示系统不允许安装未知来源应用，
  /// 调用方应引导用户去设置里授权。
  Future<bool> installApk(String path) async {
    if (!Platform.isAndroid) return false;
    final ok = await _installer.invokeMethod<bool>('installApk', {'path': path});
    return ok ?? false;
  }

  /// 打开系统「安装未知应用」授权页。用户拒绝一次之后需要它。
  Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    await _installer.invokeMethod<void>('openInstallSettings');
  }

  /// 语义化版本比较：返回 >0 表示 [a] 比 [b] 新。只比数字段，
  /// 遇到 `1.0.0-beta` 这类后缀按「不参与比较」处理。
  ///
  /// 公开而不是私有：这条逻辑直接决定「要不要弹更新」，必须有单测盯着。
  static int compareVersion(String a, String b) {
    List<int> parts(String s) => s
        .split('.')
        .map((seg) => int.tryParse(seg.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < 3; i++) {
      final vi = i < x.length ? x[i] : 0;
      final wi = i < y.length ? y[i] : 0;
      if (vi != wi) return vi - wi;
    }
    return 0;
  }
}
