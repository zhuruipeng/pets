#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在真 SQLite 上跑一遍生产 DDL（建表 + 索引 + 触发器）。

本机跑不了 `flutter test`（Windows 命名管道 231），而触发器这种东西
只读代码看不出对错 —— 少一个 WHEN 条件、列名拼错，都要等用户在手机上
升级才炸。所以把生产那份 DDL 拿过来，用 Python 自带的 sqlite3 真跑一遍。

    python tool/schema_smoke.py

语句来自 `tool/dump_schema.dart`（同一份生产 DDL），不是这里另抄的。
"""
import sqlite3
import subprocess
import sys
import os

DART = r"E:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "dump_schema.dart")


def load_ddl():
    out = subprocess.run(
        [DART, DUMP], cwd=os.path.dirname(HERE),
        capture_output=True, text=True, encoding="utf-8",
    )
    if out.returncode != 0:
        sys.exit("dump_schema.dart 跑失败:\n" + out.stderr[-2000:])

    version = None
    sections = {}
    current = None
    buf = []
    for line in out.stdout.splitlines():
        if line.startswith("#VERSION "):
            version = int(line.split()[1])
        elif line.startswith("#SECTION "):
            current = line[len("#SECTION "):]
            sections[current] = []
            buf = []
        elif line == "@@@":
            stmt = "\n".join(buf).strip()
            if stmt:
                sections[current].append(stmt)
            buf = []
        else:
            buf.append(line)
    return version, sections


def main():
    version, sections = load_ddl()
    on_create = sections["onCreate"]
    migs = {k: v for k, v in sections.items() if k.startswith("migration ")}

    print(f"schema v{version}：onCreate {len(on_create)} 条语句，"
          f"{len(migs)} 级迁移")

    db = sqlite3.connect(":memory:")
    db.row_factory = sqlite3.Row
    for stmt in on_create:
        db.execute(stmt)
    db.commit()

    def tables():
        return {r[0] for r in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}

    def triggers():
        return {r[0] for r in db.execute(
            "SELECT name FROM sqlite_master WHERE type='trigger'")}

    t = tables()
    print(f"建出 {len(t)} 张表、{len(triggers())} 个触发器")

    assert "expenses" in t, "onCreate 应建出 expenses"
    assert "attachments" in t, "onCreate 应建出 attachments"

    # ---- 1) 每张同步表的 INSERT 都要进 outbox ----
    # 八张表的 pet_id 取法各不相同（自己的列 / 反查 record / NULL），
    # 取错了就是「同步出去别人看不见」或「同步给了不该看的人」。
    db.execute("INSERT INTO pets (id, name, species, created_by,"
               " created_at, updated_at) VALUES "
               "('p1','额藕丝','dog','u1',1000,1000)")
    db.execute("DELETE FROM sync_outbox")
    db.execute("INSERT INTO records (id, pet_id, type, recorded_at,"
               " created_by, created_at, updated_at) VALUES "
               "('r1','p1','medical',1100,'u1',1100,1100)")
    db.execute("DELETE FROM sync_outbox")

    cases = [
        ("members", "INSERT INTO members (id, pet_id, user_id, role,"
                    " status, joined_at, updated_at) VALUES "
                    "('m1','p1','u1','owner','active',1200,1200)"),
        ("records", "INSERT INTO records (id, pet_id, type, recorded_at,"
                    " created_by, created_at, updated_at) VALUES "
                    "('r2','p1','weight',1200,'u1',1200,1200)"),
        ("attachments", "INSERT INTO attachments (id, record_id, kind,"
                        " local_path, created_at, updated_at) VALUES "
                        "('a1','r1','photo','/x/1.jpg',1200,1200)"),
        ("reminders", "INSERT INTO reminders (id, pet_id, type, title,"
                      " rule, next_at, enabled, created_at, updated_at)"
                      " VALUES ('rm1','p1','vaccine','t','{}',1300,1,"
                      " 1200,1200)"),
        ("expenses", "INSERT INTO expenses (id, pet_id, amount_cents, currency,"
                     " category, spent_at, created_by, created_at,"
                     " updated_at) VALUES "
                     "('e1','p1',12000,'CNY','medical',1200,'u1',1200,1200)"),
        ("walk_sessions", "INSERT INTO walk_sessions (id, pet_id,"
                          " started_at, region, created_by, created_at,"
                          " updated_at) VALUES "
                          "('w1','p1',1200,'cn','u1',1200,1200)"),
    ]
    for table, insert in cases:
        db.execute("DELETE FROM sync_outbox")
        db.execute(insert)
        rows = list(db.execute("SELECT * FROM sync_outbox"))
        assert len(rows) == 1, f"{table} 的 INSERT 应产生 1 条 outbox，实际 {len(rows)}"
        assert rows[0]["table_name"] == table, f"{table} 的 outbox 表名不对"
        assert rows[0]["pet_id"] == "p1", f"{table} 的分发键 pet_id 取错了"
        assert rows[0]["op"] == "upsert", f"{table} 的新增应是 upsert"
    print(f"INSERT 触发器：{len(cases)} 张表 × (进 outbox + pet_id 正确)")

    # ---- 2) 软删除要变成 delete 而不是 upsert ----
    db.execute("DELETE FROM sync_outbox")
    db.execute("UPDATE expenses SET deleted_at = 1300, updated_at = 1300"
               " WHERE id = 'e1'")
    row = db.execute("SELECT op FROM sync_outbox WHERE row_id='e1'").fetchone()
    assert row is not None, "软删要进 outbox"
    assert row["op"] == "delete", f"软删应记 delete，实际 {row['op']}"
    print("软删除：记为 delete")

    # ---- 3) applying=1 时整体哑火（否则拉下来的变更会被再推上去） ----
    db.execute("INSERT OR REPLACE INTO sync_meta (key, value)"
               " VALUES ('applying','1')")
    db.execute("DELETE FROM sync_outbox")
    db.execute("INSERT INTO expenses (id, pet_id, amount_cents, currency,"
               " category, spent_at, created_by, created_at, updated_at)"
               " VALUES ('e2','p1',500,'CNY','food',1400,'u1',1400,1400)")
    assert not list(db.execute("SELECT * FROM sync_outbox")), \
        "applying=1 时触发器必须哑火，否则同步会自激循环"
    db.execute("DELETE FROM sync_meta WHERE key='applying'")
    print("回环抑制：applying=1 时不记 outbox")

    # ---- 4) 文档原件只存本机，不进同步队列 ----
    db.execute("DELETE FROM sync_outbox")
    db.execute("INSERT INTO attachments (id, record_id, kind, local_path,"
               " file_name, size_bytes, local_only, created_at, updated_at)"
               " VALUES ('d1','r1','document','/x/v.pdf','疫苗本.pdf',2048,1,"
               " 1500,1500)")
    assert not list(db.execute("SELECT * FROM sync_outbox")), \
        "local_only=1 的文档不该进同步队列"
    # 同一次里插一张照片，确认「没把整张表的触发器误关掉」。
    db.execute("INSERT INTO attachments (id, record_id, kind, local_path,"
               " created_at, updated_at) VALUES "
               "('a2','r1','photo','/x/2.jpg',1500,1500)")
    rows = list(db.execute("SELECT * FROM sync_outbox"))
    assert len(rows) == 1 and rows[0]["row_id"] == "a2", \
        f"照片应照常进 outbox，实际 {rows}"
    print("文档原件：local_only=1 不进队列，照片照常进")

    # ---- 5) 每级迁移都能在「本版本建出来的库」上重放关键语句 ----
    # 完整重放做不到（ALTER 的那一列在 onCreate 里已经有了），
    # 但至少保证每条语句都是 SQLite 能解析的 —— 语法错是最常见的手误。
    #
    # 容忍两类「已存在」：onCreate 已经建过同名列 / 表 / 索引 / 触发器。
    # **只容忍这两种措辞**，真正的语法错、列名拼错会被留下来报出来。
    #
    # 两级迁移是特例，都在别处被真跑验证，这里只查「其余语句语法对不对」：
    # - v6：先 DROP 再 CREATE，那两条 CREATE 在本阶段就是真跑成功的。
    # - v8：重建 expenses 表，`SELECT amount`（旧列名）在「本版本建出来的库」
    #   上必然找不到 —— `no such column` 是**预期**的，不是手误。
    #   它在第 7 节用真正的 v7 老库结构跑过一遍，那才是有意义的验证。
    KNOWN_REPLAY_ERRORS = {
        "migration 8": ["no such column: amount"],
    }
    bad = []
    for v in sorted(migs, key=lambda k: int(k.split()[1])):
        probe = sqlite3.connect(":memory:")
        for stmt in on_create:
            probe.execute(stmt)
        tolerated = KNOWN_REPLAY_ERRORS.get(v, [])
        for stmt in migs[v]:
            try:
                probe.execute(stmt)
            except sqlite3.OperationalError as e:
                msg = str(e)
                if "duplicate column name" in msg or "already exists" in msg:
                    continue
                if any(t in msg for t in tolerated):
                    continue
                bad.append(f"  v{v}: {msg}\n    {stmt.splitlines()[0][:90]}")

        if v == "migration 6":
            sql = probe.execute(
                "SELECT sql FROM sqlite_master WHERE "
                "name='trg_attachments_outbox_ins'"
            ).fetchone()
            assert sql is not None, "v6 之后 attachments 的触发器必须还在"
            assert "local_only" in sql[0], \
                "v6 必须把触发器换成带 local_only 条件的那版（文档才拦得住）"
            print("v6 迁移：老触发器被换成带 local_only 条件的一版")

        probe.close()
    assert not bad, "迁移语句有 SQLite 解析不过的：\n" + "\n".join(bad)
    print(f"迁移语句：{len(migs)} 级，无 SQLite 语法错误")

    # ---- 6) v6 升级路径：老库（v5 时代、没有新列）真跑一遍迁移 ----
    # 上面的语法检查是在「onCreate 已含新列」的库上重放，只能查语法；
    # 这里按老用户手机上真实的表结构建库再升级，才验得到列真的补上、
    # 触发器真的被换掉。曾在此抓到过 flutter test 里的同款错误：
    # 用新 DDL 建表再跑迁移 = duplicate column。
    OLD_ATTACHMENTS = """
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
"""
    probe = sqlite3.connect(":memory:")
    probe.row_factory = sqlite3.Row
    for stmt in on_create:
        # 凡是引用 attachments 的语句全部跳过：表用老结构另建，
        # 它身上的索引与触发器这里用不上（触发器由 v6 迁移重建）。
        if "attachments" in stmt:
            continue
        probe.execute(stmt)
    probe.execute(OLD_ATTACHMENTS)
    probe.execute(
        "CREATE TRIGGER trg_attachments_outbox_ins AFTER INSERT ON attachments "
        "WHEN (SELECT value FROM sync_meta WHERE key = 'applying') IS NOT '1' "
        "BEGIN "
        "INSERT OR REPLACE INTO sync_outbox(table_name, row_id, pet_id, op,"
        " updated_at) VALUES ('attachments', NEW.id,"
        " (SELECT pet_id FROM records WHERE id = NEW.record_id),"
        " CASE WHEN NEW.deleted_at IS NULL THEN 'upsert' ELSE 'delete' END,"
        " NEW.updated_at); END;"
    )

    for stmt in migs["migration 6"]:
        probe.execute(stmt)

    sql = probe.execute(
        "SELECT sql FROM sqlite_master WHERE name='trg_attachments_outbox_ins'"
    ).fetchone()
    assert sql and "local_only" in sql[0], "升级后触发器必须带 local_only 条件"

    probe.execute(
        "INSERT INTO records (id, pet_id, type, recorded_at, created_by,"
        " created_at, updated_at) VALUES ('r1','p1','medical',1000,'u1',1000,1000)"
    )
    # 上面这条 records 本身就会进 outbox，先清掉再看文档那笔。
    probe.execute("DELETE FROM sync_outbox")
    probe.execute(
        "INSERT INTO attachments (id, record_id, kind, local_path, file_name,"
        " local_only, created_at, updated_at) VALUES"
        " ('d1','r1','document','/x/v.pdf','疫苗本.pdf',1,1500,1500)"
    )
    assert not list(probe.execute("SELECT * FROM sync_outbox")), \
        "升级后文档仍不该进同步队列"
    # 老照片行：不带 local_only 列插入（老代码就是这么写的）。
    probe.execute(
        "INSERT INTO attachments (id, record_id, kind, local_path,"
        " created_at, updated_at) VALUES"
        " ('a1','r1','photo','/x/1.jpg',1500,1500)"
    )
    rows = list(probe.execute("SELECT * FROM sync_outbox"))
    assert len(rows) == 1 and rows[0]["row_id"] == "a1", \
        f"老照片要照常同步，实际 {rows}"
    probe.close()
    print("v6 升级路径：老库补列成功、触发器被换掉、文档拦得住、老照片照常同步")

    # ---- 7) v7 → v8 升级路径：金额 REAL「元」→ INTEGER「分」 ----
    # 这是全库唯一一次**数据类型变更**（SQLite 不支持 ALTER COLUMN），
    # 走的是「建新表 → 搬运 → 删旧 → 改名 → 重建索引/触发器」。
    # 三个必须验的点：
    #   a) 老金额被正确换算成分（ROUND 不能省，否则 12.35 会截成 1234）
    #   b) 老行要重新进 outbox —— 否则其他设备永远拿不到新格式的金额
    #   c) 触发器/索引真的重建了（漏了的话那张表从此不同步）
    OLD_EXPENSES = """
