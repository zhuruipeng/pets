/// 登录令牌的存放测试 —— 跑在内存 SQLite + 内存密钥库上，不碰平台通道。
///
/// 令牌从 `sync_meta` 明文搬到系统密钥库这件事，真正会出错的地方只有三个：
/// 1. **搬迁**：老用户库里那条明文有没有真的搬走、有没有真的删掉；
/// 2. **半截状态**：密钥库写失败时，能不能别留下「有账号、没令牌」的库；
/// 3. **清理**：登出、令牌失效之后，两处是不是都干净了。
///
/// 这三条在真机上都无法复现（要 root 才能看密钥库），所以只能靠这里的
/// [MemoryTokenStore] 把它们钉死。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_app/data/db/schema.dart';
import 'package:pet_app/data/sync/sync_api.dart';
import 'package:pet_app/data/sync/sync_engine.dart';
import 'package:pet_app/data/sync/token_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 建一个内存库，用生产 DDL（抄一份 DDL 迟早会漏掉新列）。
Future<Database> _memDb() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: kSchemaVersion,
      onCreate: (db, _) async {
        final batch = db.batch();
        for (final stmt in onCreate) {
          batch.execute(stmt);
        }
        await batch.commit(noResult: true);
      },
    ),
  );
}

/// 直接读 `sync_meta` 的某一项，用来断言「库里到底还留没留着明文令牌」。
Future<String?> _meta(Database db, String key) async {
  final rows = await db.query('sync_meta', where: 'key = ?', whereArgs: [key]);
  return rows.isEmpty ? null : rows.first['value'] as String?;
}

Future<void> _setMeta(Database db, String key, String value) async {
  await db.insert('sync_meta', {'key': key, 'value': value});
}

AuthSession _session(String token, {String userId = 'u-1'}) => AuthSession(
      token: token,
      user: RemoteUser(id: userId, nickname: '老板'),
    );

/// 不真的打网络的 [SyncApi]：只记录「服务端撤销了哪个令牌」。
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
      throw TokenStoreException('测试：密钥库不可用');
}

