/// 登录令牌的存放位置 —— **只有接口**，不含任何平台实现。
///
/// **为什么不能放 SQLite**：`sync_meta` 落在应用私有目录的明文库文件里。
/// root 过的手机、`adb backup`、各种「手机搬家 / 清理大师」都能把它整份读走 ——
/// 里面就一条 `Authorization: Bearer <token>`，拿到就是完整的冒充凭证。
/// 令牌是唯一凭证（不是 JWT，服务端随时可撤销），必须交给系统级密钥库。
///
/// **为什么接口和实现要分成两个文件**：密钥库实现
/// （[SecureTokenStore]，见 secure_token_store.dart）依赖
/// flutter_secure_storage，而那个包会 import `package:flutter` →
/// `dart:ui`。只要它在 import 图里，[SyncEngine] 就没有任何办法用
/// `dart tool/xxx.dart` 单独跑起来；而本机 `flutter test` 是跑不动的
/// （非提权必撞命名管道 231）。
///
/// 于是拆成两半：
/// - 本文件：接口 + 内存实现，**纯 Dart**，验证脚本可以直接用；
/// - secure_token_store.dart：真机实现，只被 providers.dart 引用。
///
/// 这也让「测试要注入内存实现」这件事变成接口的自然用法，
/// 而不是为了测试在生产代码里开后门。
library;

/// 令牌写不进安全存储时抛这个。
///
/// **不静默降级**：写失败却说登录成功，用户下次启动会莫名其妙掉登录，
/// 而且这种现象在测试里永远复现不了。宁可当场把失败说出来。
class TokenStoreException implements Exception {
  TokenStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'TokenStoreException: $message'
      : 'TokenStoreException: $message（$cause）';
}

/// 令牌的读写口子。真机用 `SecureTokenStore`，测试与离线验证用 [MemoryTokenStore]。
abstract class TokenStore {
  /// 读不到（没登录 / 解密失败）返回 null，**不抛异常**。
  Future<String?> read();

  /// 写入失败抛 [TokenStoreException]。
  Future<void> write(String token);

  /// 删除。**失败不抛** —— 见 secure_token_store.dart 里实现的说明。
  Future<void> clear();
}

/// 内存实现，**只给测试和离线验证脚本用**。
///
/// 生产环境用它没有任何意义 —— 令牌重启即失效，且完全没加密。
class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this._value]);

  String? _value;

  /// 当前存着的值，测试里断言「确实存进去了 / 确实被删了」。
  String? get value => _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String token) async => _value = token;

  @override
  Future<void> clear() async => _value = null;
}
