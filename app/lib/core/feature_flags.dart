/// 功能开关 —— 已经写好但还没到发布条件的模块，从这里统一关闭。
///
/// 用法约定：
/// - 开关是 `const bool`，让 Dart 的 tree-shake 把关掉的代码整块丢掉，
///   死代码不会进包体，也不需要担心「关了但还在跑」。
/// - 每个开关必须写清楚**为什么关**和**什么条件下打开**，
///   否则半年后没人敢动，就变成永久注释掉了。
/// - 只允许 UI 入口读开关；数据层（repository / migration）不要读。
///   数据库里已经存的数据不能因为开关来回跳。
library;

/// 遛狗：GPS 轨迹采集尚未接入。
///
/// **为什么关**：`geolocator` 目前零引用 —— 没有任何代码往 `walk_points`
/// 写轨迹点，`endSession` 用 `totalDistanceM(points)` 算出来的距离恒为 0。
/// 也就是说现在跑一趟遛狗，结果页永远显示 0.0 km，用户只会当成 bug。
///
/// **什么时候开**：第三批 Task 10。接入 `positionStream` → 批量写点 →
/// 50m 漂移过滤之后，把这里改成 true，同时补一条「距离非 0」的集成测试。
///
/// 关掉期间代码一行不删，schema / model / repository / 迁移测试全部保留。
const bool kWalkEnabled = false;

/// 苹果小组件：尚未实现 WidgetKit 扩展和共享数据容器。
/// 接入原生扩展、验证同步与隐私展示后才能打开。
const bool kIosWidgetsEnabled = false;

/// 苹果快捷指令：尚未实现原生 App Intents 桥接。
/// 完成动作权限检查、重复执行保护和真机验证后才能打开。
const bool kIosShortcutsEnabled = false;
