"""多设备同步：push / pull。

这是协议里唯一「两边都会写」的接口，所以每个决定都偏向保守：
- push 幂等、与顺序无关：客户端 outbox 是按 updated_at 排的，但补传/重传
  会打乱顺序，服务端不能假设顺序。
- pull 的可见范围在服务端算：客户端不可信。
- 整批 push 一个事务：半批成功会让客户端 outbox 和服务端状态永久错位。
"""

from __future__ import annotations

import json
import math
from typing import Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .auth import current_user
from .changes import (
    active_member_pet_ids,
    has_any_member,
    latest_change,
    member_payload,
    record_change,
    resolve_role,
)
from .db import get_session
from .models import Member, Pet, PetRecord, SyncChange, User
from .sync_logic import is_newer, now_ms, role_can, visible_to

router = APIRouter(tags=["sync"])

# 允许同步的表。walk_points 不在其中：轨迹点作为 walk_sessions.points
# 随会话一起传（见协议第三节），逐行同步会把变更日志撑爆。
SYNC_TABLES = frozenset(
    {
        "users",
        "pets",
        "members",
        "records",
        "attachments",
        "reminders",
        "reminder_logs",
        "expenses",
        "walk_sessions",
        "pet_tags",
    }
)

# 写不同表需要的权限不同：改档案是 edit_profile，改成员是 invite，
# 其余数据写入是 write_data。默认落 write_data，漏配的表不会变成「人人可写」。
_TABLE_ACTION = {
    "pets": "edit_profile",
    "members": "invite",
}

PULL_DEFAULT_LIMIT = 200
PULL_MAX_LIMIT = 500


class PushChangeIn(BaseModel):
    table: str
    row_id: str
    op: str = "upsert"
    # 客户端本地的 LWW 时间戳。服务端不信任它的「真实性」，但必须用它做比较：
    # 换成服务端接收时间会把离线补传的旧数据判成新数据。
    updated_at: int
    payload: dict[str, Any] = Field(default_factory=dict)


class PushIn(BaseModel):
    device_id: str | None = Field(default=None, max_length=64)
    changes: list[PushChangeIn] = Field(default_factory=list)


def _pet_id_of(change: PushChangeIn) -> str | None:
    """从变更里取出分发键 pet_id。

    pets 行没有 pet_id 列（它自己就是宠物），所以取行 id；
    users 行不属于任何宠物，取 None。其余业务行都带 pet_id。
    """
    if change.table == "users":
        return None
    if change.table == "pets":
        return change.row_id
    return change.payload.get("pet_id")


def _action_for(change: PushChangeIn) -> str:
    if change.table == "pets" and (change.op == "delete" or
                                  change.payload.get("deleted_at") is not None):
        return "delete_pet"
    return _TABLE_ACTION.get(change.table, "write_data")


def _rejected(change: PushChangeIn, result: str) -> dict:
    return {"table": change.table, "row_id": change.row_id, "result": result}


# pets 实体表需要哪些列。落实体表时按这份白名单从 payload 里取，
# 而不是 `Pet(**payload)` 全量透传：客户端 schema 会演进（现在已有
# 服务端没有的 `tier` 列），透传会让一个新增字段直接把同步炸成 500。
_PET_ENTITY_COLUMNS = frozenset(
    {
        "name",
        "species",
        "breed",
        "gender",
        "birthday",
        "birthday_estimated",
        "adopt_date",
        "avatar_url",
        "weight_baseline",
        "neutered",
        "chip_no",
        "color",
        "allergy",
        "note",
        "personality",
        "archived_at",
        "created_by",
        "created_at",
        "updated_at",
        "deleted_at",
    }
)


