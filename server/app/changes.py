"""变更日志与成员角色的公共出口。

为什么单独成模块：往 `sync_changes` 追加变更的入口有三条（客户端 push、
账号改资料 PATCH /me、共养邀请/接受/移除），读「我对某只宠物是什么角色」
的入口更多。日志的写入形态与权限口径必须**只有一份** ——
否则同一条数据从不同路径进来会长得不一样，客户端拉下来就会解析失败，
或者出现「同一个请求在 A 接口有权限、在 B 接口没有」这种前后矛盾的越权。

这里只做「拼语句 + 查一行」，不含业务规则（规则在 sync_logic 里）。
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import select, text
from sqlalchemy.orm import Session

from .models import Member, Pet, SyncChange


# One transaction lock for every log writer. BIGSERIAL allocates before commit;
# without serialization a later seq can become visible before an earlier seq.
_SYNC_WRITE_LOCK = 0x50455453594E43


def lock_sync_writes(session: Session) -> None:
    """Serialize conflict reads and log allocation through transaction commit.

    Production uses PostgreSQL READ COMMITTED. SQLite test databases already
    serialize writes and do not provide PostgreSQL advisory locks.
    """
    if session.get_bind().dialect.name != "postgresql":
        return
    transaction = session.get_transaction()
    if transaction is not None and session.info.get("sync_write_transaction") is transaction:
        return
    session.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": _SYNC_WRITE_LOCK})
    session.info["sync_write_transaction"] = session.get_transaction()


def record_change(
    session: Session,
    *,
    table_name: str,
    row_id: str,
    op: str,
    pet_id: str | None,
    user_id: str,
    payload: dict[str, Any],
    changed_at: int,
) -> SyncChange:
    """把一次变更追加进全局变更日志。

    只 add 不 commit：事务边界由调用方决定。/sync/push 要求整批变更
    一次提交 —— 半批成功半批失败会让客户端 outbox 与服务端状态永久错位。

    changed_at 用的是**这次变更的 LWW 时间戳**（通常就是 payload 里的
    updated_at），不是服务端落库时间。因为客户端拉取时要拿它和本地行的
    updated_at 比大小决定跳不跳；若填服务端时间，离线补传的旧数据会被
    当成「刚刚发生」而覆盖掉本地的新编辑。
    """
    lock_sync_writes(session)
    change = SyncChange(
        table_name=table_name,
        row_id=row_id,
        op=op,
        pet_id=pet_id,
        user_id=user_id,
        payload=payload,
        changed_at=changed_at,
    )
    session.add(change)
    return change


def latest_change(session: Session, table_name: str, row_id: str) -> SyncChange | None:
    """取某行当前的最新快照。

    为什么拿它当 LWW 的「现值」而不是去查业务表：同步载荷是整行快照且
    表结构随客户端演进，服务端要是每张表都建模一遍，加字段就得改两处。
    变更日志本身就是这张行数据的权威现值（payload 即快照）。
    """
    stmt = (
        select(SyncChange)
        .where(SyncChange.table_name == table_name, SyncChange.row_id == row_id)
        .order_by(SyncChange.seq.desc())
        .limit(1)
    )
    return session.execute(stmt).scalars().first()


def resolve_role(session: Session, pet_id: str, user_id: str) -> str | None:
    """查这个人在该宠物上的角色；不是**有效**成员则返回 None。

    只认 status=active 且未软删的行：pending 的邀请不是授权，
    删除的成员关系也不能残留权限。
    """
    stmt = select(Member).where(
        Member.pet_id == pet_id,
        Member.user_id == user_id,
        Member.deleted_at.is_(None),
        Member.status == "active",
    )
    member = session.execute(stmt).scalars().first()
    return member.role if member is not None else None


def active_member_pet_ids(session: Session, user_id: str) -> set[str]:
    """这个人当前可读的全部宠物 id，作为 pull 的可见性白名单。"""
    stmt = select(Member.pet_id).where(
        Member.user_id == user_id,
        Member.deleted_at.is_(None),
        Member.status == "active",
    )
    return set(session.execute(stmt).scalars().all())


def has_any_member(session: Session, pet_id: str) -> bool:
    """这只宠物是否已经有任何成员行（含 pending、含已删）。

    用于「首台设备建宠物」的引导判定：见 sync.push 里的说明。
    """
    stmt = select(Member.id).where(Member.pet_id == pet_id).limit(1)
    return session.execute(stmt).first() is not None


def member_payload(member: Member, changed_at: int) -> dict[str, Any]:
    """members 行的同步快照。

    为什么要显式塞一个 updated_at：members 表本身没有这一列（权限关系
    没有「编辑时间」的语义），但 LWW 需要一个比较基准，否则成员变更
    永远无法参与冲突判定。用本次变更的时间戳充当，等价于「最后被改的时间」。
    """
    return {
        "id": member.id,
        "pet_id": member.pet_id,
        "user_id": member.user_id,
        "role": member.role,
        "status": member.status,
        "joined_at": member.joined_at,
        "deleted_at": member.deleted_at,
        "updated_at": changed_at,
    }


def pet_payload(pet: Pet) -> dict[str, Any]:
    """实体档案的同步快照；布尔值与客户端 SQLite 的 0/1 口径一致。"""
    values = {column.name: getattr(pet, column.name) for column in Pet.__table__.columns}
    return {key: int(value) if isinstance(value, bool) else value
            for key, value in values.items()}
