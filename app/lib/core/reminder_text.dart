/// 提醒文案的解析与类型表。
///
/// 放在 core 且**只收字符串**（不 import data/models）：这样通知服务与界面
/// 能共用同一套解析，各自不用抄一遍。抄两遍的后果是「列表里显示『疫苗』、
/// 通知栏却显示 plan.vaccine.core」这种只有用户才发现的不一致。
library;

import 'l10n.dart';

/// 可手动新建的提醒类型。顺序即选择器里的顺序。
///
/// 值必须与库里的 type 一致：自动生成的提醒用的是
/// `PlanItemType.wireName`（下划线式），手动建的必须跟它同一套，
/// 否则统计和图标又要分叉。
const List<String> kManualReminderTypes = [
  'vaccine',
  'deworm_internal',
  'deworm_external',
  'checkup',
  'medication',
  'other',
];

/// 提醒类型的显示名。未知类型回落到「其他」，绝不显示内部串。
String reminderTypeLabel(String type) {
  final key = 'reminder.type.$type';
  final v = L.t(key);
  return v == key ? L.t('reminder.type.other') : v;
}

/// 提醒标题。
///
/// 三种约定，按顺序判：
/// 1. 空 → 用类型名（用户没起名）
/// 2. 含 `.` → 系统生成的 i18n key（如 `plan.vaccine.core`），翻译它
/// 3. 其余 → 用户自己写的名字，原样显示
///
/// 早先这里对第 3 种也回落到 `type`，导致手动提醒在列表里显示成
/// `medication` 这种内部串。
String reminderTitleFrom(String rawTitle, String type) {
  final raw = rawTitle.trim();
  if (raw.isEmpty) return reminderTypeLabel(type);
  if (raw.contains('.')) {
    final translated = L.t(raw);
    if (translated != raw) return translated;
  }
  return raw;
}
