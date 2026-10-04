/// 同步与账号的 HTTP 客户端。
///
/// 只负责「把协议翻译成请求」和「把响应翻译成对象」，不含任何同步策略 ——
/// 策略在 [SyncEngine] 里。这样拆是为了让策略部分能脱离网络单测。
///
/// 接口契约见 docs/同步协议.md 第五节。**改这里之前先读那份文档。**
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/region.dart';

/// 接口返回非 2xx，或响应体不符合契约。
class SyncApiException implements Exception {
  SyncApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  bool get isUnauthorized => statusCode == 401;

  /// 服务端限流（如验证码 60 秒内重复请求）。
  bool get isTooManyRequests => statusCode == 429;

  @override
  String toString() => 'SyncApiException($statusCode): $message';
}

/// 服务端用户。
class RemoteUser {
  const RemoteUser({
    required this.id,
    required this.nickname,
    this.phone,
    this.email,
    this.wechat,
    this.contactNote,
    this.region,
  });

  final String id;
  final String nickname;
  final String? phone;
  final String? email;
  final String? wechat;
  final String? contactNote;
  final String? region;

  factory RemoteUser.fromJson(Map<String, dynamic> j) => RemoteUser(
        id: '${j['id']}',
        nickname: '${j['nickname'] ?? ''}',
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        wechat: j['wechat'] as String?,
        contactNote: j['contact_note'] as String?,
        region: j['region'] as String?,
      );
}

class AuthSession {
  const AuthSession({required this.token, required this.user, this.expiresAt});

  final String token;
  final RemoteUser user;
  final DateTime? expiresAt;
}

class CodeRequestResult {
  const CodeRequestResult({required this.sent, this.expiresIn, this.devCode});

  final bool sent;
  final int? expiresIn;

  /// 开发环境回显的验证码。生产环境服务端不下发这个字段。
  final String? devCode;
}

/// 一条待推送 / 已拉取的变更。
class SyncChange {
  const SyncChange({
    required this.table,
    required this.rowId,
    required this.op,
    this.petId,
    this.updatedAt,
    this.payload = const {},
    this.seq,
  });

  final String table;
  final String rowId;

  /// `upsert` / `delete`（墓碑）。
  final String op;

  final String? petId;

  /// 客户端本地时间（毫秒），LWW 的比较基准。pull 回来的可能没有。
  final int? updatedAt;

  final Map<String, dynamic> payload;

  /// 服务端序号，只有 pull 回来的才有。
  final int? seq;

  bool get isDelete => op == 'delete';

  factory SyncChange.fromJson(Map<String, dynamic> j) => SyncChange(
        table: '${j['table']}',
        rowId: '${j['row_id']}',
        op: '${j['op'] ?? 'upsert'}',
        petId: j['pet_id'] as String?,
        updatedAt: (j['updated_at'] as num?)?.toInt(),
        payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        seq: (j['seq'] as num?)?.toInt(),
      );

  Map<String, dynamic> toPushJson() => {
        'table': table,
        'row_id': rowId,
        'op': op,
        if (petId != null) 'pet_id': petId,
        if (updatedAt != null) 'updated_at': updatedAt,
        'payload': payload,
      };
}

class PushResult {
  const PushResult({
    required this.applied,
    required this.rejected,
    this.serverSeq,
  });

  /// 已被服务端接受（含 delete）。
  final List<SyncChange> applied;

  /// 被拒（`stale` 服务端更新 / `forbidden` 无权限）。
  final List<({SyncChange change, String reason})> rejected;

  final int? serverSeq;
}

class PullResult {
  const PullResult({
    required this.changes,
    required this.nextSince,
    required this.hasMore,
  });

  final List<SyncChange> changes;
  final int nextSince;
  final bool hasMore;
}

/// 共养成员（服务端视图）。
class RemoteMember {
  const RemoteMember({
    required this.userId,
    required this.role,
    required this.status,
    this.nickname,
    this.joinedAt,
    this.isMe = false,
  });

  final String userId;
  final String role;
  final String status;
  final String? nickname;
  final DateTime? joinedAt;
  final bool isMe;

  factory RemoteMember.fromJson(Map<String, dynamic> j) => RemoteMember(
        userId: '${j['user_id'] ?? j['id']}',
        role: '${j['role'] ?? 'editor'}',
        status: '${j['status'] ?? 'active'}',
        nickname: j['nickname'] as String?,
        joinedAt: (j['joined_at'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['joined_at'] as num).toInt()),
        isMe: j['is_me'] == true,
      );
}

/// 我收到的一条共养邀请。
class RemoteInvite {
  const RemoteInvite({
    required this.inviteId,
    required this.petId,
    required this.role,
    this.petName,
    this.invitedAt,
  });

  final String inviteId;
  final String petId;
  final String role;
  final String? petName;
  final DateTime? invitedAt;

