// ignore_for_file: avoid_print
// ↑ 命令行自检脚本，print 是它的输出方式（同 verify_*.dart）。

// 官网统一账号（cn 区登录链路）的生产自检。
//
// 为什么能用 `dart.exe` 直接跑：这整条链路的依赖只有 `dart:*` 与
// `package:http` —— `core/region.dart` 零 import、`unified_api.dart` 不碰
// `package:flutter/`。所以本机那个「非提权进程起不了 flutter」的限制
// （CreateFile failed 231）在这里不适用，契约改坏了当场就能发现。
//
// 用法：
//   dart tool/probe_unified_account.dart                  # 用 region.dart 里的默认地址
//   dart tool/probe_unified_account.dart https://xxx.com  # 指定别的地址
// 退出码 0 = 全部通过，非 0 = 有失败项。
//
// ⚠️ 安全：脚本只发**必然被服务端拒绝**的请求 ——
//    空手机号（`_valid_phone` 先于限流与发码拦下）、不存在的令牌。
//    不会真的发出短信、不会写库、不会消耗限流配额。
//    **绝不要**把这里的空手机号换成真手机号。
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pet_app/core/region.dart';
import 'package:pet_app/data/sync/unified_api.dart';

int _failed = 0;

void pass(String label, String detail) => print('  [OK]   $label — $detail');

void fail(String label, String detail) {
  _failed++;
  print('  [FAIL] $label — $detail');
}

/// 把「抛出的异常」当结果用：这些请求本来就该被拒。
Future<Object?> _expectThrow(Future<void> Function() call) async {
  try {
    await call();
    return null;
  } catch (e) {
    return e;
  }
}

Future<void> main(List<String> argv) async {
  final explicit = argv.isNotEmpty ? argv.first.trim() : '';
  final configured = Region.cn.unifiedAccountBaseUrl;
  final base = explicit.isNotEmpty ? explicit : (configured ?? '');

  print('=== 官网统一账号自检 ===');
  print('  region.dart 里 cn 的默认地址 : $configured');
  print('  本次实际探测的地址           : $base');
  print('  (本进程 AppRegion.current = ${AppRegion.current.name}，'
      '所以下面显式传地址，不吃默认值)');
  print('');

  if (base.isEmpty) {
    fail('地址配置', 'cn 的 unifiedAccountBaseUrl 是空的');
    print('\n结论：$_failed 项失败');
    exit(1);
  }

  // 1) 规范地址必须带 www —— 裸域会被 301，而 Dart 不跟随非 GET 的 301。
  if (base.contains('//www.')) {
    pass('规范地址', '带 www');
  } else if (base.contains('weiyuantool.com')) {
    fail('规范地址', '缺 www —— 裸域对 POST 也回 301，Dart 不跟随，验证码发不出去');
  } else {
    pass('规范地址', '非 weiyuantool.com 域名，跳过 www 检查');
  }

  final api = UnifiedAccountApi(baseUrl: base);

  // 2) 发码路径。空手机号必然被拒，但「被拒的方式」能证明契约：
  //    400 + 服务端自己写的中文提示 = 域名/路径/方法/字段名/UTF-8 全都对。
  print('');
  print('2) 发验证码端点（空手机号，服务端应拒）');
  final codeErr = await _expectThrow(
    () => api.requestCode(phone: ''),
  );
  if (codeErr is UnifiedApiException) {
    if (codeErr.statusCode == 400) {
      pass('POST /api/auth/sms/send', '400 · ${codeErr.message}');
    } else if (codeErr.statusCode >= 300 && codeErr.statusCode < 400) {
      fail('POST /api/auth/sms/send',
          '${codeErr.statusCode} · ${codeErr.message}（地址被重定向，检查 UNIFIED_ACCOUNT_BASE）');
    } else {
      fail('POST /api/auth/sms/send',
          '期望 400，实际 ${codeErr.statusCode} · ${codeErr.message}');
    }
  } else if (codeErr != null) {
    fail('POST /api/auth/sms/send', '非预期异常：$codeErr');
  } else {
    fail('POST /api/auth/sms/send', '空手机号竟然成功了？服务端校验有洞');
  }

  // 3) 换票时用来验身份的那个接口。假令牌应得 401。
  //    直接手写请求而不是走客户端类：`UnifiedAccountApi` 不暴露 me，
  //    这一项验的是**官网契约**（路径 + 鉴权语义）而不是我们自己的封装。
  print('');
  print('3) 身份接口（假令牌，应为 401）');
  try {
    final resp = await http.get(
      Uri.parse('$base/api/auth/me'),
      headers: {'Authorization': 'Bearer probe-not-a-real-token'},
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      pass('GET /api/auth/me', '401，鉴权生效');
    } else if (resp.statusCode >= 300 && resp.statusCode < 400) {
      fail('GET /api/auth/me', '${resp.statusCode} 被重定向 —— 地址不是规范主机');
    } else {
      fail('GET /api/auth/me', '期望 401，实际 ${resp.statusCode}');
    }
  } catch (e) {
    fail('GET /api/auth/me', '请求异常：$e');
  }

  print('');
  print(_failed == 0 ? '全部通过。' : '$_failed 项失败。');
  exit(_failed == 0 ? 0 : 1);
}