void main() {
  late Database db;

  setUp(() async => db = await _memDb());
  tearDown(() async => db.close());

  SyncEngine engineWith(TokenStore store, {SyncApi? api}) => SyncEngine(
        dbProvider: () => db,
        tokenStore: store,
        api: api ?? _FakeApi(),
      );

  group('明文令牌搬迁', () {
    test('老库里的 token 会被搬进密钥库，并从库里删掉', () async {
      // 老版本留下的状态：只有库里那一条明文。
      await _setMeta(db, 'token', 'legacy-plain-token');
      final store = MemoryTokenStore();

      final engine = engineWith(store);

      expect(await engine.token(), 'legacy-plain-token');
      expect(store.value, 'legacy-plain-token', reason: '必须落到密钥库里');
      expect(
        await _meta(db, 'token'),
        isNull,
        reason: '库里那行必须删掉，否则明文一直留着，等于白搬',
      );
      expect(await engine.isLoggedIn(), isTrue);
    });

    test('密钥库写失败时先继续用旧令牌，库里那行保留以便下次重试', () async {
      await _setMeta(db, 'token', 'legacy-plain-token');
      final engine = engineWith(_FailingWriteStore());

      expect(await engine.token(), 'legacy-plain-token', reason: '不能把用户踢下线');
      expect(
        await _meta(db, 'token'),
        'legacy-plain-token',
        reason: '没搬成功就不能删，否则令牌直接丢了',
      );
    });

    test('密钥库已经有令牌时，不看库里的遗留明文', () async {
      await _setMeta(db, 'token', 'stale-plain-token');
      final store = MemoryTokenStore('secure-token');

      final engine = engineWith(store);

      expect(await engine.token(), 'secure-token');
      expect(store.value, 'secure-token', reason: '不能反被明文覆盖');
    });

    test('重新登录后会顺手清掉遗留明文', () async {
      // 模拟「迁移失败过、之后用户重新登录」：库里一条明文，密钥库空。
      await _setMeta(db, 'token', 'stale-plain-token');
      final store = MemoryTokenStore();
      final engine = engineWith(store);

      await engine.saveSession(_session('fresh-token'), accountRegion: 'cn');

      expect(store.value, 'fresh-token');
      expect(
        await _meta(db, 'token'),
        isNull,
        reason: '这时候不删，那条明文就再也不会被读到、永远删不掉了',
      );
    });
  });

  group('登录态落盘', () {
    test('从没登录过时：没有令牌，也不会凭空写任何键', () async {
      final store = MemoryTokenStore();
      final engine = engineWith(store);

      expect(await engine.token(), isNull);
      expect(await engine.isLoggedIn(), isFalse);
      expect(store.value, isNull);
      expect(await _meta(db, 'token'), isNull);
    });

    test('saveSession 只把令牌写进密钥库，库里不再有 token 行', () async {
      final store = MemoryTokenStore();
      final engine = engineWith(store);

      await engine.saveSession(_session('t-abc'), accountRegion: 'cn');

      expect(store.value, 't-abc');
      expect(await _meta(db, 'token'), isNull, reason: 'SQLite 里不许再出现令牌');
      expect(await _meta(db, 'account_id'), 'u-1');
      expect(await _meta(db, 'account_region'), 'cn');
      expect(await engine.token(), 't-abc');
    });

    test('saveSession 在令牌落盘失败时会抛，且不留下半截账号状态', () async {
      final engine = engineWith(_FailingWriteStore());

      await expectLater(
        engine.saveSession(_session('t-abc'), accountRegion: 'cn'),
        throwsA(isA<TokenStoreException>()),
      );
      expect(
        await _meta(db, 'account_id'),
        isNull,
        reason: '「有 account_id 却没有令牌」的半截状态会让下次启动表现错乱',
      );
    });
  });

  group('登出与失效清理', () {
    test('登出：撤销服务端令牌、清空密钥库、遗留明文也没了', () async {
      await _setMeta(db, 'token', 'stale-plain-token');
      final store = MemoryTokenStore();
      final api = _FakeApi();
      final engine = engineWith(store, api: api);

      await engine.saveSession(_session('t-xyz'), accountRegion: 'cn');
      await engine.signOut();

      expect(api.revoked, ['t-xyz'], reason: '要通知服务端撤销');
      expect(store.value, isNull);
      expect(await _meta(db, 'token'), isNull);
      expect(await engine.isLoggedIn(), isFalse);
      expect(
        await _meta(db, 'account_id'),
        'u-1',
        reason: '只清登录态，不动账号元数据 —— 下次登录同账号要能接着推',
      );
    });

    test('服务端不可达也要能登出', () async {
      final store = MemoryTokenStore();
      final engine = engineWith(store, api: _FakeApi(logoutFails: true));

      await engine.saveSession(_session('t-xyz'), accountRegion: 'cn');
      await engine.signOut();

      expect(store.value, isNull, reason: '不能因为网络问题把用户卡在登录态里');
      expect(await engine.isLoggedIn(), isFalse);
    });

    test('登出后重新构造引擎，读到的也是未登录（真的落盘了）', () async {
      final store = MemoryTokenStore();
      final engine = engineWith(store);

      await engine.saveSession(_session('t-xyz'), accountRegion: 'cn');
      await engine.signOut();

      // 新实例 = 丢掉内存缓存，强制走一次真实的「从存储里读」。
      final reopened = engineWith(store);
      expect(await reopened.token(), isNull);
      expect(await reopened.isLoggedIn(), isFalse);
    });

    test('新实例能读到上一个实例存的令牌', () async {
      final store = MemoryTokenStore();
      await engineWith(store).saveSession(_session('t-abc'), accountRegion: 'cn');

      final reopened = engineWith(store);
      expect(await reopened.token(), 't-abc');
      expect(await reopened.isLoggedIn(), isTrue);
    });
  });

  group('内存密钥库自身', () {
    test('write 之后 read 拿到同一个值，clear 之后读不到', () async {
      final store = MemoryTokenStore();
      await store.write('x');
      expect(await store.read(), 'x');
      await store.clear();
      expect(await store.read(), isNull);
    });
  });
}