CREATE TABLE expenses (
  id          TEXT PRIMARY KEY,
  pet_id      TEXT NOT NULL,
  amount      REAL NOT NULL,
  currency    TEXT NOT NULL DEFAULT 'CNY',
  category    TEXT NOT NULL DEFAULT 'other',
  spent_at    INTEGER NOT NULL,
  note        TEXT,
  record_id   TEXT,
  created_by  TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER,
  deleted_at  INTEGER
);
"""
    probe = sqlite3.connect(":memory:")
    probe.row_factory = sqlite3.Row
    for stmt in on_create:
        if "expenses" in stmt:
            continue  # 表用 v7 时代的老结构另建，索引/触发器由 v8 迁移重建。
        probe.execute(stmt)
    probe.execute(OLD_EXPENSES)

    # 老数据：挑几个「换算会出错」的典型值。
    #   12.35 → 1235（不 ROUND 会 truncate 成 1234）
    #    0.07 →    7
    #  120.0  → 12000
    #   -12.5 → -1250（退款，负号必须保住）
    #    0.0   →    0
    legacy = [
        ("e1", 12.35, 1000),
        ("e2", 0.07, 2000),
        ("e3", 120.0, 3000),
        ("e4", -12.5, 4000),
        ("e5", 0.0, 5000),
    ]
    for eid, amt, ts in legacy:
        probe.execute(
            "INSERT INTO expenses (id, pet_id, amount, currency, category,"
            " spent_at, created_by, created_at, updated_at) VALUES"
            " (?, 'p1', ?, 'CNY', 'food', ?, 'u1', ?, ?)",
            (eid, amt, ts, ts, ts),
        )

    for stmt in migs["migration 8"]:
        probe.execute(stmt)

    # a) 列类型与名字都换了。
    cols = {r["name"]: r["type"] for r in probe.execute(
        "PRAGMA table_info(expenses)")}
    assert "amount_cents" in cols, "v8 之后必须有 amount_cents 列"
    assert "amount" not in cols, "v8 之后旧的 amount 列必须消失"
    assert cols["amount_cents"].upper() == "INTEGER", \
        f"amount_cents 必须是 INTEGER，实际 {cols['amount_cents']}"

    # b) 每一笔的换算都对。
    want = {"e1": 1235, "e2": 7, "e3": 12000, "e4": -1250, "e5": 0}
    got = {r["id"]: r["amount_cents"] for r in probe.execute(
        "SELECT id, amount_cents FROM expenses")}
    assert got == want, f"换算结果不对：期望 {want}，实际 {got}"

    # c) 老行重新进了 outbox（不然别的设备还是老金额）。
    out = {r["row_id"] for r in probe.execute(
        "SELECT row_id FROM sync_outbox WHERE table_name='expenses'")}
    assert out == set(want), f"老费用行应全部重推，实际 {out}"
    ops = {r["op"] for r in probe.execute(
        "SELECT op FROM sync_outbox WHERE table_name='expenses'")}
    assert ops == {"upsert"}, f"重推应是 upsert，实际 {ops}"

    # d) 索引与触发器真的重建了（漏了就从此不同步 / 查询变慢）。
    idx = {r[0] for r in probe.execute(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='expenses'")}
    assert any("pet" in n or "spent" in n for n in idx), \
        f"expenses 的索引没重建，实际 {idx}"
    trg = {r[0] for r in probe.execute(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='expenses'")}
    assert "trg_expenses_outbox_ins" in trg, f"INSERT 触发器没重建，实际 {trg}"
    assert "trg_expenses_outbox_upd" in trg, f"UPDATE 触发器没重建，实际 {trg}"

    # e) 迁移后的表真的能写（新触发器生效）。
    probe.execute("DELETE FROM sync_outbox")
    probe.execute(
        "INSERT INTO expenses (id, pet_id, amount_cents, currency, category,"
        " spent_at, created_by, created_at, updated_at) VALUES"
        " ('e9','p1',99,'CNY','food',9000,'u1',9000,9000)")
    rows = list(probe.execute(
        "SELECT * FROM sync_outbox WHERE row_id='e9'"))
    assert len(rows) == 1 and rows[0]["pet_id"] == "p1", \
        "迁移后新写入必须照常进 outbox"
    probe.close()
    print("v7→v8 升级路径：REAL 元 正确换算为 INTEGER 分、老行重推、索引/触发器重建")

    print("\n全部通过")


if __name__ == "__main__":
    main()
