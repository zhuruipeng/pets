/// 多设备同步引擎。
///
/// 策略部分（先推后拉、LWW 合并、回环抑制）都在这里，网络细节在 [SyncApi]。
/// 这样拆是为了让策略能脱离网络单测。
///
/// 完整流程与取舍见 docs/同步协议.md 第七节。三处最容易错的地方，
/// 在下面各自的位置都写了原因：
/// 1. **必须先 push 后 pull**（否则自己的改动会被远端旧值覆盖一次）
/// 2. **应用远端变更期间要置 applying 标志**（否则无限推拉循环）
/// 3. **被拒的变更也要从 outbox 删掉**（否则队列永远卡在那一条上）
library;

import 'dart:convert';

// 注意这里引的是**接口包**（sqflite_common），不是 package:sqflite。
// 后者会把 Flutter 的 dart:ui 拖进 import 图，本文件就再也不能用
// `dart tool/verify_token_migration.dart` 单独跑起来了 ——
// 而本机 `flutter test` 跑不动（非提权必撞命名管道 231），
// 那样这段策略代码就只能靠肉眼审。类型是同一个（sqflite 直接 re-export 它），
// 所以 providers 里传 sqflite 的 Database 进来完全兼容。
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'sync_api.dart';
import 'token_store.dart';

/// 哪些表参与同步。与 schema.dart 的 kSyncedTables 一致 ——
/// 那边决定「谁产生变更」，这边决定「谁能被应用」。
const List<String> kSyncableTables = [
  'users',
  'pets',
  'members',
  'records',
  'attachments',
  'reminders',
  'reminder_logs',
  'expenses',
  'walk_sessions',
];

/// 一次同步的结果。
class SyncReport {
  const SyncReport({
    required this.pushed,
    required this.pulled,
    required this.rejected,
    this.error,
  });

  final int pushed;
  final int pulled;

  /// 被服务端拒掉的条数（stale / forbidden）。
  final int rejected;

  /// 出错时的原因。**同步失败不弹窗**，只记在这里给设置页看。
  final Object? error;

  bool get ok => error == null;

  static const SyncReport skipped =
      SyncReport(pushed: 0, pulled: 0, rejected: 0);
}

/// 同步状态。UI 据此显示「同步中 / 上次同步时间 / 出错」。
enum SyncPhase { idle, syncing, offline, notLoggedIn, error }

class SyncEngine {
  /// [dbProvider] 与 [tokenStore] 都**必填、不给默认值**，这是有意的。
  ///
  /// 它们的默认值只能写成 `() => AppDatabase.instance.db` 与
  /// `SecureTokenStore()`，那是两个 Flutter 插件（path_provider、
  /// flutter_secure_storage），一旦写进本文件，引擎就再也没法用
  /// `dart tool/xxx.dart` 单独跑起来了 —— 而本机 `flutter test` 跑不动
  /// （非提权必撞命名管道 231），等于把这段策略代码变成只能靠肉眼审。
  ///
  /// 现在由调用方（providers.dart）注入，本文件保持纯 Dart，
  /// 见 tool/verify_token_migration.dart。
  SyncEngine({
    required Database Function() dbProvider,
    required TokenStore tokenStore,
    SyncApi? api,
  })  : _api = api ?? SyncApi(),
        _dbProvider = dbProvider,
        _tokens = tokenStore;

  final SyncApi _api;
  final Database Function() _dbProvider;

  /// 令牌不去 SQLite，走系统密钥库。理由见 token_store.dart 的文件头。
  ///
  /// 可注入是为了测试 —— 平台通道在 `flutter test` 里不存在。
  final TokenStore _tokens;

  /// 老版本把令牌明文存在这个 key 下。**已废弃**，只在迁移时读一次。
  static const String _legacyTokenKey = 'token';

  /// 令牌的内存缓存。读一次要过一次平台通道（跨进程），
  /// 而设置页刷新一次就可能连问好几遍。
  bool _tokenLoaded = false;
  String? _cachedToken;

  static const _uuid = Uuid();

  /// 每批推送条数。太大容易在弱网下半途失败、整批重来。
  static const int _pushBatch = 200;

  /// pull 的分页上限（服务端上限 500，取小一点让进度可见）。
  static const int _pullLimit = 200;

