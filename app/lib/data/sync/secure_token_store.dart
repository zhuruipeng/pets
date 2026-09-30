/// 令牌的真机实现：Android Keystore / iOS Keychain。
///
/// 单独一个文件的原因见 token_store.dart 的文件头 —— 这个文件依赖
/// flutter_secure_storage，一旦被 [SyncEngine] 直接引用，
/// 引擎就没法在纯 Dart 下跑验证了。所以它只由 providers.dart 引用一次。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_store.dart';

class SecureTokenStore implements TokenStore {
  /// 允许注入，方便将来做端到端自检；正常调用不传。
  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  /// 存储键。**发布之后不能再改** —— 改了等于所有老用户掉登录。
  static const String storageKey = 'pet_auth_token';

  /// 用插件的默认配置，不传 options：
  /// - Android（v10 起）：密钥 RSA-OAEP 包裹 + AES-GCM 存值，密钥在 Keystore 里不可导出；
  /// - iOS：走 Keychain，默认 accessibility = 设备解锁后可读。
  ///
  /// 默认值够用是因为**本 App 只在前台读写令牌**（同步由前台生命周期与手动按钮触发）。
  /// 以后若加了后台同步（WorkManager / BGTask），要在锁屏状态下读 Keychain，
  /// 那时才需要改成 `IOSOptions(accessibility: KeychainAccessibility.first_unlock)`。
  /// 现在不写，是因为那套 options API 在插件大版本之间改过形状，
  /// 为一个用不到的场景去绑定具体版本的构造签名，不划算。
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    try {
      final value = await _storage.read(key: storageKey);
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      // 读失败一律当「未登录」，**不往上抛**。
      //
      // 最主要的原因不是设备坏了，而是**云备份还原**：Android 自动备份会
      // 把 SharedPreferences 里的密文搬到新手机，但解开它的 Keystore 密钥
      // 没有跟着搬（密钥本就设计成不可导出）。于是新机上每次解密都失败。
      //
      // 之所以在这里咽掉：抛出去的表现是「App 一打开就崩」，
      // 用户连重新登录的机会都没有。咽掉之后是一次干净的「请登录」。
      //
      // 配套动作是把密文从备份里排除掉，见
      // android/app/src/main/res/xml/{backup_rules,data_extraction_rules}.xml。
      return null;
    }
  }

  @override
  Future<void> write(String token) async {
    try {
      await _storage.write(key: storageKey, value: token);
    } catch (e) {
      throw TokenStoreException('无法把登录令牌写入系统密钥库', e);
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: storageKey);
    } catch (_) {
      // 删不掉不等于退不出去，所以不抛：
      // 1. 调用方 SyncEngine.signOut 已经先让服务端撤销了令牌；
      // 2. 万一那次撤销也没发出去（离线登出），残留的本地密文一旦被使用
      //    只会拿到 401，而 401 会把本地登录态清干净（见 SyncEngine.sync）。
      // 抛出去的坏处是确定的：用户点了「退出登录」却被卡在登录态里出不来。
    }
  }
}