def _ensure_pet_row(session: Session, payload: dict[str, Any]) -> None:
    """幂等地把一只宠物落进 pets 实体表。

    为什么要有这一步：members 等实体表带 `pet_id → pets.id` 的外键，
    但同步只往 sync_changes 写快照、不落实体表（客户端走本地 SQLite，
    宠物创建后不调 /pets REST）。于是引导 owner 成员行时，外键指向的
    pets 行还不存在，直接炸 ForeignKeyViolation。这里在需要时先把
    pets 实体行补上，重复推不重复插。

    为什么「只在有更完整/更新的快照时才更新」：宠物名、生日这些字段
    可能被后来的同步改掉，实体表不能一直停留在首次落的那一版，否则
    list_pets / get_pet 这些 REST 接口返回的是陈旧档案。
    """
    pet_id = payload.get("id")
    if not pet_id:
        return
    # id 单独用 pet_id 传，不放进 values —— payload 里也带 id，白名单含 id
    # 会让 Pet(id=..., **values) 出现重复关键字参数。
    values = {k: v for k, v in payload.items() if k in _PET_ENTITY_COLUMNS}
    # created_by / created_at / updated_at 是实体表必填列，快照若缺就用
    # 安全的兜底：created_by 取 payload 里已存在的、时间取 updated_at 或 0。
    existing = session.get(Pet, pet_id)
    if existing is None:
        row = Pet(id=pet_id, **values)
        # 快照里可能没有这些时间列（异常/旧客户端），兜成不抛错的最小值。
        if row.created_at is None:
            row.created_at = int(values.get("updated_at") or 0)
        if row.updated_at is None:
            row.updated_at = int(values.get("updated_at") or 0)
        if row.created_by is None:
            row.created_by = ""
        session.add(row)
    else:
        # 已有实体行：仅当本次快照确实更新才覆盖，避免旧数据回写。
        incoming_ts = values.get("updated_at")
        if incoming_ts is not None and incoming_ts >= (existing.updated_at or 0):
            for k, v in values.items():
                setattr(existing, k, v)
    session.flush()


def _bootstrap_owner_if_needed(
    session: Session, change: PushChangeIn, user: User
) -> None:
    """首台设备推宠物时，补一条 owner 成员行。

    为什么必须补：服务端只从 `members` 表读权限。客户端第一次把宠物推上来
    时，这张表和这只宠物还没有任何关系，于是本批次里紧随其后的 records 等
    写入都会「查不到角色」被拒。而客户端无法控制批次内顺序（outbox 是按
    updated_at 排的），所以要在处理整批之前先把它认成 owner。

    凭什么认：这行宠物快照的 created_by 就是我，并且该宠物在服务端
    还没有任何成员行 —— 这两个条件同时成立才认，不是「谁先推谁当 owner」。
    """
    pet_id = _pet_id_of(change)
    if not pet_id or resolve_role(session, pet_id, user.id) is not None:
        return
    if change.payload.get("created_by") != user.id:
        return
    if has_any_member(session, pet_id):
        return
    existing_pet = session.get(Pet, pet_id)
    if existing_pet is not None and existing_pet.created_by != user.id:
        return
    # 只有这行宠物确实更新时才补，避免为一堆过期重传凭空造成员关系。
    current = latest_change(session, "pets", change.row_id)
    current_ts = (current.payload or {}).get("updated_at") if current is not None else None
    if not is_newer(change.updated_at, current_ts):
        return

    now = now_ms()
    # 先落实体表 pets：owner 的 members 行带 pet_id 外键，pets 实体行不存在
    # 就直接 ForeignKeyViolation（首台设备建宠物时必然触发）。
    _ensure_pet_row(session, change.payload)
    owner = Member(
        pet_id=pet_id,
        user_id=user.id,
        role="owner",
        status="active",
        joined_at=now,
    )
    session.add(owner)
    session.flush()
    record_change(
        session,
        table_name="members",
        row_id=owner.id,
        op="upsert",
        pet_id=pet_id,
        user_id=user.id,
        payload=member_payload(owner, now),
        changed_at=now,
    )
    session.flush()


