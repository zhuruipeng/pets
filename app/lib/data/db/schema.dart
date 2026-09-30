/// 数据库 Schema —— 十张表的建表语句。
///
/// 选型说明：用 sqflite + 手写 DDL，而不是 drift 代码生成。
/// 理由：MVP 阶段 schema 会频繁调整，手写 DDL 改起来更直接，
/// 也省掉 build_runner 的生成步骤。表结构稳定后可再迁 drift。
///
/// 三条铁律（详见 README）：
/// 1. 所有业务表带 deleted_at，一律软删除
/// 2. recorded_at（事件发生时间）与 created_at（入库时间）必须分开
/// 3. 时间统一存 INTEGER（millisecondsSinceEpoch），不存字符串
///
/// MVP 期版本策略：`kSchemaVersion` 从 1 起步，每改一次表结构加一版。
///
/// 判断依据不是「有没有上线」，而是**有没有人在用**：一旦老板手机上装了包，
/// sqlite 文件就落地了，改 CREATE 语句对已存在的库无效 —— 必须走迁移。
///
/// 迁移写在 [migrations] 里，按目标版本 Key。**已发出去的分支不许再改**，
/// 老用户升级时会按版本顺序重放，改一句就会在别人手机上错位。
library;

const int kSchemaVersion = 4;

const String createUsers = '''
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  nickname      TEXT NOT NULL,
  phone         TEXT,
  email         TEXT,
  avatar_url    TEXT,
  -- 联系方式（M5）：走失协查卡片要印在卡片上给拾到的人看。
  -- wechat 单列出来是因为国内场景下它比手机号更常用；
  -- 其它渠道塞 contact_note 自由文本，不为了「完整性」再开五列。
  wechat        TEXT,
  contact_note  TEXT,
  region        TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);
''';

const String createPets = '''
CREATE TABLE pets (
  id                  TEXT PRIMARY KEY,
  name                TEXT NOT NULL,
  species             TEXT NOT NULL,
  breed               TEXT,
  gender              TEXT,
  birthday            INTEGER,
  birthday_estimated  INTEGER NOT NULL DEFAULT 0,
  adopt_date          INTEGER,
  avatar_url          TEXT,
  weight_baseline     REAL,
  neutered            INTEGER NOT NULL DEFAULT 0,
  chip_no             TEXT,
  color               TEXT,
  allergy             TEXT,
  note                TEXT,
  -- 个性特点：JSON 数组字符串（如 ["friendly","playful"]）。
  -- 存 code 不存显示文案 —— 文案会随语言变，code 不会。
  personality         TEXT,
  archived_at         INTEGER,
  -- 商业化预留：'free' | 'premium'。V1 不做付费，字段先占位，
  -- 免得后面加订阅要动一次生产库的 schema 迁移。
  tier                TEXT NOT NULL DEFAULT 'free',
  created_by          TEXT NOT NULL,
  created_at          INTEGER NOT NULL,
  updated_at          INTEGER NOT NULL,
  deleted_at          INTEGER
);
''';

const String createMembers = '''
CREATE TABLE members (
  id         TEXT PRIMARY KEY,
  pet_id     TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  -- owner / editor / viewer，与 docs/同步协议.md 的权限矩阵一致。
  role       TEXT NOT NULL,
  -- pending（已邀请未接受，此时**没有读权限**）/ active。
  status     TEXT NOT NULL DEFAULT 'active',
  joined_at  INTEGER NOT NULL,
  updated_at INTEGER,
  deleted_at INTEGER,
  UNIQUE(pet_id, user_id)
);
''';

const String createRecords = '''
CREATE TABLE records (
  id           TEXT PRIMARY KEY,
  pet_id       TEXT NOT NULL,
  type         TEXT NOT NULL,
  recorded_at  INTEGER NOT NULL,
  value_num    REAL,
  value_text   TEXT,
  unit         TEXT,
  payload      TEXT,
  note         TEXT,
  created_by   TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  deleted_at   INTEGER
);
''';

const String createAttachments = '''
CREATE TABLE attachments (
  id          TEXT PRIMARY KEY,
  record_id   TEXT NOT NULL,
  kind        TEXT NOT NULL,
  local_path  TEXT,
  remote_url  TEXT,
  width       INTEGER,
  height      INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER,
  deleted_at  INTEGER
);
''';

/// 同步元数据。key/value 表，见 docs/同步协议.md 第八节。
///
/// key 取值：device_id / last_seq / last_sync_at / account_id / applying
const String createSyncMeta = '''
CREATE TABLE sync_meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
''';

/// 待推送变更队列。**由触发器自动写入**，仓储层不用管。
///
/// (table_name, row_id) 是主键：同一行被改多次只留最后一次 ——
/// 中间态没有推送价值，推上去也只会让服务端多做几次无用的 LWW 比较。
const String createSyncOutbox = '''
CREATE TABLE sync_outbox (
  table_name TEXT NOT NULL,
  row_id     TEXT NOT NULL,
  pet_id     TEXT,
  op         TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (table_name, row_id)
);
''';

