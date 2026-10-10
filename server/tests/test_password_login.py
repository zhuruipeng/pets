"""密码登录的回归测试。

守两点：① 密码永远只存 bcrypt 哈希、不落明文；② 密码登录失败时
不泄露「号码是否注册过 / 是否设过密码」——三种情况统一返回 401。

纯函数（hash_password / verify_password）直接测；接口用 mock session
测分支（与 test_sync_push_bootstrap.py 一致，不依赖真实数据库）。
"""

from __future__ import annotations

from unittest.mock import Mock

import pytest
from fastapi import HTTPException

from app.auth import (
    PasswordLoginIn,
    PasswordSetIn,
    hash_password,
    password_login,
    set_password,
    verify_password,
)
from app.models import User


def _user(phone: str = "+8613800138000") -> User:
    return User(
        id="u1",
        nickname="n",
        phone=phone,
        region="cn",
        created_at=0,
        updated_at=0,
    )


class TestHashVerify:
    def test_roundtrip(self) -> None:
        h = hash_password("secret123")
        assert h != "secret123"  # 不是明文
        assert verify_password("secret123", h) is True

    def test_wrong_password(self) -> None:
        h = hash_password("secret123")
        assert verify_password("wrong", h) is False

    def test_empty_hash_returns_false(self) -> None:
        # 没设过密码的用户，verify 直接 False，不抛异常。
        assert verify_password("anything", None) is False

    def test_garbage_hash_does_not_crash(self) -> None:
        # 库里存了非 bcrypt 串（脏数据），当不匹配处理，别让接口 500。
        assert verify_password("anything", "not-a-bcrypt-hash") is False

    def test_salt_differs(self) -> None:
        # 同一明文两次哈希结果不同（随机盐），避免「同密码同哈希」便于撞库。
        assert hash_password("secret123") != hash_password("secret123")


class TestSetPassword:
    def test_sets_hash_not_plaintext(self) -> None:
        session = Mock()
        user = _user()
        set_password(PasswordSetIn(password="secret123"), user, session)
        assert user.password_hash != "secret123"
        assert user.password_hash is not None
        assert user.password_hash.startswith("$2")
        session.commit.assert_called_once()

    def test_short_password_rejected(self) -> None:
        # Pydantic 校验：<6 位直接 422，不会走到业务逻辑。
        with pytest.raises(Exception):
            PasswordSetIn(password="123")


class TestPasswordLogin:
    def test_success_issues_token(self) -> None:
        session = Mock()
        user = _user()
        user.password_hash = hash_password("secret123")
        session.execute.return_value.scalars.return_value.first.return_value = user
        # 签发前会跑一次令牌清理（`_prune_tokens`），它走 `.all()`。
        # Mock 默认返回的 Mock 不可迭代，这里显式给空列表 —— 表示
        # 「这个用户手上还没有多余令牌」，是签发的正常路径。
        session.execute.return_value.scalars.return_value.all.return_value = []
        settings = Mock()
        settings.token_ttl_days = 30

        resp = password_login(
            PasswordLoginIn(channel="sms", target="13800138000", password="secret123"),
            session,
            settings,
        )

        assert "token" in resp
        assert resp["user"]["id"] == "u1"

    def test_unknown_target_401(self) -> None:
        session = Mock()
        session.execute.return_value.scalars.return_value.first.return_value = None
        settings = Mock()

        with pytest.raises(HTTPException) as exc:
            password_login(
                PasswordLoginIn(channel="sms", target="13800138000", password="x"),
                session,
                settings,
            )
        assert exc.value.status_code == 401
        assert exc.value.detail == "invalid phone/email or password"

    def test_wrong_password_401_same_message(self) -> None:
        # 号存在但密码错，与「号不存在」返回**同一句话**，不泄露注册状态。
        session = Mock()
        user = _user()
        user.password_hash = hash_password("correct")
        session.execute.return_value.scalars.return_value.first.return_value = user
        settings = Mock()

        with pytest.raises(HTTPException) as exc:
            password_login(
                PasswordLoginIn(channel="sms", target="13800138000", password="wrong"),
                session,
                settings,
            )
        assert exc.value.status_code == 401
        assert exc.value.detail == "invalid phone/email or password"

    def test_no_password_set_401(self) -> None:
        # 号存在但没设过密码（password_hash 为空），同样统一 401。
        session = Mock()
        user = _user()  # password_hash 为 None
        session.execute.return_value.scalars.return_value.first.return_value = user
        settings = Mock()

        with pytest.raises(HTTPException) as exc:
            password_login(
                PasswordLoginIn(channel="sms", target="13800138000", password="x"),
                session,
                settings,
            )
        assert exc.value.status_code == 401
