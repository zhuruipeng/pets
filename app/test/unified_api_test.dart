/// 官网统一账号客户端（cn 区登录路径）的请求与解析测试。
///
/// 这一层能脱离网络测，是因为它只做「协议翻译」：把 HTTP 请求拼对、
/// 把响应读对。真正会出事的也正是这两件事 —— 路径写错、字段名对不上、
/// 中文提示解码成乱码，都是那种「本机跑得好好的、上线才炸」的问题。
///
/// 用 MockClient 而不是真打官网：本机测试不该依赖外网，也不该往老板的
/// 生产站发请求（那会真的发短信）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pet_app/core/region.dart';
import 'package:pet_app/data/sync/unified_api.dart';

const String _base = 'https://www.weiyuantool.com';

/// 记录收到的请求，方便断言「发出去的是什么」。
class _Recorder {
  final List<http.Request> requests = [];

  Uri get lastUri => requests.last.url;
  Map<String, dynamic> get lastBody =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;
}

/// 造一个假官网。`body` 用字节给，才能覆盖「中文靠 UTF-8 解」这条。
UnifiedAccountApi _api(
  _Recorder rec, {
  required int status,
  String body = '{}',
}) {
  final client = MockClient((req) async {
    rec.requests.add(req);
    return http.Response.bytes(
      utf8.encode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  return UnifiedAccountApi(client: client, baseUrl: _base);
}

void main() {
  group('区域开关', () {
    test('测试环境默认是海外区，统一账号不启用', () {
      // flutter test 不带 --dart-define=REGION 时 REGION 默认 intl。
      // 这条断言是「海外区永远不会误走中国账号」的第一道证据。
      expect(AppRegion.current, Region.intl);
      expect(AppRegion.current.unifiedAccountBaseUrl, isNull);
      expect(UnifiedAccountApi.isAvailable, isFalse);
    });

    test('intl 的 baseUrl 是 null 而不是空串', () {
      // 用 null 表示「没有这个能力」，调用方写 if (base != null)；
      // 返回空串会让人误以为「配了但填错了」。
      expect(Region.intl.unifiedAccountBaseUrl, isNull);
    });

    test('cn 有默认地址，且必须带 www', () {
      final base = Region.cn.unifiedAccountBaseUrl;
      expect(base, isNotNull);
      expect(base, startsWith('https://'));
      // 裸域对**所有**请求（含 POST）301 到 www，而 Dart 的 HttpClient
      // 对非 GET 的 301 不自动跟随 → 拿到的是 nginx 的 HTML 错误页。
      // 实测见 tool/probe_unified_account.dart；配错的表现是
      // 「验证码永远发不出去」，排查时很难联想到域名。
      expect(base, contains('//www.'), reason: '必须是 www 这个规范主机');
    });
  });

  group('配置门禁', () {
    test('没配地址就调用，抛 StateError 而不是发请求', () {
      final api = UnifiedAccountApi(baseUrl: '');
      expect(
        () => api.requestCode(phone: '13800138000'),
        throwsA(isA<StateError>()),
      );
    });

    test('尾部斜杠会被去掉，不拼出双斜杠', () async {
      final rec = _Recorder();
      final withSlash = UnifiedAccountApi(
        client: MockClient((req) async {
          rec.requests.add(req);
          return http.Response('{"ok":true}', 200);
        }),
        baseUrl: '$_base///',
      );
      await withSlash.requestCode(phone: '13800138000');
      expect(rec.lastUri.toString(), '$_base/api/auth/sms/send');
    });
  });

  group('发验证码', () {
    test('路径、方法、body 都对', () async {
      final rec = _Recorder();
      await _api(rec, status: 200, body: '{"ok":true,"expires_in":300}')
          .requestCode(phone: '13800138000');

      expect(rec.requests.last.method, 'POST');
      expect(rec.lastUri.toString(), '$_base/api/auth/sms/send');
      expect(rec.lastBody['phone'], '13800138000');
      // scene=login 与官网登录进的是**同一个码池**。这不是巧合，正是 A 方案
      // 的要义：同一个账号域，用户在官网发的码也能拿来登宠物 App。
      //
      // 注意 scene **不决定短信模板** —— 模板是按 `ALIYUN_SMS_TEMPLATE_{SCENE}`
      // 环境变量找、找不到就回退到 `ALIYUN_SMS_TEMPLATE_CODE`（服务器上只配了
      // 后者），所以各 scene 最终都走同一条已报备模板。
      expect(rec.lastBody['scene'], 'login');
      expect(rec.lastBody.keys.toSet(), {'phone', 'scene'});
    });

    test('解析 expires_in 与 debug_code', () async {
      final rec = _Recorder();
      final r = await _api(
        rec,
        status: 200,
        body: '{"ok":true,"expires_in":300,"debug_code":"123456",'
            '"provider":"local-debug"}',
      ).requestCode(phone: '13800138000');

      expect(r.sent, isTrue);
      expect(r.expiresIn, 300);
      expect(r.debugCode, '123456');
    });

    test('debug 响应没有 expires_in 时不报错，expiresIn 为空', () async {
      // 官网开 APP_SMS_DEBUG 时返回 {"debug_code":..., "provider":...}，
      // 没有 expires_in。别把两者绑在一起判断。
      final rec = _Recorder();
      final r = await _api(
        rec,
        status: 200,
        body: '{"debug_code":"000000","provider":"local-debug"}',
      ).requestCode(phone: '13800138000');

      expect(r.expiresIn, isNull);
      expect(r.debugCode, '000000');
      expect(r.sent, isFalse);
    });

    test('中文错误消息不乱码', () async {
      final rec = _Recorder();
      UnifiedApiException? caught;
      try {
        await _api(
          rec,
          status: 400,
          body: '{"detail":"短信服务未配置，请先设置阿里云短信环境变量"}',
        ).requestCode(phone: '13800138000');
      } on UnifiedApiException catch (e) {
        caught = e;
      }
      // 用 resp.body 会退回 latin1，整句变乱码 —— 这条就是在钉死这一点。
      expect(caught?.message, '短信服务未配置，请先设置阿里云短信环境变量');
    });

    test('限流是 429，可被识别为「等一会儿」', () async {
      final rec = _Recorder();
      UnifiedApiException? caught;
      try {
        await _api(rec, status: 429, body: '{"detail":"发送太频繁"}')
            .requestCode(phone: '13800138000');
      } on UnifiedApiException catch (e) {
        caught = e;
      }
      expect(caught?.isTooManyRequests, isTrue);
      expect(caught?.isUnauthorized, isFalse);
    });

    test('非 JSON 响应不会崩，退到状态码文案', () async {
      final rec = _Recorder();
      UnifiedApiException? caught;
      try {
        await _api(rec, status: 502, body: '<html>bad gateway</html>')
            .requestCode(phone: '13800138000');
      } on UnifiedApiException catch (e) {
        caught = e;
      }
      expect(caught?.statusCode, 502);
      expect(caught?.message, contains('502'));
    });

    test('301 要提示「地址被重定向」，而不是一句无信息的状态码', () async {
      // 真实现场：baseUrl 配成裸域 weiyuantool.com 时，nginx 对 POST 也回
      // 301 到 www，而 Dart 不跟随非 GET 的 301 → 响应体是那张 HTML 错误页。
      // 没有这条特判，用户看到的是「操作失败」、开发者看到 error (301)，
      // 两边都指不到真正的原因（域名少了 www）。
      final rec = _Recorder();
      UnifiedApiException? caught;
      try {
        await _api(rec, status: 301, body: '<html>301 Moved Permanently</html>')
            .requestCode(phone: '13800138000');
      } on UnifiedApiException catch (e) {
        caught = e;
      }
      expect(caught?.statusCode, 301);
      expect(caught?.message, contains('redirected'));
      expect(caught?.message, contains('UNIFIED_ACCOUNT_BASE'));
    });
  });

  group('验证码登录', () {
    test('路径与 body 都对', () async {
      final rec = _Recorder();
      await _api(
        rec,
        status: 200,
        body: '{"ok":true,"token":"acct-token-abc","account":'
            '{"id":7,"phone":"13800138000","nickname":"阿黄的主人"}}',
      ).login(phone: '13800138000', code: '123456');

      expect(rec.lastUri.toString(), '$_base/api/auth/login-sms');
      expect(rec.lastBody, {'phone': '13800138000', 'code': '123456'});
    });

    test('解析 token 与账号信息', () async {
      final rec = _Recorder();
      final r = await _api(
        rec,
        status: 200,
        body: '{"ok":true,"token":"acct-token-abc","name":"商城昵称","account":'
            '{"id":7,"phone":"13800138000","nickname":"阿黄的主人"}}',
      ).login(phone: '13800138000', code: '123456');

      expect(r.token, 'acct-token-abc');
      expect(r.accountId, '7');
      expect(r.phone, '13800138000');
      // account.nickname 优先于顶层的 name（那是商城客户名，不是账号名）。
      expect(r.nickname, '阿黄的主人');
    });

    test('account 缺席时用顶层 name 兜底昵称', () async {
      final rec = _Recorder();
      final r = await _api(
        rec,
        status: 200,
        body: '{"ok":true,"token":"t-12345678","name":"商城昵称","phone":"13800138000"}',
      ).login(phone: '13800138000', code: '123456');
      expect(r.nickname, '商城昵称');
    });

    test('200 但没给 token —— 必须抛，绝不带着空 token 往下走', () async {
      final rec = _Recorder();
      await expectLater(
        _api(rec, status: 200, body: '{"ok":true,"account":{"id":7}}')
            .login(phone: '13800138000', code: '123456'),
        throwsA(isA<UnifiedApiException>()),
      );
    });

    test('401 会被识别为令牌被拒', () async {
      final rec = _Recorder();
      UnifiedApiException? caught;
      try {
        await _api(rec, status: 401, body: '{"detail":"验证码错误"}')
            .login(phone: '13800138000', code: '000000');
      } on UnifiedApiException catch (e) {
        caught = e;
      }
      expect(caught?.isUnauthorized, isTrue);
      expect(caught?.message, '验证码错误');
    });
  });
}
