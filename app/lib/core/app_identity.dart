/// 中国区合规标识：App 备案号。
///
/// 备案号是**与登记信息逐字一致**的字符串，不能美化、不能省略后缀 ——
/// 工信部抽查比的就是这个字符串与商店后台填的是否一致。
///
/// ⚠️ 以下任一变更都要走「变更备案」并同步改这里：
/// 应用显示名、包名、签名证书、域名/服务器、主体信息。
library;

class AppIdentity {
  const AppIdentity._();

  /// APP 备案号（不是网站备案号，两者不通用）。
  ///
  /// 主体 `鲁ICP备2026031884号` 下：网站 `weiyuantool.com` 是 `-2`，
  /// 本 App 是第 5 个服务，故后缀为 `-5A`（`A` = APP，数字 = 服务序号）。
  /// 商店后台（App Store / 华为 / 小米 / OPPO / vivo / 应用宝）填的也是这一串。
  static const String icpAppNumber = '鲁ICP备2026031884号-5A';

  /// 备案号必须可点击跳转到工信部备案系统，供用户核验。
  static const String icpQueryUrl = 'https://beian.miit.gov.cn';
}
