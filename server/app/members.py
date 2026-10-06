"""共养：邀请 / 成员列表 / 接受 / 移除。

共养是「一只宠物多个人读写」，权限全部落在 `members` 表上（见协议第四节）。
两条容易被忽略的规则在这里显式实现：
- 邀请目标必须是**已注册用户**（协议 5.3）：不做短信邀请裂变。理由是
  群发短信要模板报备，用户量不够时是纯成本，且会给陌生人发通知。
- `pending` 期间没有任何读权限：邀请只是「发起一个请求」，不是授权。
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .auth import current_user
from .changes import member_payload, record_change, resolve_role
from .db import get_session
from .models import Member, Pet, SyncChange, User
from .sync_logic import normalize_target, now_ms, role_can

router = APIRouter(tags=["members"])


class InviteIn(BaseModel):
    channel: str = Field(pattern="^(sms|email)$")
    target: str = Field(min_length=1, max_length=128)
    # 只能邀请 editor / viewer：owner 是宠物归属的唯一凭证，
    # 靠邀请再产生一个 owner 会让「谁是主人」变成不可判定。
    role: str = Field(pattern="^(editor|viewer)$")


def _require_role(session: Session, pet_id: str, user: User, action: str) -> None:
    """校验权限，不足则 403。

    统一走 role_can（矩阵只有一份），不在各接口里手写 if role != "owner"，
    否则以后权限矩阵调整时总会漏掉某个接口。
    """
    role = resolve_role(session, pet_id, user.id)
    if role is None or not role_can(role, action):
        raise HTTPException(status_code=403, detail="forbidden")


@router.post("/pets/{pet_id}/members/invite")
def invite_member(
    pet_id: str,
    payload: InviteIn,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """邀请一个已注册用户共养。"""
    _require_role(session, pet_id, user, "invite")

    target = normalize_target(payload.channel, payload.target)
    if payload.channel == "sms":
        invited = session.execute(select(User).where(User.phone == target)).scalars().first()
    else:
        invited = session.execute(select(User).where(User.email == target)).scalars().first()
    if invited is None:
        # 明确提示「让对方先注册」，而不是默默发一条永远收不到的邀请 ——
        # 后者会让用户以为已经邀请成功，等几天发现对方根本没收到。
        raise HTTPException(status_code=404, detail="target user not registered")

    existing = (
        session.execute(
            select(Member).where(
                Member.pet_id == pet_id,
                Member.user_id == invited.id,
            )
        )
        .scalars()
        .first()
    )
    if existing is not None and existing.deleted_at is None:
        detail = "already a member" if existing.status == "active" else "already invited"
        raise HTTPException(status_code=409, detail=detail)

    now = now_ms()
    # joined_at 先记邀请时间；接受时会被改成真正加入的时间（见 accept）。
    if existing is None:
        member = Member(pet_id=pet_id, user_id=invited.id, role=payload.role,
                        status="pending", joined_at=now)
        session.add(member)
    else:
        # UNIQUE(pet_id,user_id) 包含已软删行，重邀必须复用原行。
        member = existing
        member.role = payload.role
        member.status = "pending"
        member.joined_at = now
        member.deleted_at = None
    session.flush()

    # 成员变更要进同步日志（pet_id 用该宠物），否则其他设备看不到新人。
    record_change(
        session,
        table_name="members",
        row_id=member.id,
        op="upsert",
        pet_id=pet_id,
        user_id=user.id,
        payload=member_payload(member, now),
        changed_at=now,
    )
    session.commit()

    return {"invite_id": member.id, "sent": True}


@router.get("/pets/{pet_id}/members")
def list_members(
    pet_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> list[dict]:
    """成员列表。任何有效成员（含 viewer）都能看。"""
    _require_role(session, pet_id, user, "read")

    rows = session.execute(
        select(Member, User)
        .join(User, Member.user_id == User.id)
        .where(Member.pet_id == pet_id, Member.deleted_at.is_(None))
        .order_by(Member.joined_at)
    ).all()

    return [
        {
            "user_id": member.user_id,
            "nickname": member_user.nickname,
            "role": member.role,
            "joined_at": member.joined_at,
            "status": member.status,
        }
        for member, member_user in rows
    ]


@router.get("/members/invites/mine")
def my_invites(
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> list[dict]:
    """我收到的、还没接受的邀请。

    **为什么必须单独有这个接口**：被邀请人此时还不是 `active` 成员，
    `/sync/pull` 的可见性过滤会把他自己那条 `members` 变更挡在外面 ——
    光靠同步，他永远不知道自己被邀请了。

    这里不需要在邀请上另存 target：邀请发出时已经把手机号/邮箱解析成了
    user_id，按 user_id 查即可（见 invite_member）。
    """
    rows = session.execute(
        select(Member, Pet)
        .join(Pet, Member.pet_id == Pet.id)
        .where(
            Member.user_id == user.id,
            Member.status == "pending",
            Member.deleted_at.is_(None),
            Pet.deleted_at.is_(None),
        )
        .order_by(Member.joined_at.desc())
    ).all()

    return [
        {
            "invite_id": member.id,
            "pet_id": member.pet_id,
            "pet_name": pet.name,
            "role": member.role,
            "status": member.status,
            "invited_at": member.joined_at,
        }
        for member, pet in rows
    ]


@router.post("/members/invites/{invite_id}/accept")
def accept_invite(
    invite_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """接受邀请：pending → active。"""
    member = session.get(Member, invite_id)
    if member is None or member.deleted_at is not None:
        raise HTTPException(status_code=404, detail="invite not found")
    if member.user_id != user.id:
        # 别人的邀请轮不到我来接受。
        raise HTTPException(status_code=403, detail="not your invite")

    if member.status == "active":
        # 幂等：客户端重试、或两台设备同时点接受，都当成成功。
        return {"ok": True}

    now = now_ms()
    member.status = "active"
    member.joined_at = now  # 这一刻才算真正加入
    record_change(
        session,
        table_name="members",
        row_id=member.id,
        op="upsert",
        pet_id=member.pet_id,
        user_id=user.id,
        payload=member_payload(member, now),
        changed_at=now,
    )
    # 授权前各设备已推进全局游标，旧宠物数据当时被过滤掉了。
    # 重发每行最新快照（含墓碑），保留 LWW 时间戳。
    # 已有成员幂等跳过，新成员的所有设备都能接到历史。
    session.flush()
    latest_seqs = (select(func.max(SyncChange.seq))
                   .where(SyncChange.pet_id == member.pet_id)
                   .group_by(SyncChange.table_name, SyncChange.row_id))
    snapshots = session.execute(
        select(SyncChange).where(SyncChange.seq.in_(latest_seqs))
        .order_by(SyncChange.seq)
    ).scalars().all()
    for snapshot in snapshots:
        record_change(session, table_name=snapshot.table_name, row_id=snapshot.row_id,
                      op=snapshot.op, pet_id=snapshot.pet_id, user_id=snapshot.user_id,
                      payload=dict(snapshot.payload), changed_at=snapshot.changed_at)
    session.commit()
    return {"ok": True}


@router.delete("/pets/{pet_id}/members/{user_id}")
def remove_member(
    pet_id: str,
    user_id: str,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """移除成员。只有 owner 能做（协议权限矩阵）。"""
    _require_role(session, pet_id, user, "invite")

    member = (
        session.execute(
            select(Member).where(
                Member.pet_id == pet_id,
                Member.user_id == user_id,
                Member.deleted_at.is_(None),
            )
        )
        .scalars()
        .first()
    )
    if member is None:
        raise HTTPException(status_code=404, detail="member not found")

    if member.role == "owner":
        # 不允许移除最后一个 owner：否则这只宠物会变成没人能邀请/删除的
        # 孤儿数据，而协议里没有「认领」流程可以救回来。
        other_owners = session.execute(
            select(func.count())
            .select_from(Member)
            .where(
                Member.pet_id == pet_id,
                Member.role == "owner",
                Member.status == "active",
                Member.deleted_at.is_(None),
                Member.user_id != user_id,
            )
        ).scalar_one()
        if other_owners == 0:
            raise HTTPException(status_code=400, detail="cannot remove the last owner")

    now = now_ms()
    member.deleted_at = now  # 软删：硬删会让离线设备把已移除的成员「复活」
    record_change(
        session,
        table_name="members",
        row_id=member.id,
        op="delete",
        pet_id=pet_id,
        user_id=user.id,
        payload=member_payload(member, now),
        changed_at=now,
    )
    session.commit()
    return {"ok": True}
