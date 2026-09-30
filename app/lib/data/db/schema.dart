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

const int kSchemaVersion = 2;

const String createUsers = '''
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  nickname      TEXT NOT NULL,
  phone         TEXT,
  email         TEXT,
  avatar_url    TEXT,
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
  role       TEXT NOT NULL,
  joined_at  INTEGER NOT NULL,
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
  deleted_at  INTEGER
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
const List<String> onCreate = [
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
  ...createIndexes,
];

/// 逐级迁移语句。key = 目标版本。
///
/// 每一条都是 ALTER TABLE ADD COLUMN —— SQLite 只支持这种弱改表，
/// 要删列或改约束就得走「建新表 → 搬数据 → 改名」那套，届时单独写。
const Map<int, List<String>> migrations = {
  // v2：遛狗结束后补录心情与备注（参考稿屏 12）。
  // 两条都是可空列，老数据不用回填。
  2: [
    'ALTER TABLE walk_sessions ADD COLUMN mood TEXT',
    'ALTER TABLE walk_sessions ADD COLUMN note TEXT',
  ],
};
