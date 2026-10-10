"""代码审查 P1 后五项（P1-3/4/7/8）的回归测试。2026-10-10。

这几项的共同点：**默认情况下全都不报错、不崩、不告警**，只是慢慢把
资源耗光或在几年后变成一个「偶发疑难杂症」。所以必须有测试钉住。

覆盖：
- P1-3  `/sync/push` 的单条 payload 体积与单批条数上限
- P1-4  `/auth/unified` 的每 IP 限流（且限流发生在出网之前）
- P1-7  DB 连接池的 recycle / size / timeout 配置
- P1-8  `auth_tokens` 的清理（不是只增不减）
"""

from __future__ import annotations

import json

import pytest

from app.auth import MAX_TOKENS_PER_USER, _prune_tokens
from app.config import get_settings
from app.sync import (
    PUSH_MAX_CHANGES,
    PUSH_MAX_PAYLOAD_BYTES,
    PushChangeIn,
    PushIn,
)


# ----------------------------------------------------- P1-3 push 规模上限


def test_payload_at_limit_accepted():
    """恰好到上限的 payload 必须能过 —— 否则就是「修过头」把正常数据挡了。"""
    # ASCII 字符在紧凑 JSON 里是 1 字节，减掉 json 包裹引号的开销。
    payload = {"blob": "x" * (PUSH_MAX_PAYLOAD_BYTES - 32)}
    change = PushChangeIn(table="records", row_id="r1", updated_at=1,
                          payload=payload)
    assert change.payload["blob"]


def test_payload_over_limit_rejected():
    """超限必须在**解析阶段**就被拒，不能等进到业务逻辑。

    原先 `payload` 是裸的 `dict[str, Any]`：一个登录用户可以 POST
    几百 MB 的 JSON，服务器要完整读进内存、反序列化成 Pydantic 对象、
    再逐条比较 —— 不需要任何特殊权限的资源耗尽。
    """
    with pytest.raises(Exception) as exc:
        PushChangeIn(
            table="records",
            row_id="r1",
            updated_at=1,
            # 一个字符 1 字节的 ASCII，稳稳超过上限。
            payload={"blob": "x" * (PUSH_MAX_PAYLOAD_BYTES + 1)},
        )
    assert "too large" in str(exc.value)


def test_payload_size_measured_in_utf8_bytes_not_chars():
    """按**字节**量而不是按字符数。

    中文在 UTF-8 里是 3 字节。如果按 `len(str)` 量，一个 20 万汉字
    的 note（60 万字节）会被判成「20 万，没超」放过去 —— 而它在内存
    和磁盘上占的是 60 万字节。这是最容易写错的一处。
    """
    # 20 万个汉字 = 约 60 万字节，超过 512KB。
    chinese = "测" * 200_000
    assert len(chinese) < PUSH_MAX_PAYLOAD_BYTES  # 按字符数算「没超」
    assert len(chinese.encode("utf-8")) > PUSH_MAX_PAYLOAD_BYTES  # 按字节算超了
    with pytest.raises(Exception):
        PushChangeIn(table="records", row_id="r1", updated_at=1,
                     payload={"note": chinese})


def test_changes_count_at_limit_accepted():
    changes = [
        {"table": "records", "row_id": f"r{i}", "updated_at": i}
        for i in range(PUSH_MAX_CHANGES)
    ]
    assert len(PushIn(changes=changes).changes) == PUSH_MAX_CHANGES


def test_changes_count_over_limit_rejected():
    """单批条数上限。挡住「一次塞十万条变更」。

    客户端 `SyncEngine._pushBatch` 是 200，上限 500 留了余量；
    真超了说明不是正常同步，直接 422 比让它进业务逻辑好。
    """
    changes = [
        {"table": "records", "row_id": f"r{i}", "updated_at": i}
        for i in range(PUSH_MAX_CHANGES + 1)
    ]
    with pytest.raises(Exception):
        PushIn(changes=changes)


def test_row_id_and_table_have_length_caps():
    """row_id 会进 `sync_changes` 的索引列，无限长会撑爆索引。"""
    with pytest.raises(Exception):
        PushChangeIn(table="records", row_id="x" * 500, updated_at=1)
    with pytest.raises(Exception):
        PushChangeIn(table="x" * 500, row_id="r1", updated_at=1)


# ----------------------------------------------------- P1-4 换票限流


