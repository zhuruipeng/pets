// ignore_for_file: avoid_print
//
// ↑ 这是命令行验证脚本：print 就是它把结果说给人听的方式，不是「生产代码里
//   忘删的调试输出」。avoid_print 针对的是 App 里的调试输出（那会把用户数据
//   写进 logcat，Release 包里也该用日志框架），这里的输出是脚本的对外接口本身。
//   同类的还有 verify_health_ledger.dart 与 probe_unified_account.dart。
//
//   之所以不干脆把 tool/ 从 analysis_options.yaml 里 exclude 掉：这些脚本里
//   也是有真逻辑的（内存 kv、搬迁分支、断言），排除掉就等于让它们彻底失去
//   静态检查 —— 为躲一条规则而关掉全部检查，不划算。
/// 令牌搬迁/登出/落盘的离线验证 —— **纯 Dart，不碰平台通道，也不用 Flutter**。
///
/// 跑法（本机 flutter test 跑不动：非提权必撞命名管道 231）：
///
///     E:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_token_migration.dart
///
/// 注意：**用 dart.exe 直接执行，不要用 `dart run`** —— 后者会先跑
/// build hooks（native assets），那一步 spawn 子进程，在本机照样撞 231。
/// 本脚本不依赖 sqlite，所以不需要 native assets。
///
/// 为什么要有这个脚本：令牌从 `sync_meta` 明文搬进系统密钥库这件事，
/// 真机上要 root 才能看到效果，`flutter test` 在本机又跑不起来。
/// 而这里三条最容易错的路径（搬迁、半截状态、清理）都能真跑：
///   SyncEngine 是**真的**，只有它依赖的三个外部世界是替身 ——
///   db（一个内存 kv）、密钥库（[MemoryTokenStore]）、网络（[_FakeApi]）。
///
/// 对应的 flutter test 版本在 test/token_store_test.dart，两边覆盖同一批分支。
/// 改这里或改那边，都要同步改另一份。
library;

import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// 内存版 kv 表，只实现 SyncEngine 碰 `sync_meta` 用到的那三个方法。
///
/// `implements Database` 会要求实现几十个成员；声明了 [noSuchMethod] 之后
/// Dart 就不再强制（成员调用会转发过去），所以没用到的方法一律抛 ——
/// **这是有意的**：万一以后 SyncEngine 用了新方法，脚本会立刻报出来，
/// 而不是悄悄用假实现算出个好看的结果。
class _MemDb implements Database {
  final Map<String, Map<String, Object?>> rows = {};

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final key = '${whereArgs?.first ?? ''}';
    final row = rows[key];
    return row == null ? const [] : [Map<String, Object?>.from(row)];
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final key = '${values['key']}';
    // 与 sqflite 的 ConflictAlgorithm.replace 行为对齐（主键相同则覆盖）。
    rows[key] = {'key': key, 'value': values['value']};
    return 1;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final key = '${whereArgs?.first ?? ''}';
    return rows.remove(key) == null ? 0 : 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('验证脚本没实现 Database.${invocation.memberName}');
}

/// 不打网络的 SyncApi：只记录「服务端撤销了哪个令牌」。
class _FakeApi extends SyncApi {
  _FakeApi({this.logoutFails = false}) : super(baseUrl: 'http://127.0.0.1:1');

  final bool logoutFails;
  final List<String> revoked = [];

  @override
  Future<void> logout(String token) async {
    if (logoutFails) throw StateError('网络不可达');
    revoked.add(token);
  }
}

/// 写不进去的密钥库，用来验证「写失败」这条分支。
class _FailingWriteStore extends MemoryTokenStore {
  @override
  Future<void> write(String token) async =>
      throw TokenStoreException('验证：密钥库不可用');
}

int _passed = 0;
int _failed = 0;

void check(bool ok, String what) {
  if (ok) {
    _passed++;
    print('  ok   $what');
  } else {
    _failed++;
    print('  FAIL $what');
  }
}

AuthSession _session(String token, {String userId = 'u-1'}) => AuthSession(
      token: token,
      user: RemoteUser(id: userId, nickname: '老板'),
    );