  factory RemoteInvite.fromJson(Map<String, dynamic> j) => RemoteInvite(
        inviteId: '${j['invite_id'] ?? j['id']}',
        petId: '${j['pet_id']}',
        role: '${j['role'] ?? 'editor'}',
        petName: j['pet_name'] as String?,
        invitedAt: (j['invited_at'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['invited_at'] as num).toInt()),
      );
}

class SyncApi {
  SyncApi({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? '${AppRegion.current.apiBaseUrl}/api/v1';

  final http.Client _client;
  final String baseUrl;

  static const Duration _timeout = Duration(seconds: 15);

  // ---------------------------------------------------------------- 认证

  Future<CodeRequestResult> requestCode({
    required String channel,
    required String target,
  }) async {
    final j = await _post('/auth/code/request', {
      'channel': channel,
      'target': target,
    });
    return CodeRequestResult(
      sent: j['sent'] == true,
      expiresIn: (j['expires_in'] as num?)?.toInt(),
      devCode: j['dev_code'] as String?,
    );
  }

  /// 提交一条反馈。
  ///
  /// **只在用户主动点「提交」时调用**，不做自动上报 ——
  /// 自动上报会在用户毫不知情时把崩溃数据传出去，
  /// 那与隐私政策里「不做数据上报」的承诺冲突。
  ///
  /// 失败时抛 [SyncApiException]，由调用方决定怎么提示。
  /// 提交内容**不含任何账号信息**（没有手机号、没有宠物名），
  /// 崩溃上下文里只有 App 版本、区域、平台。
  Future<void> submitFeedback({
    required String message,
    String kind = 'manual',
    String? appVersion,
    String? region,
    String? platform,
    String? stack,
  }) async {
    await _post('/feedback', {
      'message': message,
      'kind': kind,
      if (appVersion != null) 'app_version': appVersion,
      if (region != null) 'region': region,
      if (platform != null) 'platform': platform,
      if (stack != null) 'stack': stack,
    });
  }

  Future<AuthSession> verifyCode({
    required String channel,
    required String target,
    required String code,
    required String deviceId,
  }) async {
    final j = await _post('/auth/code/verify', {
      'channel': channel,
      'target': target,
      'code': code,
      'device_id': deviceId,
    });
    return _sessionFrom(j);
  }

  /// 用官网账号令牌换一个宠物域令牌（**仅中国区**，A 方案）。
  ///
  /// 官网令牌是不透明随机串，宠物服务端自己验不了，只能拿它去问官网
  /// 「这是谁」，所以这一步由服务端做（`POST /auth/unified`）。客户端
  /// 只是把令牌递过去，**不解析、不保存**官网令牌 —— 它只在这一次
  /// 请求里存在。详见 server/app/unified.py 的模块注释。
  Future<AuthSession> exchangeUnified({
    required String unifiedToken,
    required String deviceId,
  }) async {
    final j = await _post('/auth/unified', {
      'unified_token': unifiedToken,
      'device_id': deviceId,
    });
    return _sessionFrom(j);
  }

  /// 手机号/邮箱 + 密码登录。密码是宠物域本地凭据，与官网统一账号无关：
  /// 官网本身没有密码（也是短信/微信登录），所以密码登录直接走宠物服务端
  /// 自己的 `/auth/password/login`，不经过官网换票。
  Future<AuthSession> passwordLogin({
    required String channel,
    required String target,
    required String password,
    required String deviceId,
  }) async {
    final j = await _post('/auth/password/login', {
      'channel': channel,
      'target': target,
      'password': password,
      'device_id': deviceId,
    });
    return _sessionFrom(j);
  }

  /// 设置或更换登录密码（需已登录）。首次验证码登录后引导调用。
  Future<void> setPassword({
    required String token,
    required String password,
  }) async {
    await _post('/auth/password/set', {'password': password}, token: token);
  }

  /// `/auth/code/verify` 与 `/auth/unified` 返回同一个会话形态，
  /// 共用一份解析，避免两边字段处理走偏（比如一边解析了 expires_at、
  /// 另一边忘了，于是「什么时候过期」在两个入口表现不一致）。
  static AuthSession _sessionFrom(Map<String, dynamic> j) => AuthSession(
        token: '${j['token']}',
        user: RemoteUser.fromJson((j['user'] as Map).cast<String, dynamic>()),
        expiresAt: (j['expires_at'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (j['expires_at'] as num).toInt(),
              ),
      );

  Future<void> logout(String token) async {
    await _post('/auth/logout', const {}, token: token);
  }

  Future<RemoteUser> me(String token) async {
    final j = await _get('/me', token: token);
    // 兼容 {user: {...}} 与直接返回用户对象两种形态。
    final body = (j['user'] as Map?)?.cast<String, dynamic>() ?? j;
    return RemoteUser.fromJson(body);
  }

  Future<RemoteUser> patchMe(
    String token, {
    String? nickname,
    String? phone,
    String? email,
    String? wechat,
    String? contactNote,
  }) async {
    final j = await _send('PATCH', '/me', {
      if (nickname != null) 'nickname': nickname,
      if (phone != null) 'phone': phone,
      if (email != null) 'email': email,
      if (wechat != null) 'wechat': wechat,
      if (contactNote != null) 'contact_note': contactNote,
    }, token: token);
    final body = (j['user'] as Map?)?.cast<String, dynamic>() ?? j;
    return RemoteUser.fromJson(body);
  }

  // ---------------------------------------------------------------- 同步

  /// 推送一批变更。返回「哪些被接受、哪些被拒」。
  ///
  /// 响应里只有 `[{table,row_id,result}]`，所以这里按 (table,row_id)
  /// 回查入参，还原成完整的 [SyncChange] —— 省掉服务端回传整个 payload。
  Future<PushResult> push({
    required String token,
    required String deviceId,
    required List<SyncChange> changes,
  }) async {
    if (changes.isEmpty) {
      return const PushResult(applied: [], rejected: []);
    }
    final j = await _post('/sync/push', {
      'device_id': deviceId,
      'changes': [for (final c in changes) c.toPushJson()],
    }, token: token);

    final byKey = {for (final c in changes) '${c.table}#${c.rowId}': c};
    final applied = <SyncChange>[];
    final rejected = <({SyncChange change, String reason})>[];

    for (final raw in (j['applied'] as List?) ?? const []) {
      final m = (raw as Map).cast<String, dynamic>();
      final c = byKey['${m['table']}#${m['row_id']}'];
      if (c != null) applied.add(c);
    }
    for (final raw in (j['rejected'] as List?) ?? const []) {
      final m = (raw as Map).cast<String, dynamic>();
      final c = byKey['${m['table']}#${m['row_id']}'];
      if (c != null) {
        rejected.add((change: c, reason: '${m['result'] ?? m['reason'] ?? 'rejected'}'));
      }
    }
    return PushResult(
      applied: applied,
      rejected: rejected,
      serverSeq: (j['server_seq'] as num?)?.toInt(),
    );
  }

  Future<PullResult> pull({
    required String token,
    required int since,
    int limit = 200,
  }) async {
    final j = await _get('/sync/pull?since=$since&limit=$limit', token: token);
    final changes = [
      for (final raw in (j['changes'] as List?) ?? const [])
        SyncChange.fromJson((raw as Map).cast<String, dynamic>()),
    ];
    return PullResult(
      changes: changes,
      nextSince: (j['next_since'] as num?)?.toInt() ?? since,
      hasMore: j['has_more'] == true,
    );
  }

  // ---------------------------------------------------------------- 共养

  Future<List<RemoteMember>> members(String token, String petId) async {
    final j = await _get('/pets/$petId/members', token: token);
    // 服务端可能返回 `{members: [...]}`，也可能直接是数组
    // （后者会被 _decode 包成 `{items: [...]}`）。
    final list = (j['members'] as List?) ?? (j['items'] as List?) ?? const [];
    return [
      for (final raw in list)
        RemoteMember.fromJson((raw as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> inviteMember(
    String token,
    String petId, {
    required String channel,
    required String target,
    required String role,
  }) async {
    await _post('/pets/$petId/members/invite', {
      'channel': channel,
      'target': target,
      'role': role,
    }, token: token);
  }

  Future<void> acceptInvite(String token, String inviteId) async {
    await _post('/members/invites/$inviteId/accept', const {}, token: token);
  }

  /// 我收到的待接受邀请。
  ///
  /// 这个接口不是可选的：被邀请人此时还不是 active 成员，pull 的可见性过滤
  /// 会把他自己那条 members 变更挡在外面，光靠同步他永远不知道被邀请了。
  Future<List<RemoteInvite>> myInvites(String token) async {
    final j = await _get('/members/invites/mine', token: token);
    final list = (j['invites'] as List?) ?? (j['items'] as List?) ?? const [];
    return [
      for (final raw in list)
        RemoteInvite.fromJson((raw as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> removeMember(String token, String petId, String userId) async {
    await _send('DELETE', '/pets/$petId/members/$userId', const {}, token: token);
  }

  // ---------------------------------------------------------------- 内部

  Map<String, String> _headers(String? token) => {
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _get(String path, {String? token}) async =>
      _decode(await _client
          .get(Uri.parse('$baseUrl$path'), headers: _headers(token))
          .timeout(_timeout));

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) =>
      _send('POST', path, body, token: token);

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'))
      ..headers.addAll(_headers(token))
      ..body = jsonEncode(body);
    final streamed = await _client.send(req).timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    return _decode(resp);
  }

  Map<String, dynamic> _decode(http.Response resp) {
    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SyncApiException(resp.statusCode, _errorMessage(body));
    }
    if (body.trim().isEmpty) return const {};
    final decoded = jsonDecode(body);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    // 少数接口直接返回数组（如成员列表）。
    return {'items': decoded};
  }

  /// FastAPI 的错误体是 `{"detail": "..."}`，但也可能是纯文本。
  static String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return '${decoded['detail']}';
      }
    } catch (_) {
      // 不是 JSON，按原文返回。
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}