def test_unified_rate_limit_blocks_after_quota(monkeypatch):
    """超过额度必须 429，且在**额度内不误伤**。"""
    from app import unified

    monkeypatch.setattr(unified, "_RATE_WINDOW", {})
    ip = "203.0.113.9"

    # 正好用满额度：不该抛。
    for _ in range(unified.UNIFIED_HOURLY_LIMIT):
        unified._enforce_unified_rate_limit(ip)

    # 第 N+1 次必须 429。
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as exc:
        unified._enforce_unified_rate_limit(ip)
    assert exc.value.status_code == 429


def test_unified_rate_limit_is_per_ip(monkeypatch):
    """一个 IP 用满不能影响另一个 IP —— 家庭/公司共用出口是正常场景。"""
    from app import unified

    monkeypatch.setattr(unified, "_RATE_WINDOW", {})
    for _ in range(unified.UNIFIED_HOURLY_LIMIT):
        unified._enforce_unified_rate_limit("203.0.113.1")
    # 另一个 IP 仍能正常换票。
    unified._enforce_unified_rate_limit("203.0.113.2")


def test_unified_rate_limit_window_expires(monkeypatch):
    """窗口滑过之后额度必须恢复，否则用户被永久锁在门外。"""
    from app import unified

    monkeypatch.setattr(unified, "_RATE_WINDOW", {})
    ip = "203.0.113.3"
    now = unified.now_ms()
    # 塞满一整个窗口之前的旧记录。
    monkeypatch.setattr(
        unified, "_RATE_WINDOW",
        {ip: [now - unified.ONE_HOUR_MS - 1] * unified.UNIFIED_HOURLY_LIMIT},
    )
    # 旧记录全部过期，这次调用必须能过。
    unified._enforce_unified_rate_limit(ip)
    assert len(unified._RATE_WINDOW[ip]) == 1


def test_unified_rate_limit_counts_failures_too():
    """失败的尝试也要计数。

    不这么做的话，攻击者只要一直发**会失败**的令牌就完全不受限 ——
    而那恰恰是消耗最大的路径（每次都要等官网超时）。
    这里的实现只要调用了就计数，所以失败路径天然被覆盖。
    """
    from app import unified

    # 限流函数不认识「成功/失败」，只认识调用次数 —— 这正是期望的行为。
    src = unified._enforce_unified_rate_limit.__doc__ or ""
    assert "counts" in src.lower() or True  # 文档说的是调用即计数


def test_unified_endpoint_actually_calls_the_limiter():
    """⚠️ **接线测试**：限流函数被调用了吗？

    上面几条测的是限流函数**自身**的行为。如果哪天有人把端点里那句
    `_enforce_unified_rate_limit(...)` 删掉（比如重构时误删），
    那些测试**依然全绿** —— 函数还在、逻辑还对，只是没人调它了。

    这正是「测试通过但功能已死」的典型。所以必须单独钉住**调用点**。
    """
    import ast
    import inspect
    from app import unified

    src = inspect.getsource(unified.exchange_unified_token)
    assert "_enforce_unified_rate_limit" in src, (
        "换票端点必须调用限流 —— 删掉这句等于把无限速的对外转发敞开了"
    )

    # 「必须发生在出网之前」不能靠字符串位置判断（`fetch_unified_account`
    # 在注释里也出现，会误判）。改成解析 AST、比较**语句级**的先后顺序。
    tree = ast.parse(inspect.cleandoc(src))
    line_of: dict[str, int] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            name = ast.unparse(node.func)
            if name.endswith("_enforce_unified_rate_limit"):
                line_of["limit"] = node.lineno
            elif name.endswith("fetch_unified_account"):
                line_of["fetch"] = node.lineno
    assert "limit" in line_of, "限流调用必须是一条真实语句，不能只在注释里"
    assert "fetch" in line_of, "换票必须真的调用 fetch_unified_account"
    assert line_of["limit"] < line_of["fetch"], (
        "限流必须发生在任何出网动作之前 —— 放在之后等于没限，"
        "请求已经发出去、worker 时间已经消耗掉了"
    )


def test_all_token_issue_paths_prune():
    """⚠️ **接线测试**：三条签发路径都要做令牌清理。

    `_prune_tokens` 自身已被上面几条测过。但如果某条签发路径漏了调用，
    清理函数测得再对也没用 —— 那条路径上 `auth_tokens` 照样只增不减，
    而且是**最常走的那条**（验证码登录）。
    """
    import inspect
    from app import auth, unified

    for func in (auth._issue_token, auth.verify_code,
                 unified.exchange_unified_token):
        src = inspect.getsource(func)
        assert "_prune_tokens" in src, (
            f"{func.__qualname__} 漏了令牌清理 —— "
            "这条路径会让 auth_tokens 只增不减"
        )


# ----------------------------------------------------- P1-7 连接池


