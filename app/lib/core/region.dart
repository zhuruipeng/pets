/// 双市场区域配置 —— 全项目唯一的区域判断入口。
///
/// 约定：业务代码只允许读 [AppRegion.current] 及其扩展属性，
/// 不允许在任何其它文件里出现 region 相关的 if/else 判断。
/// 新增区域差异时，在本文件加一个 getter。
library;

/// 区域枚举。
///
/// [cn]   中国大陆：应用商店备案、无地图底图渲染、公制单位。
/// [intl] 海外：GDPR / CCPA、可用地图渲染、英制或公制按 locale。
enum Region { cn, intl }

/// 编译期注入的区域，由 --dart-define=REGION=cn|intl 决定。
///
/// 默认 intl，保证不带参数直接 `flutter run` 时也能跑起来。
class AppRegion {
  AppRegion._();

  static const String _raw =
      String.fromEnvironment('REGION', defaultValue: 'intl');

  static const Region current = _raw == 'cn' ? Region.cn : Region.intl;

  static bool get isCn => current == Region.cn;
  static bool get isIntl => current == Region.intl;
}

/// 各区域的行为差异，集中在这里。
extension RegionBehavior on Region {
  /// 后端基址。两个区域独立部署，数据不出境。
  String get apiBaseUrl => switch (this) {
        Region.cn => const String.fromEnvironment(
            'API_BASE_CN',
            defaultValue: 'https://api.pet.weiyuantool.com',
          ),
        Region.intl => const String.fromEnvironment(
            'API_BASE_INTL',
            defaultValue: 'https://api.pet.example.com',
          ),
      };

  /// 是否渲染地图底图。
  ///
  /// 中国境内地图展示涉及测绘资质，MVP 决定国内版不渲染底图，
  /// 只记录经纬度并展示地址文本 + 自绘轨迹折线。
  /// 详见产品结构文档 7.3。
  bool get mapRenderingEnabled => this == Region.intl;

  /// 统一账号（出岫）的地址。**null 表示本区域用自有账号体系**。
  ///
  /// 中国区登录走官网账号（A 方案，见 docs/账号体系复用.md）：与官网的
  /// ERP / 商城 / AI 修图共用同一个手机号，用户不必再记一个账号，我们也
  /// 不必自己接短信通道与模板报备。
  ///
  /// 用 nullable 而不是「布尔 + 另一处地址」是为了让调用方写成
  /// `if (base != null)`，而不是在业务代码里判断区域 —— 那正是本文件
  /// 开头禁止的事情。海外区没有出岫账号，也不能把用户数据送到中国节点，
  /// 所以这里是 null。
  ///
  /// ⚠️ **必须带 `www.`，这不是笔误。** 裸域 `weiyuantool.com` 对**所有**
  /// 请求（含 POST）返回 301 到 `www.weiyuantool.com`，而 Dart 的
  /// `HttpClient` 对非 GET 的 301 **不会自动跟随** —— 客户端拿到的是 nginx
  /// 那张 `301 Moved Permanently` 的 HTML 页，不是 JSON。
  /// 已验证（`dart tool/probe_unified_account.dart`）：
  /// 裸域 → `status=301`、无重定向记录、body 是 HTML；
  /// www  → `status=400 {"detail":"请输入正确的中国大陆手机号"}`（请求完好到达）。
  /// 配错的表现是「验证码永远发不出去，提示 error (301)」，
  /// 排查时很难联想到域名。
  String? get unifiedAccountBaseUrl => switch (this) {
        Region.cn => const String.fromEnvironment(
            'UNIFIED_ACCOUNT_BASE',
            defaultValue: 'https://www.weiyuantool.com',
          ),
        Region.intl => null,
      };

  /// 默认重量单位（用户仍可在设置里手动切换）。
  /// 美国习惯磅，其余海外地区多用公斤。
  bool get defaultUseImperial => this == Region.intl;

  /// 是否需要在 App 内展示备案号（中国区合规要求）。
  bool get requiresIcpDisplay => this == Region.cn;

  /// 逆地理编码服务商标识，供 Geocoder 工厂选择实现。
  String get geocoderVendor => switch (this) {
        Region.cn => 'amap',
        Region.intl => 'mapbox',
      };

  /// 免疫规则集版本，供免疫计划生成使用。
  String get immunizationRuleSet => switch (this) {
        Region.cn => 'cn',
        Region.intl => 'intl',
      };
}