@router.post("/sync/push")
def sync_push(
    payload: PushIn,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """接收客户端的一批变更，逐条 LWW 落库。

    返回里 rejected 与 applied 一样重要：客户端要据此清 outbox ——
    stale 也删（服务端已有更新的版本，本地这条推不上去，留着只会卡住队列）。
    """
    applied: list[dict] = []
    rejected: list[dict] = []
    valid_changes: list[PushChangeIn] = []
    for change in payload.changes:
        if (change.table not in SYNC_TABLES or change.op not in ("upsert", "delete")
                or change.payload.get("id", change.row_id) != change.row_id):
            rejected.append(_rejected(change, "invalid"))
            continue
        if change.table == "members":
            # 权限关系只通过邀请/接受/移除接口变更，不能发布与实体表不符的快照。
            rejected.append(_rejected(change, "forbidden"))
            continue
        valid_changes.append(change)

    # 身份校验在引导之前，避免无效载荷先产生 owner 或修改另一只宠物。
    for change in valid_changes:
        if change.table == "pets" and change.op == "upsert":
            normalized = change.model_copy(update={"payload": {
                **change.payload, "id": change.row_id, "updated_at": change.updated_at,
            }})
            _bootstrap_owner_if_needed(session, normalized, user)

    # 附件依赖父记录；同批输入即使附件在前，也先接收 records。
    priority = {"pets": 0, "reminders": 1, "records": 2, "attachments": 3, "reminder_logs": 4}
    for change in sorted(valid_changes, key=lambda item: priority.get(item.table, 2)):

        pet_id = _pet_id_of(change)
        if change.table == "users":
            # 只能改自己那一行。别人的资料不该由客户端推上来。
            if change.row_id != user.id:
                rejected.append(_rejected(change, "forbidden"))
                continue
        else:
            if not pet_id:
                rejected.append(_rejected(change, "invalid"))
                continue
            role = resolve_role(session, pet_id, user.id)
            if role is None or not role_can(role, _action_for(change)):
                rejected.append(_rejected(change, "forbidden"))
                continue

        current = latest_change(session, change.table, change.row_id)
        if current is not None and current.pet_id != pet_id:
            rejected.append(_rejected(change, "forbidden"))
            continue
        if change.table == "attachments":
            record_id = change.payload.get("record_id")
            parent = latest_change(session, "records", record_id) if record_id else None
            if parent is None and record_id:
                parent = session.get(PetRecord, record_id)
            if parent is None or parent.pet_id != pet_id:
                rejected.append(_rejected(change, "forbidden"))
                continue
        if change.table == "reminder_logs":
            reminder_id = change.payload.get("reminder_id")
            due_at = change.payload.get("due_at")
            stock_used = change.payload.get("stock_used", 0)
            parent = latest_change(session, "reminders", reminder_id) if isinstance(reminder_id, str) else None
            if (parent is None or parent.pet_id != pet_id or type(due_at) is not int
                    or change.row_id != f"log_{reminder_id}_{due_at}"
                    or not isinstance(stock_used, (int, float)) or isinstance(stock_used, bool)
                    or not math.isfinite(stock_used) or stock_used < 0
                    or change.payload.get("action") != "done"
                    or type(change.payload.get("done_at")) is not int):
                rejected.append(_rejected(change, "invalid"))
                continue
            # A scheduled occurrence is completed once, even if two offline
            # devices submit it. Preserve the first accepted caregiver and dose.
            if current is not None:
                rejected.append(_rejected(change, "stale"))
                continue
            record_id = change.payload.get("record_id")
            record = latest_change(session, "records", record_id) if isinstance(record_id, str) else None
            if record_id is not None and (record is None or record.pet_id != pet_id):
                rejected.append(_rejected(change, "invalid"))
                continue
        dose_details = None
        if change.table == "records" and change.op == "upsert":
            details = change.payload.get("payload", {})
            if isinstance(details, str):
                try:
                    details = json.loads(details)
                except (ValueError, TypeError):
                    details = {}
            if isinstance(details, dict) and details.get("course_id"):
                course_id, due_at = details["course_id"], details.get("due_at")
                parent = latest_change(session, "reminders", course_id) if isinstance(course_id, str) else None
                if (parent is None or parent.pet_id != pet_id or type(due_at) is not int
                        or change.row_id != f"dose_{course_id}_{due_at}"):
                    rejected.append(_rejected(change, "invalid"))
                    continue
                if current is not None:
                    # Distinguish an edit to the original record from a second
                    # device creating another completion of the same slot.
                    original = current.payload or {}
                    if (current.op == "delete" or type(original.get("created_at")) is not int
                            or change.payload.get("created_at") != original["created_at"]
                            or change.payload.get("created_by") != original.get("created_by")):
                        rejected.append(_rejected(change, "stale"))
                        continue
                else:
                    dose_details = {**details, "actor_name": user.nickname}
        if change.table == "pets":
            existing_pet = session.get(Pet, change.row_id)
            if (existing_pet is not None and change.payload.get("created_by",
                    existing_pet.created_by) != existing_pet.created_by):
                rejected.append(_rejected(change, "forbidden"))
                continue
        current_ts = current.changed_at if current is not None else None
        if not is_newer(change.updated_at, current_ts):
            rejected.append(_rejected(change, "stale"))
            continue

        # payload 原样存：walk_sessions 的轨迹点就在 payload["points"] 里，
        # 不拆到别处（见协议第三节）。拆开会让「整段覆盖」的语义无处落脚。
        snapshot = {**change.payload, "id": change.row_id, "updated_at": change.updated_at}
        if dose_details is not None:
            snapshot["created_by"] = user.id
            snapshot["payload"] = json.dumps(dose_details, ensure_ascii=False)
        if change.table == "reminder_logs" and snapshot.get("created_by") is not None:
            if snapshot.get("actor_name") is not None:
                snapshot["created_by"] = user.id
                snapshot["actor_name"] = user.nickname
            else:
                # Migrated logs can identify the historical author only through
                # a linked record; uploading them does not make the uploader it.
                snapshot["created_by"] = (record.payload or {}).get("created_by") if record is not None else None
        if change.op == "delete":
            snapshot["deleted_at"] = snapshot.get("deleted_at") or change.updated_at
        if change.table == "pets":
            _ensure_pet_row(session, snapshot)
        record_change(
            session,
            table_name=change.table,
            row_id=change.row_id,
            op=change.op,
            pet_id=pet_id,
            user_id=user.id,
            payload=snapshot,
            changed_at=change.updated_at,
        )
        # 立刻 flush：同一批次里对同一行的多条变更要能相互看到，
        # 否则后一条会比较到「批处理开始前」的旧值而错误地也判为 applied。
        session.flush()
        applied.append({"table": change.table, "row_id": change.row_id, "result": "applied"})

    # 整个批次一次提交（get_session 的上下文在异常时回滚）。
    session.flush()
    max_seq = session.execute(select(func.max(SyncChange.seq))).scalar()
    session.commit()

    return {"applied": applied, "rejected": rejected, "server_seq": int(max_seq or 0)}


@router.get("/sync/pull")
def sync_pull(
    since: int = Query(default=0),
    limit: int = Query(default=PULL_DEFAULT_LIMIT),
    table: str | None = Query(default=None),
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """按全局游标拉取变更。"""
    since = max(0, since)
    # 超上限按上限处理而不是报错：客户端把 limit 配大了不该导致同步整体失败。
    limit = max(1, min(limit, PULL_MAX_LIMIT))

    stmt = select(SyncChange).where(SyncChange.seq > since)
    if table:
        stmt = stmt.where(SyncChange.table_name == table)
    rows = session.execute(stmt.order_by(SyncChange.seq.asc()).limit(limit)).scalars().all()

    whitelist = active_member_pet_ids(session, user.id)
    candidates = [
        {
            "seq": row.seq,
            "table": row.table_name,
            "row_id": row.row_id,
            "op": row.op,
            "pet_id": row.pet_id,
            "user_id": row.user_id,
            "payload": row.payload,
            "changed_at": row.changed_at,
        }
        for row in rows
    ]
    visible = visible_to(candidates, whitelist, user.id)

    # 只回协议约定的字段，不外泄 pet_id / user_id（它们是内部分发与审计用的）。
    changes = [
        {
            "seq": item["seq"],
            "table": item["table"],
            "row_id": item["row_id"],
            "op": item["op"],
            "payload": item["payload"],
            "changed_at": item["changed_at"],
        }
        for item in visible
    ]

    if rows:
        next_since = rows[-1].seq
    else:
        # 没有变更时也要推进游标，否则客户端会永远从旧位置重拉，
        # 每次同步都白跑一趟。
        next_since = int(session.execute(select(func.max(SyncChange.seq))).scalar() or since)

    # 语义是「可能还有」：被可见性过滤掉的行也占用了一页的名额，
    # 所以用「原始页是否取满」判断，客户端据此继续拉即可。
    has_more = len(rows) >= limit

    return {"changes": changes, "next_since": int(next_since), "has_more": has_more}
