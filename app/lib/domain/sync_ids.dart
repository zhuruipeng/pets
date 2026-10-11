/// 同步协议里**由客户端约定**的行 id 规则。
///
/// ## 为什么单独开一个文件
///
/// 三条规矩原先散在三个地方，各自手拼字符串：
/// - `reminder_repository.dart` 记「给药完成」时拼 `dose_...`
/// - `backup_service.dart` 恢复备份时**重新拼一遍**同样的格式
/// - `sync_engine.dart` 反过来用 `rowId.startsWith('dose_')` **猜**
///   「这行是不是给药完成」
///
/// 前两处是「同一个格式写了两遍」，第三处更糟 —— 它把**字符串前缀**
/// 当成了业务语义的判据。这条前缀是本地发明的，协议文档里没有它；
/// 一旦有人改了拼法（或者服务端将来直接下发一个 `dose_` 开头的 id），
/// 判定就会静默出错，而错的方向是「本机离线补记的完成被远端旧记录覆盖」——
/// 用户看到的是自己刚点的「已给药」又变回未完成。
///
/// 所以这里做两件事：
/// 1. 拼法集中一处，写入方都从这里取
/// 2. 提供一个**显式的判据函数**，读的地方不再碰字符串
///
/// 纯 Dart，无 Flutter 依赖 —— 领域逻辑要能在离线环境单独跑（见
/// `tool/verify_*.dart`）。
library;

/// 给药完成记录的行 id 前缀。
///
/// 语义：id = `dose_{reminderId}_{dueAtMillis}`。
/// 用「方案 id + 该次应服时间」而不是随机 uuid，是为了**幂等**：
/// 同一只宠物、同一个方案、同一时刻的完成，在多台设备上离线各记一次，
/// 拼出来的 id 相同，服务端合并时是同一行（而不是两条都算数）。
const String kDoseRecordIdPrefix = 'dose_';

/// 提醒日志的行 id 前缀。语义同上：`log_{reminderId}_{dueAtMillis}`。
const String kReminderLogIdPrefix = 'log_';

/// 拼一条给药完成记录的行 id。
String doseRecordId({
  required String reminderId,
  required DateTime dueAt,
}) =>
    '$kDoseRecordIdPrefix${reminderId}_${dueAt.millisecondsSinceEpoch}';

/// 拼一条提醒日志的行 id。
String reminderLogId({
  required String reminderId,
  required DateTime dueAt,
}) =>
    '$kReminderLogIdPrefix${reminderId}_${dueAt.millisecondsSinceEpoch}';

/// 这行记录是不是「给药完成」？
///
/// ⚠️ 读的地方**必须用这个函数**，不要自己写 `startsWith('dose_')`。
/// 抽出来的意义就是让「前缀怎么拼」和「怎么认」只有一个来源。
bool isDoseRecordId(String rowId) =>
    rowId.startsWith(kDoseRecordIdPrefix);

/// 这行是不是提醒日志？同理，别自己写前缀判断。
bool isReminderLogId(String rowId) =>
    rowId.startsWith(kReminderLogIdPrefix);
