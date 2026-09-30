"""sync_logic 的纯逻辑测试。

刻意不依赖数据库、不依赖 FastAPI：这台机器上装了 pytest 但没有
PostgreSQL / SQLAlchemy，而这些规则（LWW、可见性、验证码、权限矩阵）
恰恰是最需要被钉死的部分。把它们做成纯函数就是为了能在这种环境里验证。
"""

from __future__ import annotations

import pytest

from app.sync_logic import (
    CODE_MAX_TRIES,
    generate_code,
    hash_token,
    is_code_valid,
    is_newer,
    new_token,
    normalize_target,
    role_can,
    visible_to,
)

# --------------------------------------------------------------- is_newer


def test_is_newer_strictly_greater_wins():
    assert is_newer(2000, 1000) is True


def test_is_newer_older_does_not_win():
    assert is_newer(1000, 2000) is False


def test_is_newer_tie_goes_to_server():
    # 平局判旧件出局（「平局服务端胜」），否则两端会来回互相覆盖。
    assert is_newer(1000, 1000) is False


def test_is_newer_no_current_value_is_always_new():
    assert is_newer(0, None) is True
    assert is_newer(1730000000000, None) is True


# --------------------------------------------------------------- visible_to


def _change(pet_id, user_id, seq=1):
    return {"seq": seq, "pet_id": pet_id, "user_id": user_id}


def test_visible_to_keeps_changes_of_my_pets():
    changes = [_change("p1", "someone-else")]
    assert visible_to(changes, {"p1"}, "me") == changes


def test_visible_to_drops_changes_of_foreign_pets():
    changes = [_change("p2", "someone-else")]
    assert visible_to(changes, {"p1"}, "me") == []


def test_visible_to_keeps_my_own_users_row():
    # users 行没有 pet_id，只能靠 user_id 判断归属。
    changes = [_change(None, "me")]
    assert visible_to(changes, set(), "me") == changes


def test_visible_to_drops_other_users_row():
    changes = [_change(None, "other")]
    assert visible_to(changes, set(), "me") == []


def test_visible_to_mixes_and_preserves_order():
    mine = _change("p1", "other", seq=1)
    foreign = _change("p9", "other", seq=2)
    my_user_row = _change(None, "me", seq=3)
    result = visible_to([mine, foreign, my_user_row], {"p1"}, "me")
    assert result == [mine, my_user_row]


def test_visible_to_empty_whitelist_keeps_only_own_rows():
    changes = [_change("p1", "other"), _change(None, "me")]
    assert visible_to(changes, set(), "me") == [_change(None, "me")]


# --------------------------------------------------------------- normalize_target


@pytest.mark.parametrize(
    ("channel", "raw", "expected"),
    [
        # 中国手机号默认补 +86（纯数字）
        ("sms", "13800138000", "+8613800138000"),
        # 用户从通讯录粘过来常带空格/横杠/括号
        ("sms", "138-0013-8000", "+8613800138000"),
        ("sms", "138 0013 8000", "+8613800138000"),
        ("sms", " (138) 0013-8000 ", "+8613800138000"),
        # 已带国家码的原样保留（不猜区号）
        ("sms", "+8613800138000", "+8613800138000"),
        ("sms", "+86 138 0013 8000", "+8613800138000"),
        ("sms", "+1 415 555 0100", "+14155550100"),
        # 邮箱统一小写去空格
        ("email", "  User@Example.COM ", "user@example.com"),
        ("email", "Foo.Bar@Gmail.com", "foo.bar@gmail.com"),
    ],
)
def test_normalize_target(channel, raw, expected):
    assert normalize_target(channel, raw) == expected


def test_normalize_target_returns_non_numeric_unchanged():
    # 含字母的「手机号」不做猜测，原样返回交给上层拒绝。
    assert normalize_target("sms", "abc123") == "abc123"


def test_normalize_target_handles_empty():
    assert normalize_target("sms", "") == ""
    assert normalize_target("email", "   ") == ""


# --------------------------------------------------------------- is_code_valid


def _code_row(**overrides):
    row = {
        "channel": "sms",
        "target": "+8613800138000",
        "code": "123456",
        "tries": 0,
        "created_at": 1000,
        "expires_at": 2000,
        "consumed_at": None,
    }
    row.update(overrides)
    return row


