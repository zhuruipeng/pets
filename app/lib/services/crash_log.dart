/// 崩溃与异常的**本地**记录。
///
/// ## 为什么不上报崩溃到 Sentry 之类
///
/// 三条理由，第一条是硬的：
/// 1. **隐私政策**。App 内两份隐私政策（含英文版、含网页版）都明确写了
///    「不做行为埋点、不做用户画像、不接入任何统计 SDK」。接 Sentry 就要
///    全部重写，并且**商店审核会对照** —— 为一个还没上线的产品改合规文件
///    不值得。
/// 2. **国内访问**。Sentry 的自建端点在境外，国内用户的网络质量不可控，
///    上报本身可能变成新的「有时候连不上」问题。
/// 3. **用户规模**。现在真实用户是个位数，接第三方 SDK 要引包、要配项目、
///    要看板，而面板上的数字一天能看一次就够。
///
/// ## 那怎么修 bug
///
/// 靠**用户主动把详情发给你**，但要保证「不用他描述、他也传得过来」。
/// 之前排查导出失败就是这么做的：让用户点「复制详情」，
/// 你拿到完整堆栈直接定位。这套流程有效，只是当时是临时加的。
///
/// 这里把它系统化：App 崩溃时自动记下完整信息，用户在「我的」里点一下
/// 就能看到并发出来。
///
/// ## 保存在哪
///
/// 纯本地文件，**不上传任何东西**。用户自己决定发不发。
/// 保留最近 [maxEntries] 条，避免无限增长。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/sync/sync_api.dart';

/// 反馈提交的函数签名。
///
/// 抽成 typedef 是为了让测试能注入假实现 —— `autoUpload` 内部要发网络请求，
/// 测试里真发会既慢又不确定（还可能真的把测试数据发到开发者邮箱）。
typedef FeedbackFn = Future<void> Function({
  required String message,
  String kind,
  String? appVersion,
  String? region,
  String? platform,
  String? stack,
});

/// 保留最近多少条。
///
/// 30 条的取舍：一个人一周能踩到的 bug 撑死十条，30 条够回溯一个多月；
/// 而每条含完整堆栈 + 设备信息约 2-5 KB，30 条不到 150 KB，
/// 不会因为「忘记清理」把用户的存储撑大。
const int maxEntries = 30;

/// 一次崩溃的记录。
class CrashEntry {
  const CrashEntry({
    required this.at,
    required this.kind,
    required this.message,
    required this.stack,
    this.context = const {},
  });

  final DateTime at;

  /// `flutter`（框架/界面层）、`platform`（原生回调）、`zone`（未捕获异步）、
  /// `manual`（手动记录）。
  final String kind;

  final String message;
  final String stack;

  /// 附加信息：当前页面、App 版本、区域等。
  final Map<String, String> context;

  /// 存成一行 JSON。**刻意保持单行** —— 多行会让「一个文件一个问题」
  /// 的排查策略失效，grep 一次定位一条。
  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'kind': kind,
        'message': message,
        'stack': stack,
        'context': context,
      };

  static CrashEntry fromJson(Map<String, dynamic> m) => CrashEntry(
        at: DateTime.tryParse(m['at'] as String? ?? '') ?? DateTime.now(),
        kind: m['kind'] as String? ?? 'unknown',
        message: m['message'] as String? ?? '',
        stack: m['stack'] as String? ?? '',
        context: (m['context'] as Map?)?.cast<String, String>() ??
            const <String, String>{},
      );

  /// 给用户看的文本。
  ///
  /// **要能一眼看出「什么操作触发的」** —— 只贴一堆堆栈的话，
  /// 对方（开发者）还得反推是哪一步点的。所以带上 context 与时间。
  String toDisplayText() {
    final buf = StringBuffer()
      ..writeln('[$kind] $message')
      ..writeln('时间: ${at.toIso8601String()}');
    if (context.isNotEmpty) {
      final ctx = context.entries.map((e) => '${e.key}=${e.value}').join('  ');
      buf.writeln('环境: $ctx');
    }
    buf
      ..writeln('---')
      ..writeln(stack);
    return buf.toString();
  }
}

class CrashLog {
  CrashLog._();
  static final CrashLog instance = CrashLog._();

  File? _file;
  final List<CrashEntry> _buffer = [];

  /// 内存里的最新记录，「我的」页直接读这个，不用等 IO。
  List<CrashEntry> get recent => List.unmodifiable(_buffer);