void main() async {
  print('令牌搬迁与清理 · 离线验证\n');

  // --- 1. 老库里的明文令牌 ---
  print('老版本遗留的明文令牌：');
  {
    final db = _MemDb();
    await db.insert('sync_meta', {'key': 'token', 'value': 'legacy-plain'});
    final store = MemoryTokenStore();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );

    check(await engine.token() == 'legacy-plain', '读得到老令牌');
    check(store.value == 'legacy-plain', '令牌落进了密钥库');
    check(!db.rows.containsKey('token'), '库里那行明文被删掉（不删等于白搬）');
    check(await engine.isLoggedIn(), '登录态判定为已登录');
  }

  // --- 2. 搬迁时密钥库不可用 ---
  print('\n搬迁时密钥库写不进去：');
  {
    final db = _MemDb();
    await db.insert('sync_meta', {'key': 'token', 'value': 'legacy-plain'});
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: _FailingWriteStore(),
      api: _FakeApi(),
    );

    check(await engine.token() == 'legacy-plain', '仍然返回老令牌（不把用户踢下线）');
    check(db.rows.containsKey('token'), '没搬成功就不删，留着下次再试');
  }

  // --- 3. 密钥库已有值 ---
  print('\n密钥库里已经有令牌：');
  {
    final db = _MemDb();
    await db.insert('sync_meta', {'key': 'token', 'value': 'stale-plain'});
    final store = MemoryTokenStore('secure-token');
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );

    check(await engine.token() == 'secure-token', '以密钥库为准，不被明文覆盖');
    check(store.value == 'secure-token', '密钥库里的值没被改');
  }

  // --- 4. 重新登录清掉遗留明文 ---
  print('\n迁移失败过、之后重新登录：');
  {
    final db = _MemDb();
    await db.insert('sync_meta', {'key': 'token', 'value': 'stale-plain'});
    final store = MemoryTokenStore();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );

    await engine.saveSession(_session('fresh'), accountRegion: 'cn');
    check(store.value == 'fresh', '新令牌落进密钥库');
    check(!db.rows.containsKey('token'), '遗留明文被顺手清掉（否则永远删不掉）');
  }

  // --- 5. 从没登录过 ---
  print('\n从没登录过：');
  {
    final db = _MemDb();
    final store = MemoryTokenStore();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );

    check(await engine.token() == null, '读不到令牌');
    check(!await engine.isLoggedIn(), '判定为未登录');
    check(store.value == null, '没有凭空写入密钥库');
    check(db.rows.isEmpty, '没有凭空写入数据库');
  }

  // --- 6. 正常登录 ---
  print('\n保存登录态：');
  {
    final db = _MemDb();
    final store = MemoryTokenStore();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );

    await engine.saveSession(_session('t-abc'), accountRegion: 'cn');
    check(store.value == 't-abc', '令牌进了密钥库');
    check(!db.rows.containsKey('token'), 'SQLite 里不再出现令牌');
    check(db.rows['account_id']?['value'] == 'u-1', '账号 id 照常写进库');
    check(db.rows['account_region']?['value'] == 'cn', '区域照常写进库');
    check(await engine.token() == 't-abc', '会话内读得到');
  }

  // --- 7. 写入失败不留半截状态 ---
  print('\n保存登录态时密钥库写失败：');
  {
    final db = _MemDb();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: _FailingWriteStore(),
      api: _FakeApi(),
    );

    var threw = false;
    try {
      await engine.saveSession(_session('t-abc'), accountRegion: 'cn');
    } on TokenStoreException {
      threw = true;
    }
    check(threw, '抛出 TokenStoreException（不静默降级）');
    check(!db.rows.containsKey('account_id'), '不留下「有账号没令牌」的半截状态');
  }

  // --- 8. 登出 ---
  print('\n登出：');
  {
    final db = _MemDb();
    await db.insert('sync_meta', {'key': 'token', 'value': 'stale-plain'});
    final store = MemoryTokenStore();
    final api = _FakeApi();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: api,
    );

    await engine.saveSession(_session('t-xyz'), accountRegion: 'cn');
    await engine.signOut();

    check(api.revoked.length == 1 && api.revoked.first == 't-xyz', '通知服务端撤销令牌');
    check(store.value == null, '密钥库清空');
    check(!db.rows.containsKey('token'), '遗留明文也没了');
    check(!await engine.isLoggedIn(), '判定为未登录');
    check(db.rows['account_id']?['value'] == 'u-1', '账号元数据保留（下次登录接着推）');
  }

  // --- 9. 离线登出 ---
  print('\n服务端不可达时登出：');
  {
    final db = _MemDb();
    final store = MemoryTokenStore();
    final engine = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(logoutFails: true),
    );

    await engine.saveSession(_session('t-xyz'), accountRegion: 'cn');
    await engine.signOut();

    check(store.value == null, '本地仍然退干净（不被卡在登录态里）');
    check(!await engine.isLoggedIn(), '判定为未登录');
  }

  // --- 10. 落盘真的持久 ---
  print('\n换一个引擎实例（丢掉内存缓存）：');
  {
    final db = _MemDb();
    final store = MemoryTokenStore();
    await SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    ).saveSession(_session('t-abc'), accountRegion: 'cn');

    final reopened = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );
    check(await reopened.token() == 't-abc', '新实例读得到上次存的令牌');
    check(await reopened.isLoggedIn(), '新实例判定为已登录');

    await reopened.signOut();
    final again = SyncEngine(
      dbProvider: () => db,
      tokenStore: store,
      api: _FakeApi(),
    );
    check(await again.token() == null, '登出后新实例读不到令牌');
  }

  print('\n结果：$_passed 项通过，$_failed 项失败');
  if (_failed > 0) throw StateError('有 $_failed 项断言未通过');
}