def test_is_code_valid_ok():
    assert is_code_valid(_code_row(), now_ms=1500, code="123456") == (True, "ok")


def test_is_code_valid_rejects_consumed():
    row = _code_row(consumed_at=1200)
    assert is_code_valid(row, now_ms=1500, code="123456") == (False, "consumed")


def test_is_code_valid_rejects_expired():
    row = _code_row(expires_at=1200)
    assert is_code_valid(row, now_ms=1500, code="123456") == (False, "expired")


def test_is_code_valid_rejects_too_many_tries():
    row = _code_row(tries=CODE_MAX_TRIES)
    assert is_code_valid(row, now_ms=1500, code="123456") == (False, "too_many_tries")


def test_is_code_valid_rejects_mismatch():
    assert is_code_valid(_code_row(), now_ms=1500, code="000000") == (False, "mismatch")


def test_is_code_valid_rejects_empty_code_as_mismatch():
    assert is_code_valid(_code_row(), now_ms=1500, code="") == (False, "mismatch")


def test_is_code_valid_boundary_exactly_at_expiry_still_valid():
    # 边界归用户：卡点到达不算过期。
    assert is_code_valid(_code_row(expires_at=1500), now_ms=1500, code="123456") == (True, "ok")


def test_is_code_valid_one_below_limit_still_valid():
    row = _code_row(tries=CODE_MAX_TRIES - 1)
    assert is_code_valid(row, now_ms=1500, code="123456") == (True, "ok")


def test_is_code_valid_consumed_takes_priority_over_expired():
    # 已消费优先于过期：给客户端的原因要能反映「这条码已经用掉了」，
    # 否则用户会用一条旧码反复重试。
    row = _code_row(consumed_at=1100, expires_at=1200)
    assert is_code_valid(row, now_ms=1500, code="123456") == (False, "consumed")


# --------------------------------------------------------------- role_can


@pytest.mark.parametrize(
    ("role", "action", "expected"),
    [
        # owner：全都能做
        ("owner", "read", True),
        ("owner", "write_data", True),
        ("owner", "edit_profile", True),
        ("owner", "invite", True),
        ("owner", "delete_pet", True),
        # editor：能读写数据、改档案，不能管成员、不能删宠物
        ("editor", "read", True),
        ("editor", "write_data", True),
        ("editor", "edit_profile", True),
        ("editor", "invite", False),
        ("editor", "delete_pet", False),
        # viewer：只能读
        ("viewer", "read", True),
        ("viewer", "write_data", False),
        ("viewer", "edit_profile", False),
        ("viewer", "invite", False),
        ("viewer", "delete_pet", False),
    ],
)
def test_role_can_full_matrix(role, action, expected):
    assert role_can(role, action) is expected


def test_role_can_denies_unknown_role_and_action():
    # 默认拒绝：新增角色忘了登记时，得到的是「用不了」而不是「全放行」。
    assert role_can("admin", "read") is False
    assert role_can("owner", "drop_database") is False
    assert role_can("", "") is False


# --------------------------------------------------------------- hash_token / 生成


def test_hash_token_is_stable():
    assert hash_token("abc") == hash_token("abc")


def test_hash_token_is_deterministic_sha256_hex():
    # 固定向量：锁住算法，避免以后有人「顺手」换成别的哈希导致所有旧令牌失效。
    assert hash_token("abc") == (
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )


def test_hash_token_does_not_leak_plaintext():
    raw = new_token()
    assert hash_token(raw) != raw
    assert len(hash_token(raw)) == 64


def test_hash_token_differs_for_different_input():
    assert hash_token("a") != hash_token("b")


def test_generate_code_is_six_digits():
    for _ in range(500):
        code = generate_code()
        assert len(code) == 6
        assert code.isdigit()


def test_generate_code_can_produce_leading_zeros_form():
    # 只验证格式（补零到 6 位），不赌它一定抽到小数字。
    assert len(generate_code()) == 6


def test_new_token_is_unpredictable_and_nonempty():
    tokens = {new_token() for _ in range(100)}
    assert len(tokens) == 100  # 无碰撞
    assert all(len(t) >= 32 for t in tokens)