const String createReminders = '''
CREATE TABLE reminders (
  id         TEXT PRIMARY KEY,
  pet_id     TEXT NOT NULL,
  type       TEXT NOT NULL,
  title      TEXT NOT NULL,
  rule       TEXT NOT NULL,
  next_at    INTEGER NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  source     TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
''';

const String createReminderLogs = '''
CREATE TABLE reminder_logs (
  id           TEXT PRIMARY KEY,
  reminder_id  TEXT NOT NULL,
  due_at       INTEGER NOT NULL,
  done_at      INTEGER,
  record_id    TEXT,
  action       TEXT,
  UNIQUE(reminder_id, due_at)
);
''';

const String createWalkSessions = '''
CREATE TABLE walk_sessions (
  id          TEXT PRIMARY KEY,
  pet_id      TEXT NOT NULL,
  started_at  INTEGER NOT NULL,
  ended_at    INTEGER,
  distance_m  REAL NOT NULL DEFAULT 0,
  duration_s  INTEGER NOT NULL DEFAULT 0,
  region      TEXT NOT NULL,
  mood        TEXT,
  note        TEXT,
  created_by  TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER
);
''';

const String createWalkPoints = '''
CREATE TABLE walk_points (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL,
  lat         REAL NOT NULL,
  lng         REAL NOT NULL,
  altitude    REAL,
  accuracy    REAL,
  recorded_at INTEGER NOT NULL
);
''';

const String createPetTags = '''
CREATE TABLE pet_tags (
  id            TEXT PRIMARY KEY,
  pet_id        TEXT NOT NULL,
  tag_type      TEXT NOT NULL,
  tag_name      TEXT,
  tag_uid       TEXT,
  last_seen_at  INTEGER,
  created_at    INTEGER NOT NULL,
  deleted_at    INTEGER
);
''';

/// 索引。轨迹点是全库写入最频繁的表，必须建索引。
const List<String> createIndexes = [
  'CREATE INDEX idx_records_pet_time ON records(pet_id, recorded_at DESC);',
  'CREATE INDEX idx_records_pet_type ON records(pet_id, type, recorded_at DESC);',
  'CREATE INDEX idx_reminders_pet_next ON reminders(pet_id, next_at);',
  'CREATE INDEX idx_walk_points_session ON walk_points(session_id, recorded_at);',
  'CREATE INDEX idx_walk_sessions_pet ON walk_sessions(pet_id, started_at DESC);',
  'CREATE INDEX idx_attachments_record ON attachments(record_id);',
];

/// 建库顺序（有外键依赖关系的先建）。
///
/// 不是 `const`：触发器语句由 [_triggersFor] 拼出来，
/// 常量表达式里没法 in循环生成。
final List<String> onCreate = [
  createUsers,
  createPets,
  createMembers,
  createRecords,
  createAttachments,
  createReminders,
  createReminderLogs,
  createWalkSessions,
  createWalkPoints,
  createPetTags,
  createSyncMeta,
  createSyncOutbox,
  ...createIndexes,
  ...createSyncTriggers,
];

// ------------------------------------------------------------------ 变更捕获触发器

/// 同步范围：哪些表要往 outbox 记变更。
///
/// 三个字段都是有原因才写死在这里的：
/// - `petExpr`：分发键怎么取。多数表有自己的 `pet_id` 列，但 `pets` 的
///   归属就是它自己，`users` 不属于任何宠物，`attachments` 要经 record 反查。
///   同步靠 `pet_id` 判断「这条变更我该不该看见」，取错就等于泄露或丢数据。
/// - `hasDeletedAt`：`users` 表没有 `deleted_at`（账号不做软删除），
///   触发器里不能引用不存在的列 —— **SQLite 建触发器时就会解析列名并报错**。
///
/// **不在这个列表里的表不会被同步**，见 docs/同步协议.md 第三节：
/// - `walk_points`：逐点同步会把变更日志撑爆，它随 session 一起传
/// - `reminder_logs`：本地行为统计，跨设备合并意义不大，且表里没有 updated_at
/// - `pet_tags`：目前没有任何写入路径
const List<({String table, String petExpr, bool hasDeletedAt})> kSyncedTables = [
  (table: 'users', petExpr: 'NULL', hasDeletedAt: false),
  (table: 'pets', petExpr: 'NEW.id', hasDeletedAt: true),
  (table: 'members', petExpr: 'NEW.pet_id', hasDeletedAt: true),
  (table: 'records', petExpr: 'NEW.pet_id', hasDeletedAt: true),
  (
    table: 'attachments',
    petExpr: '(SELECT pet_id FROM records WHERE id = NEW.record_id)',
    hasDeletedAt: true,
  ),
  (table: 'reminders', petExpr: 'NEW.pet_id', hasDeletedAt: true),
  (table: 'walk_sessions', petExpr: 'NEW.pet_id', hasDeletedAt: true),
];