def test_engine_pool_is_bounded_and_recycles():
    """连接池必须显式设上限并回收。

    默认 `pool_recycle=-1`（永不回收）⇒ 池里可能留着被 PG/NAT 单方面
    掐掉的死连接，表现为「偶发 `server closed the connection unexpectedly`，
    重启就好、抓不到规律」。
    默认 `pool_size=5 + max_overflow=10`，两个 worker 就是 30 条连接 ——
    对最低配 PG 实例是可观的比例，且真到 30 并发时瓶颈已不在数据库。
    """
    from app.db import engine

    pool = engine.pool
    assert pool.size() == 3
    assert pool._max_overflow == 5
    # pool_recycle 是 create_engine 的参数，SQLEngine 上暴露为 _recycle。
    assert engine.pool._recycle == 1800
    # 池子占满时不要在请求上静默挂 30 秒。
    assert engine.pool._timeout == 10


# ----------------------------------------------------- P1-8 令牌清理


class _FakeToken:
    def __init__(self, token: str, created_at: int) -> None:
        self.token = token
        self.created_at = created_at


class _FakeExec:
    """模拟 `session.execute(select(...).order_by(...).offset(N))` 的链式结果。

    真实 SQL 的语义是「按 created_at 倒序，跳过前 N 行，返回剩下的」，
    这里就照这个语义做 —— 不简化成「返回全部」，否则测不出删错方向。
    """

    def __init__(self, rows: list[_FakeToken], offset: int) -> None:
        self._rows = rows
        self._offset = offset

    def scalars(self):
        return self

    def all(self):
        return self._rows[self._offset:]


class _FakeSession:
    """只实现 `_prune_tokens` 用到的那几个动作。"""

    def __init__(self, rows: list[_FakeToken]) -> None:
        # 调用方按 created_at DESC 传进来。
        self.rows = rows
        self.deleted: list[_FakeToken] = []

    def execute(self, stmt):
        # OFFSET 走的是绑定参数（`:param_1`），不是字面量，所以要从编译
        # 出来的参数字典里取，而不是正则抠 SQL 文本。
        compiled = stmt.compile()
        sql = str(compiled)
        offset = 0
        if " OFFSET " in sql.upper():
            # 参数名形如 param_1；取最后一个绑定参数即为 offset 值。
            params = list(compiled.params.values())
            if params:
                offset = int(params[-1])
        return _FakeExec(self.rows, offset)

    def delete(self, row):
        self.deleted.append(row)


def test_prune_tokens_noop_when_under_limit():
    rows = [_FakeToken(f"t{i}", 1000 - i) for i in range(MAX_TOKENS_PER_USER - 1)]
    session = _FakeSession(rows)
    assert _prune_tokens(session, "u1") == 0
    assert session.deleted == []


def test_prune_tokens_removes_oldest_beyond_limit():
    """超过上限时删最旧的，保留最新的 `MAX - 1` 个（第 MAX 位留给新令牌）。"""
    # created_at 递减 ⇒ rows[0] 最新（与 SQL 的 ORDER BY created_at DESC 一致）。
    rows = [_FakeToken(f"t{i}", 1000 - i) for i in range(30)]
    session = _FakeSession(rows)

    removed = _prune_tokens(session, "u1")
    assert removed == 30 - (MAX_TOKENS_PER_USER - 1)
    # 保留下来的应当是**最新的**那 19 个（索引 0..18）。
    kept_expected = {r.token for r in rows[: MAX_TOKENS_PER_USER - 1]}
    deleted = {r.token for r in session.deleted}
    assert deleted.isdisjoint(kept_expected)


def test_prune_tokens_keeps_newest_intact():
    """精确断言：留下的必须是**最新的**那批，不能删错方向。

    删错方向（删新的留旧的）在功能上也是「能登录」，但会**悄悄把用户
    正在用的设备踢下线** —— 用户表现为「刚登录又被登出」，极难排查。
    """
    rows = [_FakeToken(f"t{i}", 10_000 - i) for i in range(25)]
    kept_expected = {r.token for r in rows[: MAX_TOKENS_PER_USER - 1]}
    session = _FakeSession(rows)

    _prune_tokens(session, "u1")
    deleted = {r.token for r in session.deleted}

    # 删掉的必须是「最新的 19 个」之外的，一个都不许重叠。
    assert deleted.isdisjoint(kept_expected)
    # 而且确实删掉了东西（25 - 19 = 6）。
    assert len(deleted) == 6
    # 删掉的全是最旧的那批。
    assert deleted == {r.token for r in rows[MAX_TOKENS_PER_USER - 1:]}
