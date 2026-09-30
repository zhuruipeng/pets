/// 官网「统一账号」的 HTTP 客户端 —— **只在中国区使用**。
///
/// 为什么单独一个类，而不是塞进 [SyncApi]：这是**另一个后端**。
/// 路径前缀不同（官网 `/api/auth/*`，宠物 `/api/v1/auth/*`）、
/// 字段命名不同（官网 `account.phone`，宠物 `user.phone`）、
/// 部署位置也不同。混在一起会让「宠物 API 客户端」同时依赖两份契约，
/// 以后改任何一边都得先读另一边。
///
/// 它只做两件事：发验证码、验证码换账号令牌。换宠物域令牌的那一步
/// 打的是宠物服务端，所以留在 [SyncApi] 里 —— 那条边界是「谁来当请求的
/// 收件方」，不是「谁和登录有关」。
///
/// 契约来源：官网 `server/api_routes/identity_02.py` + `server/auth_center.py`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/region.dart';

/// 官网接口返回非 2xx，或响应体不符合契约。
class UnifiedApiException implements Exception {
  UnifiedApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  /// 账号令牌被拒（官网登出/过期）。区别于「网络不通」。
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  /// 官网自己的限流（同一手机号 60 秒内重复发码）。
  bool get isTooManyRequests => statusCode == 429;

  @override
  String toString() => 'UnifiedApiException($statusCode): $message';
}

/// 发码结果。[debugCode] 只在官网开了 `APP_SMS_DEBUG=1` 时非空。
class UnifiedCodeResult {
  const UnifiedCodeResult({required this.sent, this.expiresIn, this.debugCode});

  final bool sent;
  final int? expiresIn;
  final String? debugCode;
}

/// 官网账号域的一次登录结果。**这个 token 只用来换票，用完即弃。**
class UnifiedLogin {
  const UnifiedLogin({
    required this.token,
    required this.accountId,
    required this.phone,
    required this.nickname,
  });

  final String token;
  final String accountId;
  final String phone;
  final String nickname;
}

class UnifiedAccountApi {
  UnifiedAccountApi({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = _normalizeBase(
          baseUrl ?? (AppRegion.current.unifiedAccountBaseUrl ?? ''),
        );

  final http.Client _client;
  final String baseUrl;

  static const Duration _timeout = Duration(seconds: 15);

  /// 去掉尾部斜杠。
  ///
  /// `--dart-define=UNIFIED_ACCOUNT_BASE=https://x/` 里手写带斜杠是常事，
  /// 拼出 `//api/auth/sms/send` 之后 nginx 通常先 301 再跳 —— 多一跳，
  /// 而且重定向时部分客户端会丢掉 Authorization 头（这一步是 POST+body，
  /// 更要命）。在入口处规范化，后面所有拼路径的地方都不用再想这件事。
  static String _normalizeBase(String raw) =>
      raw.trim().replaceAll(RegExp(r'/+$'), '');

  /// 本区域是否使用统一账号登录。界面据此决定「要不要显示邮箱通道」。
  static bool get isAvailable => AppRegion.current.unifiedAccountBaseUrl != null;

  /// 短信场景。官网的 scene 白名单是
  /// `{register, login, reset_password, bind_phone}`，宠物登录用 `login`。
  ///
  /// ⚠️ 用 `login` 意味着**和官网自身登录共享同一份 60 秒限流**：
  /// 用户刚在官网点过发码，再来 App 点会被拒。这正是「同一个账号」应有的
  /// 行为（他收到的就是同一条短信），所以不另立 scene。
  static const String _scene = 'login';

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers => const {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
      };

  /// 发登录验证码给 `phone`。
  Future<UnifiedCodeResult> requestCode({required String phone}) async {
    _ensureConfigured();
    final resp = await _client
        .post(
          _uri('/api/auth/sms/send'),
          headers: _headers,
          body: jsonEncode({'phone': phone, 'scene': _scene}),
        )
        .timeout(_timeout);

    final body = _decode(resp);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw UnifiedApiException(resp.statusCode, _detail(body, resp.statusCode));
    }
    return UnifiedCodeResult(
      sent: body['ok'] == true,
      expiresIn: (body['expires_in'] as num?)?.toInt(),
      // 官网 debug 返回里只有 debug_code、没有 expires_in；别把两者绑在一起判断。
      debugCode: body['debug_code'] as String?,
    );
  }

  /// 验证码换账号令牌。首次登录官网会顺带建号（登录即注册）。
  Future<UnifiedLogin> login({
    required String phone,
    required String code,
  }) async {
    _ensureConfigured();
    final resp = await _client
        .post(
          _uri('/api/auth/login-sms'),
          headers: _headers,
          body: jsonEncode({'phone': phone, 'code': code}),
        )
        .timeout(_timeout);

    final body = _decode(resp);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw UnifiedApiException(resp.statusCode, _detail(body, resp.statusCode));
    }

    final token = '${body['token'] ?? ''}'.trim();
    if (token.isEmpty) {
      // 200 但没给令牌：契约破了。**绝不返回空 token 往下走** ——
      // 下一步换票会带着空串去问宠物服务端，错误信息会跑偏到「令牌无效」，
      // 排查时会被引到完全错误的方向。
      throw UnifiedApiException(resp.statusCode, 'login response missing token');
    }

    final account = (body['account'] as Map?)?.cast<String, dynamic>() ?? const {};
    return UnifiedLogin(
      token: token,
      accountId: '${account['id'] ?? ''}',
      phone: '${account['phone'] ?? phone}',
      nickname: '${account['nickname'] ?? body['name'] ?? phone}',
    );
  }

  void _ensureConfigured() {
    if (baseUrl.trim().isEmpty) {
      // 走到这里说明调用方没先看 isAvailable。抛出来比发一个打不通的请求好：
      // 前者的堆栈直接指向漏判的调用点。
      throw StateError('unified account is not configured for this region');
    }
  }

  /// 解析响应体。官网返回体里的中文消息必须按 UTF-8 解 ——
  /// `resp.body` 用的是响应头里的 charset，官网没声明时会退回 latin1，
  /// 中文提示全变乱码。
  Map<String, dynamic> _decode(http.Response resp) {
    if (resp.bodyBytes.isEmpty) return const {};
    try {
      final parsed = jsonDecode(utf8.decode(resp.bodyBytes));
      return parsed is Map ? parsed.cast<String, dynamic>() : const {};
    } on FormatException {
      return const {};
    }
  }

  /// 从错误体里取人话。官网 `_err(code, msg)` 统一发 `{"detail": msg}`，
  /// 与宠物服务端同名，所以两边的错误文案能共用一套展示逻辑。
  String _detail(Map<String, dynamic> body, int status) {
    final detail = '${body['detail'] ?? body['error'] ?? body['msg'] ?? ''}'.trim();
    if (detail.isNotEmpty) return detail;
    if (status == 429) return 'too many requests';
    return 'unified account error ($status)';
  }
}