/// 逐个生成 INSERT / UPDATE 触发器。
///
/// **为什么用触发器而不是在仓储里手动记一笔**：仓储有六个、写方法二十多个，
/// 还分软删/恢复/批量/REPLACE 等分支。漏一处就是某一类数据永远不同步，
/// 而且只在那条路径上复现 —— 是最难查的一种 bug。交给数据库就不会漏。
///
/// **UPDATE 触发器用 `AFTER UPDATE`（无 WHEN 过滤列）而不是只盯某几列**：
/// 列名清单会随表结构漂移，一旦加了新列忘了补，那列就永远不同步。
/// 代价是「无实质变化的 update」也会产生一条 outbox，LWW 会把它判成 no-op，
/// 这点浪费换的是不会漏。
///
/// `WHEN ... IS NOT '1'`：从服务端拉下来的变更不能再进 outbox，
/// 否则「推上去 → 拉下来 → 又推上去」无限循环。应用远端数据前把
/// `sync_meta.applying` 置 1，触发器就整体哑火。`IS NOT` 是 null 安全比较，
/// 行不存在时（NULL IS NOT '1'）= 真，默认照常记录。
List<String> _triggersFor(
  String table,
  String petExpr, {
  required bool hasDeletedAt,
}) {
  final opExpr = hasDeletedAt
      ? "CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END"
      : "'upsert'";

  /// `suffix` 只用于触发器名，`keyword` 才是 SQL 关键字。
  ///
  /// **两者必须分开传**：早先写的是 `${event.toUpperCase()}`，`ins` 大写成
  /// `INS` 而不是 `INSERT`，生成出 `AFTER INS ON users` —— SQLite 直接语法错误，
  /// 建库失败，App 首次启动就起不来。单测能发现（内存库 open 会抛），
  /// 但当时测试还没跑起来，所以这个错一直潜伏到打包后。
  String body(String suffix, String keyword) => '''
CREATE TRIGGER trg_${table}_outbox_$suffix AFTER $keyword ON $table
WHEN (SELECT value FROM sync_meta WHERE key = 'applying') IS NOT '1'
BEGIN
  INSERT OR REPLACE INTO sync_outbox(table_name, row_id, pet_id, op, updated_at)
  VALUES ('$table', NEW.id, $petExpr, $opExpr, NEW.updated_at);
END;
''';

  return [body('ins', 'INSERT'), body('upd', 'UPDATE')];
}

/// 全部同步触发器。由 [_triggersFor] 生成，集中在这里方便核对覆盖范围。
final List<String> createSyncTriggers = [
  for (final t in kSyncedTables)
    ..._triggersFor(t.table, t.petExpr, hasDeletedAt: t.hasDeletedAt),
];

/// 逐级迁移语句。key = 目标版本。
///
/// 每一条都是 ALTER TABLE ADD COLUMN —— SQLite 只支持这种弱改表，
/// 要删列或改约束就得走「建新表 → 搬数据 → 改名」那套，届时单独写。
/// 迁移脚本。**不能是 const** —— v4 起把建表语句和触发器（运行时生成的
/// `final List<String>`）拼进了同一个列表，const 要求每个元素都是编译期常量。
final Map<int, List<String>> migrations = {
  // v2：遛狗结束后补录心情与备注（参考稿屏 12）。
  // 两条都是可空列，老数据不用回填。
  2: [
    'ALTER TABLE walk_sessions ADD COLUMN mood TEXT',
    'ALTER TABLE walk_sessions ADD COLUMN note TEXT',
  ],
  // v3：宠物个性特点（M2.3）。可空 JSON 数组，老数据留空即可，
  // 界面按「没填就不显示」处理，不做回填。
  3: [
    'ALTER TABLE pets ADD COLUMN personality TEXT',
  ],
  // v4：联系方式（M5）+ 同步底座（M6，见 docs/同步协议.md）。
  4: [
    // ---- 联系方式 ----
    'ALTER TABLE users ADD COLUMN wechat TEXT',
    'ALTER TABLE users ADD COLUMN contact_note TEXT',

    // ---- 统一 updated_at：同步的 LWW 基准 ----
    // members / attachments 原先没有这一列，同步时没法比新旧。
    // 补列 + 用现有时间字段回填，比在触发器里写 COALESCE 更不容易错。
    'ALTER TABLE members ADD COLUMN updated_at INTEGER',
    'ALTER TABLE attachments ADD COLUMN updated_at INTEGER',
    'UPDATE members SET updated_at = COALESCE(deleted_at, joined_at) WHERE updated_at IS NULL',
    'UPDATE attachments SET updated_at = COALESCE(deleted_at, created_at) WHERE updated_at IS NULL',

    // ---- 共养角色对齐同步协议的权限矩阵 ----
    // 早期只有 owner / caretaker 两种。caretaker 重命名为 editor，
    // 并新增 viewer（只读）。改名而不新增列，是因为权限矩阵只有一份口径，
    // 留着两套名字迟早会出现「这个 caretaker 到底算哪一级」的争论。
    'ALTER TABLE members ADD COLUMN status TEXT NOT NULL DEFAULT \'active\'',
    "UPDATE members SET role = 'editor' WHERE role = 'caretaker'",

    // ---- 同步元数据与变更队列 ----
    createSyncMeta,
    createSyncOutbox,
    ...createSyncTriggers,
  ],
};
