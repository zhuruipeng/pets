"""sync.push 的 owner 引导与 pets 实体表落实的回归测试。

守一个生产事故：客户端首台设备推宠物时，_bootstrap_owner_if_needed
往 members 实体表插 owner 行，但 pets 实体行此前不存在（同步只写
sync_changes 快照，客户端不调 /pets REST）→ 外键 members.pet_id →
pets.id 断裂，整批 push 回滚，客户端看到 500 SyncApiException。

这些测试用 mock session 锁住「写 owner 前必须先落实体表 pets」这个
顺序与分支，不依赖真实数据库（现有测试环境没有 PostgreSQL）。
"""

from __future__ import annotations

from unittest.mock import Mock

import pytest

from app.models import Member, Pet, User
from app.sync import (
    PushChangeIn,
    _bootstrap_owner_if_needed,
    _ensure_pet_row,
)


def _user(user_id: str = "u1") -> User:
    return User(id=user_id, nickname="n", created_at=0, updated_at=0)


def _pet_change(user_id: str = "u1") -> PushChangeIn:
    return PushChangeIn(
        table="pets",
        row_id="p1",
        op="upsert",
        updated_at=1000,
        payload={
            "id": "p1",
            "name": "旺财",
            "species": "dog",
            "created_by": user_id,
            "created_at": 1000,
            "updated_at": 1000,
        },
    )


class TestEnsurePetRow:
    def test_inserts_when_absent(self) -> None:
        session = Mock()
        session.get.return_value = None

        _ensure_pet_row(session, _pet_change().payload)

        session.add.assert_called_once()
        added = session.add.call_args.args[0]
        assert isinstance(added, Pet)
        assert added.id == "p1"
        assert added.name == "旺财"
        assert added.species == "dog"

    def test_no_insert_when_present(self) -> None:
        session = Mock()
        existing = Mock(spec=Pet, updated_at=1000)
        session.get.return_value = existing

        _ensure_pet_row(session, _pet_change().payload)

        session.add.assert_not_called()

    def test_updates_when_incoming_newer(self) -> None:
        session = Mock()
        existing = Pet(id="p1", name="旧名", species="dog",
                       created_at=0, updated_at=500, created_by="u1")
        session.get.return_value = existing

        _ensure_pet_row(session, _pet_change().payload)  # updated_at=1000

        assert existing.name == "旺财"
        assert existing.updated_at == 1000

    def test_does_not_regress_when_incoming_older(self) -> None:
        session = Mock()
        existing = Pet(id="p1", name="新名", species="dog",
                       created_at=0, updated_at=2000, created_by="u1")
        session.get.return_value = existing

        older = _pet_change()
        older.payload["updated_at"] = 500
        older.payload["name"] = "旧名"
        _ensure_pet_row(session, older.payload)

        assert existing.name == "新名"  # 未被旧快照回写

    def test_ignores_unknown_columns(self) -> None:
        # 客户端 schema 已有服务端没有的 tier 列，透传会 TypeError。
        session = Mock()
        session.get.return_value = None
        change = _pet_change()
        change.payload["tier"] = "free"

        _ensure_pet_row(session, change.payload)

        added = session.add.call_args.args[0]
        assert not hasattr(added, "tier") or added.tier != "free"


class TestBootstrapOwnerOrdering:
    def test_ensures_pet_before_member(self) -> None:
        session = Mock()
        session.get.return_value = None  # pets 实体行不存在
        # resolve_role / latest_change 走 .scalars().first()，
        # has_any_member 走 .first()（不带 scalars），都要返回 None
        # 才能让引导走到底。任一返回 truthy Mock 都会提前 return。
        result = Mock()
        result.scalars.return_value.first.return_value = None
        result.first.return_value = None
        result.scalar.return_value = None
        session.execute.return_value = result

        _bootstrap_owner_if_needed(session, _pet_change(), _user())

        added = [c.args[0] for c in session.add.call_args_list]
        # 顺序：pets 实体 → owner 成员 → members 变更日志（record_change 也会 add）。
        assert isinstance(added[0], Pet), "必须先落实体表 pets，再写 owner"
        assert isinstance(added[1], Member), "第二个才是 owner 成员行"
        assert added[1].role == "owner"
        assert added[1].pet_id == "p1"

    def test_skips_when_created_by_is_not_me(self) -> None:
        session = Mock()
        result = Mock()
        result.scalars.return_value.first.return_value = None
        result.first.return_value = None
        session.execute.return_value = result
        # 这行快照的 created_by 是别人 → 不引导、不落实体表、不写 owner。
        change = _pet_change(user_id="someone-else")
        change.payload["created_by"] = "someone-else"

        _bootstrap_owner_if_needed(session, change, _user("me"))

        session.add.assert_not_called()