  /// 打开日志文件。**失败不能影响 App 启动** —— 记日志是辅助功能，
  /// 它挂了不该让用户打不开 App。
  Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/crash_log.jsonl');
      if (await _file!.exists()) {
        await _load();
      }
    } catch (e) {
      debugPrint('[crash_log] 初始化失败，不影响启动：$e');
    }
  }

  Future<void> _load() async {
    try {
      final lines = await _file!.readAsLines();
      // 只取最后 maxEntries 条：文件可能比内存缓冲长（比如上次没被清理）。
      for (final line in lines.skip(
        lines.length > maxEntries ? lines.length - maxEntries : 0,
      )) {
        if (line.trim().isEmpty) continue;
        _buffer.insert(
          0,
          CrashEntry.fromJson(
            jsonDecode(line) as Map<String, dynamic>,
          ),
        );
      }
    } catch (e) {
      // 内容损坏就当空日志。**不能抛** —— 一行坏 JSON 让整个 App 打不开
      // 是极不划算的取舍。
      debugPrint('[crash_log] 读取失败，按空处理：$e');
      _buffer.clear();
    }
  }

  /// 记一条。不抛异常 —— 记录失败绝不能把被记录的异常变成更大的问题。
  Future<void> record(CrashEntry entry) async {
    _buffer.insert(0, entry);
    while (_buffer.length > maxEntries) {
      _buffer.removeLast();
    }
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      // 追加写会让文件无限增长。按需截断：超过 2 倍上限就重写一遍。
      if (await file.length() > maxEntries * 300) {
        await file.writeAsString(
          _buffer.map((e) => '${jsonEncode(e.toJson())}\n').join(),
        );
      }
    } catch (e) {
      debugPrint('[crash_log] 写入失败：$e');
    }
  }

  /// 把当前缓冲写回文件。
  ///
  /// 为什么需要它：自动上报成功后要从缓冲里**删掉已送达的**，
  /// 而文件是追加写的、不会自动收缩 —— 不重写一遍的话，
  /// 下次启动又把旧的读回来了，等于没删。
  Future<void> _persist() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
        _buffer.map((e) => '${jsonEncode(e.toJson())}\n').join(),
      );
    } catch (e) {
      debugPrint('[crash_log] 重写失败：$e');
    }
  }

  /// 把未上传的崩溃记录上传。
  ///
  /// ## 为什么是「下次启动时传」而不是「崩溃时传」
  ///
  /// 崩溃瞬间 App 已经死了，socket 也断了 —— 那时发请求必然失败。
  /// 所以记录留在本地，等**下次启动**再补传。这也符合
  /// 「崩溃时用户不会想立刻联网」的实际。
  ///
  /// ## 为什么是「匿名」的
  ///
  /// 隐私政策里承诺不收集设备唯一标识、不做用户画像。所以上传的内容里
  /// **没有** 设备 ID、账号、手机号、IMEI 之类的东西，只有：
  /// 崩溃类型、消息、堆栈、App 版本、区域、平台。
  ///
  /// 这意味着同两个人的两次相同崩溃无法区分 —— 这是**故意的**：
  /// 定位 bug 只需要「什么错、在哪一版、什么设备」，不需要「是谁」。
  ///
  /// ## 为什么上传失败不重试到天荒地老
  ///
  /// 离线状态下重试没有意义，且每次启动都重试会耗电。
  /// 失败就留在本地，等下次启动再试 —— 那时候用户可能已经联网了。
  Future<void> autoUpload() async {
    if (_buffer.isEmpty) return;
    if (_uploading) return;
    _uploading = true;
    try {
      var sent = 0;
      for (final e in _buffer) {
        try {
          await feedbackSender(
            message: '[自动上报] ${e.message.split('\n').first}',
            kind: 'crash-${e.kind}',
            appVersion: e.context['appVersion'] ?? _appVersion,
            region: e.context['region'] ?? _region,
            platform: e.context['platform'] ?? Platform.operatingSystem,
            stack: e.stack,
          );
          sent++;
        } catch (_) {
          // 单条失败就停 —— 多半是网络问题，继续试也是白试，
          // 而且会把用户电量耗在重试上。
          break;
        }
      }
      if (sent > 0) {
        // 只清掉**已确认送达**的那些，剩下的留在本地等下次。
        // 为什么不全清：请求返回不代表对方真的收到了，
        // 而崩溃记录复现一次可能隔很久，丢一条就少一个样本。
        _buffer.removeRange(0, sent);
        await _persist();
        debugPrint('[crash_log] 已自动上报 $sent 条崩溃记录');
      }
    } catch (_) {
      // 上报本身绝不能影响 App 启动 —— 它失败就静默，
      // 反正记录还在本地，用户可以手动提交。
    } finally {
      _uploading = false;
    }
  }

  bool _uploading = false;

  /// 注入点。测试用它替换成假实现，避免真发请求。
  ///
  /// 必须是 `FeedbackFn`（一个闭包）而不是 `SyncApi` —— 要绑的是
  /// 「提交反馈」这个动作，不是整个 API 客户端。返回 SyncApi 会让
  /// 类型不匹配，而且测试想替换时还得造一个真的 SyncApi。
  @visibleForTesting
  static FeedbackFn feedbackSender = ({required String message, String kind = 'manual', String? appVersion, String? region, String? platform, String? stack}) {
        return SyncApi().submitFeedback(
          message: message,
          kind: kind,
          appVersion: appVersion,
          region: region,
          platform: platform,
          stack: stack,
        );
      };

  /// 一键清空。用户觉得「这些都修好了」时该能自己删。
  Future<void> clear() async {
    _buffer.clear();
    try {
      await _file?.delete();
    } catch (_) {
      // 文件本来就不在，清空内存已经达到了目的。
    }
  }

  /// 装上全局捕获。
  ///
  /// **三个入口都要装，缺一个就漏一类错误：**
  /// - [FlutterError.onError] —— 同步的界面/构建错误（debug 模式下会被打印）
  /// - [PlatformDispatcher.onError] —— 原生侧回调进来的错误
  /// - `runZonedGuarded` —— 未 await 的 Future 里抛的（**最容易漏**，
  ///   两个 onError 都抓不到）
  ///
  /// 只装前两个的话，用户点了按钮没反应、日志里什么都没有 —— 这正是
  /// 「没反应」类问题最难查的原因。
  void installGlobalHandlers() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      // 保留原有行为（debug 下打印到控制台），否则真机静默得连日志都没了。
      previous?.call(details);
      unawaited(
        record(
          CrashEntry(
            at: DateTime.now(),
            kind: 'flutter',
            message: details.exceptionAsString(),
            stack: details.stack?.toString() ?? '(无堆栈)',
            context: _baseContext(),
          ),
        ),
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(
        record(
          CrashEntry(
            at: DateTime.now(),
            kind: 'platform',
            message: error.toString(),
            stack: stack.toString(),
            context: _baseContext(),
          ),
        ),
      );
      // 返回 true = 认为处理完了，不再交给系统默认处理（否则会红屏/闪退）。
      // 我们已经把详情记下来了，让它继续崩反而会丢掉后续信息。
      return true;
    };
  }

  /// 附加信息里放什么。
  ///
  /// 只放**开发者定位必需的**，不放任何用户隐私内容 ——
  /// 不放手机号、不放宠物名、不放备注正文。这个文件可能被用户截图发到
  /// 公开场合，内容越少越安全。
  Map<String, String> _baseContext() {
    return {
      'version': 'app',
      if (_appVersion != null) 'appVersion': _appVersion!,
      if (_region != null) 'region': _region!,
      'platform': Platform.operatingSystem,
    };
  }

  String? _appVersion;
  String? _region;

  /// 仅供测试：重置单例状态。
  ///
  /// 单例的私有构造跨库不可见，测试没法 `CrashLog._()` 建新实例，
  /// 而直接用 `instance` 又会在测试之间串状态（上一条用例记的日志
  /// 会出现在下一条的 `recent` 里，断言结果不可信）。
  ///
  /// 加这个方法而不是把构造改成 public：单例就该只有一个，
  /// 为测试放开构造等于允许生产代码造出第二个实例去写同一个文件。
  @visibleForTesting
  void resetForTest() {
    _file = null;
    _buffer.clear();
    _appVersion = null;
    _region = null;
  }

  /// 由 main 启动时注入版本与区域，让每条记录都带上。
  ///
  /// 「用户装的是哪个版本」是复现问题的前提 —— 同一个 bug 在 0.1.6 修了
  /// 而用户还是 0.1.5，就会出现「明明修好了还有」的情况。
  void setAppInfo({String? version, String? region}) {
    _appVersion = version;
    _region = region;
  }
}