  /// 防止并发同步：定时器、前台恢复、手动按钮可能同时触发。
  bool _running = false;

  Database get _db => _dbProvider();

  // ---------------------------------------------------------------- 元数据

  Future<String?> _meta(String key) async {
    final rows = await _db.query('sync_meta',
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> _setMeta(String key, String? value) async {
    if (value == null) {
      await _db.delete('sync_meta', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _db.insert(
      'sync_meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 本机设备 id。首次调用时生成并持久化 —— 服务端用它区分设备
  /// （目前只用于排查，不做 per-device 冲突）。
  Future<String> deviceId() async {
    final existing = await _meta('device_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _uuid.v4();
    await _setMeta('device_id', id);
    return id;
  }

  Future<bool> isLoggedIn() async {
    final t = await _readToken();
    return t != null && t.isNotEmpty;
  }

  /// 当前令牌。没有就是没登录。
  Future<String?> token() => _readToken();

  // ---- 令牌的读写 ----
  //
  // 令牌放在系统密钥库（Android Keystore / iOS Keychain），**不在 sync_meta 里**。
  // 老版本存在库里，所以第一次读要做一次搬迁，见 [_migrateLegacyToken]。

  Future<String?> _readToken() async {
    if (_tokenLoaded) return _cachedToken;
    var value = await _tokens.read();
    value ??= await _migrateLegacyToken();
    _cachedToken = value;
    _tokenLoaded = true;
    return value;
  }

  /// 把老版本留在 `sync_meta.token` 里的明文令牌搬进密钥库。
  ///
  /// 只在密钥库为空时才会走到这儿，所以「密钥库已有令牌」的正常路径上
  /// 它根本不执行 —— 也就没有每次启动都查一次库的开销。
  ///
  /// 搬完**必须删掉库里那一行**：不删等于明文一直留着，白搬一趟。
  Future<String?> _migrateLegacyToken() async {
    final legacy = await _meta(_legacyTokenKey);
    if (legacy == null || legacy.isEmpty) return null;
    try {
      await _tokens.write(legacy);
    } catch (_) {
      // 搬不动就先用着，**不删库里的行**（下次启动再试）。
      // 这里把「迁不过去」和「把用户踢下线」放在一起比：明文本来就在哪儿躺着，
      // 早一刻删掉它不会让情况变好，但用户会莫名其妙掉一次登录。
      return legacy;
    }
    await _setMeta(_legacyTokenKey, null);
    return legacy;
  }

  /// 清掉令牌（登出、或服务端说令牌失效）。
  ///
  /// 顺手也清一次废弃的 `sync_meta.token` —— 迁移失败过的机器上，
  /// 那行明文会留在库里，只清密钥库的话，下次启动又会把它迁回来。
  Future<void> _clearToken() async {
    await _tokens.clear();
    await _setMeta(_legacyTokenKey, null);
    _cachedToken = null;
    _tokenLoaded = true;
  }

  Future<DateTime?> lastSyncAt() async {
    final raw = await _meta('last_sync_at');
    final ms = int.tryParse(raw ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 有没有待推送的变更。用于「是否值得发一次同步」的判断 ——
  /// 定时器每次都打网络是浪费电和流量。
  Future<int> pendingCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM sync_outbox');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  // ---------------------------------------------------------------- 登录态

  /// 保存登录态。
  ///
  /// **先落令牌再写账号元数据**，顺序不能反：令牌写进密钥库可能失败
  /// （会抛 [TokenStoreException]），那时元数据要是已经写下去了，
  /// 库里就留下「有 account_id、没有可用令牌」的半截状态，
  /// 下次启动会以「未登录但有账号」的样子出现。
  Future<void> saveSession(AuthSession session,
      {required String accountRegion}) async {
    await _tokens.write(session.token);
    _cachedToken = session.token;
    _tokenLoaded = true;
    // 顺手再清一次废弃的明文行。**不能省**：如果这台机器当初迁移失败过，
    // 密钥库里没值、库里留着一条明文；用户现在重新登录，密钥库有了值，
    // 那条明文就再也不会被读、也就永远删不掉了 —— 等于明文一直躺在库里。
    await _setMeta(_legacyTokenKey, null);
    await _setMeta('account_id', session.user.id);
    await _setMeta('account_region', accountRegion);
  }

  Future<void> signOut() async {
    final t = await _readToken();
    if (t != null) {
      try {
        await _api.logout(t);
      } catch (_) {
        // 服务端不可达也要允许本地退出 —— 否则用户被卡在登录态里出不来。
        // 本地清干净后，万一服务端那份令牌还活着，它也只是个用不到的孤儿：
        // 客户端手里没有它了。
      }
    }
    // 只清登录态，**不动 outbox 与 last_seq**：
    // 下次登录同一个账号能接着推，不用从头再来。
    await _clearToken();
  }

  // ---------------------------------------------------------------- 同步

  /// 跑一次完整同步。任何异常都被兜住并写进 [SyncReport.error]。
  Future<SyncReport> sync() async {
    if (_running) return SyncReport.skipped;
    _running = true;
    try {
      final t = await token();
      if (t == null || t.isEmpty) return SyncReport.skipped;

      var pushed = 0;
      var rejected = 0;
      try {
        final device = await deviceId();
        final push = await _pushAll(t, device);
        pushed = push.$1;
        rejected = push.$2;
      } on SyncApiException catch (e) {
        // token 失效：清掉，让 UI 回到「未登录」。这不是错误，是正常状态。
        if (e.isUnauthorized) {
          await _clearToken();
          return SyncReport(
              pushed: pushed, pulled: 0, rejected: rejected, error: e);
        }
        rethrow;
      }

      final pulled = await _pullAll(t);
      await _setMeta(
          'last_sync_at', '${DateTime.now().millisecondsSinceEpoch}');

      return SyncReport(pushed: pushed, pulled: pulled, rejected: rejected);
    } on SyncApiException catch (e) {
      // pull 也可能在令牌过期后返回 401，不能只在 push 阶段清登录态。
      if (e.isUnauthorized) await _clearToken();
      return SyncReport(pushed: 0, pulled: 0, rejected: 0, error: e);
    } catch (e) {
      return SyncReport(pushed: 0, pulled: 0, rejected: 0, error: e);
    } finally {
      _running = false;
    }
  }

  /// 推完全部 outbox。返回 (成功条数, 被拒条数)。
  ///
  /// **先推后拉**：反过来的话，会先把远端的旧版本拉下来覆盖本地的新改动，
  /// 再把自己的改动推上去 —— 等于自己这次的编辑白做了一次。
  Future<(int, int)> _pushAll(String token, String device) async {
    var applied = 0;
    var rejected = 0;

    // 循环直到 outbox 空：推送过程中可能又有新写入（比如用户还在记东西）。
    for (var round = 0; round < 50; round++) {
      final changes = <SyncChange>[];
      // 队列和快照一起读取，避免二者之间的编辑产生时间戳/载荷不一致。
      final batchSize = await _db.transaction((txn) async {
        final rows = await txn.query('sync_outbox',
            orderBy: "CASE table_name WHEN 'users' THEN 0 WHEN 'pets' THEN 0 "
                "WHEN 'reminders' THEN 1 WHEN 'records' THEN 2 "
                "WHEN 'attachments' THEN 3 WHEN 'reminder_logs' THEN 4 ELSE 2 END, updated_at ASC",
            limit: _pushBatch);
        for (final row in rows) {
          final c = await _snapshot(row, executor: txn);
          if (c != null) {
            changes.add(c);
          } else {
            // 只清当前失效条目，后面的批次可能仍有有效数据。
            await txn.delete('sync_outbox',
                where: 'table_name = ? AND row_id = ?',
                whereArgs: [row['table_name'], row['row_id']]);
          }
        }
        return rows.length;
      });
      if (batchSize == 0) break;
      if (changes.isEmpty) continue;

      final result = await _api.push(
        token: token,
        deviceId: device,
        changes: changes,
      );
      applied += result.applied.length;
      rejected += result.rejected.length;

      // **被拒的也要删**：`stale` 表示服务端已有更新版本，本地这条推不上去，
      // 留着只会每轮重推一次；`forbidden` 是权限问题，重推一万次也一样。
      // 都删掉，然后由随后的 pull 把服务端那份正确数据拉回来。
      final acknowledged = [
        ...result.applied,
        ...result.rejected.map((r) => r.change)
      ];
      await _db.transaction((txn) async {
        for (final c in acknowledged) {
          final pending = await txn.query('sync_outbox',
              where: 'table_name = ? AND row_id = ?',
              whereArgs: [c.table, c.rowId]);
          if (pending.isEmpty) continue;
          final current = await _snapshot(pending.single, executor: txn);
          // 上传时用户可能又改了同一行，甚至发生在同一毫秒。
          // 只有队列仍对应刚发送的完整快照时，旧响应才能清掉它。
          if (current == null ||
              jsonEncode(current.toPushJson()) == jsonEncode(c.toPushJson())) {
            await txn.delete('sync_outbox',
                where: 'table_name = ? AND row_id = ?',
                whereArgs: [c.table, c.rowId]);
          }
        }
      });

      // 拒绝也是已处理的响应，继续下一批；没有任何确认才停止空转。
      if (acknowledged.isEmpty) break;
    }
    return (applied, rejected);
  }

  /// 把 outbox 的一行还原成完整变更（含行快照）。
  ///
  /// 返回值需要 `pet_id` 与 `points`：前者服务端用来判可见性，后者是
  /// 轨迹点随 session 一起传的约定（见协议第三节）。
  Future<SyncChange?> _snapshot(Map<String, dynamic> outboxRow,
      {required DatabaseExecutor executor}) async {
    final table = outboxRow['table_name'] as String;
    final rowId = outboxRow['row_id'] as String;
    if (!kSyncableTables.contains(table)) return null;

    final rows = await executor.query(table,
        where: 'id = ?', whereArgs: [rowId], limit: 1);
    if (rows.isEmpty) return null;
    final payload = Map<String, dynamic>.from(rows.first);

    if (table == 'attachments') {
      // 附件归属只在 outbox 中，本地表没有 pet_id；服务端需从载荷判权限。
      if (payload['local_only'] == 1) return null;
      payload['pet_id'] = outboxRow['pet_id'];
    }

    if (table == 'walk_sessions') {
      final points = await executor.query(
        'walk_points',
        where: 'session_id = ?',
        whereArgs: [rowId],
        orderBy: 'recorded_at ASC',
      );
      payload['points'] = [
        for (final p in points)
          {
            'lat': p['lat'],
            'lng': p['lng'],
            if (p['altitude'] != null) 'altitude': p['altitude'],
            if (p['accuracy'] != null) 'accuracy': p['accuracy'],
            'recorded_at': p['recorded_at'],
          },
      ];
    }

    return SyncChange(
      table: table,
      rowId: rowId,
      op: (outboxRow['op'] as String?) ?? 'upsert',
      petId: outboxRow['pet_id'] as String?,
      updatedAt: (outboxRow['updated_at'] as num?)?.toInt(),
      payload: payload,
    );
  }

  /// 拉到看到的最末。返回应用条数。
  Future<int> _pullAll(String token) async {
    var since = int.tryParse(await _meta('last_seq') ?? '') ?? 0;
    var appliedCount = 0;

    for (var round = 0; round < 200; round++) {
      final result =
          await _api.pull(token: token, since: since, limit: _pullLimit);
      if (result.changes.isNotEmpty) {
        appliedCount += await _applyRemote(result.changes);
      }
      // 即使没有变更也要落游标：服务端会在空页时返回当前最大 seq，
      // 存下来下次就不用从头扫。
      since = result.nextSince;
      await _setMeta('last_seq', '$since');
      if (!result.hasMore) break;
    }
    return appliedCount;
  }

  /// 应用远端变更：逐条 LWW 比较，更新的才写。
  ///
  /// 整段包在 `applying = 1` 里，让 outbox 触发器哑火 —— 否则刚应用完
  /// 就又变成待推送变更，推上去、再拉下来，无限循环。
  Future<int> _applyRemote(List<SyncChange> changes) async {
    var n = 0;
    await _db.transaction((txn) async {
      await txn.insert(
        'sync_meta',
        {'key': 'applying', 'value': '1'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final c in changes) {
        if (!kSyncableTables.contains(c.table)) continue;
        final ok = await _applyOne(txn, c);
        if (ok) n++;
      }

      await txn.delete('sync_meta', where: 'key = ?', whereArgs: ['applying']);
    });
    return n;
  }

  Future<bool> _applyOne(DatabaseExecutor txn, SyncChange c) async {
    final payload = Map<String, dynamic>.from(c.payload);
    payload.remove('points'); // 轨迹点是子资源，单独处理
    if (c.table == 'attachments') payload.remove('pet_id');

    // 本地现有的 updated_at，用来判新旧。
    final local = await txn.query(
      c.table,
      columns: ['updated_at'],
      where: 'id = ?',
      whereArgs: [c.rowId],
      limit: 1,
    );
    final localUpdatedAt =
        local.isEmpty ? null : (local.first['updated_at'] as num?)?.toInt();
    final remoteUpdatedAt =
        c.updatedAt ?? (payload['updated_at'] as num?)?.toInt() ?? c.seq;
    // The server keeps the first completion of an occurrence. Its canonical
    // timestamp can be older than this device's duplicate offline completion.
    final isCompletion = c.table == 'reminder_logs' ||
        (c.table == 'records' && c.rowId.startsWith('dose_') && c.op == 'upsert');
    final pending = isCompletion ? await txn.query('sync_outbox',
        where: 'table_name = ? AND row_id = ?', whereArgs: [c.table, c.rowId], limit: 1) : null;
    final canonicalCompletion = isCompletion && pending!.isEmpty;

    // 远端不比本地新就跳过。**不抛异常、不记录**：这是正常情况
    // （同一行两处都改过，本地那份更新）。
    if (!canonicalCompletion && localUpdatedAt != null &&
        remoteUpdatedAt != null &&
        remoteUpdatedAt <= localUpdatedAt) {
      return false;
    }

    if (local.isEmpty) {
      payload['id'] = c.rowId;
      // 远端推来的行可能缺列（对面设备 schema 更旧）。用 REPLACE 补齐，
      // 缺的列会是 NULL —— 这些列在对面本来也是空的。
      await txn.insert(c.table, payload,
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      // **用 update 而不是 REPLACE**：REPLACE 是「删了重插」，
      // payload 里没有的列会被清成 NULL。比如对面推 pets 时没带图片字段，
      // REPLACE 会把本地头像抹掉。
      payload.remove('id');
      if (payload.isNotEmpty) {
        await txn
            .update(c.table, payload, where: 'id = ?', whereArgs: [c.rowId]);
      }
    }

    if (c.table == 'walk_sessions') {
      final points = c.payload['points'];
      if (points is List) {
        await txn.delete('walk_points',
            where: 'session_id = ?', whereArgs: [c.rowId]);
        for (final raw in points) {
          final p = (raw as Map).cast<String, dynamic>();
          await txn.insert(
            'walk_points',
            {
              'id': '${c.rowId}_${p['recorded_at']}',
              'session_id': c.rowId,
              'lat': p['lat'],
              'lng': p['lng'],
              if (p['altitude'] != null) 'altitude': p['altitude'],
              if (p['accuracy'] != null) 'accuracy': p['accuracy'],
              'recorded_at': p['recorded_at'],
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    }
    return true;
  }

  /// 把本地联系方式推给服务端（`PATCH /me` 是即时接口，不进 outbox 批量）。
  Future<void> pushContact({
    String? phone,
    String? email,
    String? wechat,
    String? contactNote,
  }) async {
    final t = await token();
    if (t == null) return;
    await _api.patchMe(
      t,
      phone: phone,
      email: email,
      wechat: wechat,
      contactNote: contactNote,
    );
  }

  /// 调试用：把 outbox 清空（例如服务端数据被重置之后）。
  Future<void> clearOutbox() async {
    await _db.delete('sync_outbox');
  }

  /// 调试用：把游标归零，下次同步从头拉。
  Future<void> resetCursor() async {
    await _setMeta('last_seq', null);
  }

  /// 让调用方（测试）能拿到 JSON 编码后的快照大小，用于评估批大小。
  static int snapshotBytes(SyncChange c) =>
      utf8.encode(jsonEncode(c.payload)).length;
}
