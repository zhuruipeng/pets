"""SQLAlchemy 模型。字段与客户端 schema.dart 严格对齐。

对齐检查清单（任何一侧改动都要同步另一侧）：
- 时间一律 BIGINT（毫秒时间戳）
- 布尔一律 Boolean（PostgreSQL 原生）
- 所有业务表带 deleted_at，软删除
- payload 为 JSONB
"""

from __future__ import annotations

import uuid

from sqlalchemy import (
    BigInteger,
    Boolean,
    Column,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, relationship


def _uuid() -> str:
    return str(uuid.uuid4())


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"

    id = Column(String(36), primary_key=True, default=_uuid)
    nickname = Column(String(64), nullable=False)
    phone = Column(String(32), nullable=True)
    email = Column(String(128), nullable=True)
    avatar_url = Column(Text)
    # 联系方式（M5）。手机/邮箱可以用来登录并做唯一键，微信与自由文本
    # 只用于「共养时怎么联系到人」，因此允许为空、也不做唯一约束 ——
    # 好友之间互相填同一个微信号是正常情况，不该拦。
    wechat = Column(String(64), nullable=True)
    contact_note = Column(Text, nullable=True)
    # 数据分区标记。注册时按 region 写入，之后不迁移。
    region = Column(String(8), nullable=False, default="intl")
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False)

    memberships = relationship("Member", back_populates="user")


class Pet(Base):
    __tablename__ = "pets"

    id = Column(String(36), primary_key=True, default=_uuid)
    name = Column(String(64), nullable=False)
    species = Column(String(16), nullable=False)  # dog / cat / other
    breed = Column(String(64))
    gender = Column(String(16))
    birthday = Column(BigInteger)
    birthday_estimated = Column(Boolean, nullable=False, default=False)
    adopt_date = Column(BigInteger)
    avatar_url = Column(Text)
    weight_baseline = Column(Float)
    neutered = Column(Boolean, nullable=False, default=False)
    chip_no = Column(String(64))
    color = Column(String(64))
    allergy = Column(Text)
    note = Column(Text)
    # 个性特点。与客户端一致：JSON 数组的字符串形式（如 '["friendly"]'）。
    # 用 JSONB 会更好，但客户端是 sqflite 里存 TEXT，两边形态要能原样对上，
    # M6 做同步时才不用写转换层。
    personality = Column(Text)
    archived_at = Column(BigInteger)

    created_by = Column(String(36), ForeignKey("users.id"), nullable=False)
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)

    members = relationship("Member", back_populates="pet", cascade="all, delete-orphan")
    records = relationship("PetRecord", back_populates="pet")


class Member(Base):
    __tablename__ = "members"
    __table_args__ = (UniqueConstraint("pet_id", "user_id"),)

    id = Column(String(36), primary_key=True, default=_uuid)
    pet_id = Column(String(36), ForeignKey("pets.id"), nullable=False)
    user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    role = Column(String(16), nullable=False)  # owner / editor / viewer
    # 邀请发出时先落成 pending，被邀请人接受后才转 active。
    # 为什么要状态位而不是「邀请时就直接给权限」：邀请不等于授权 ——
    # 有人手滑输错联系方式就把别人拉进来并给了写权限，是数据事故。
    # pending 期间没有任何读权限，权限判定只看 active。
    status = Column(String(16), nullable=False, default="active")  # pending / active
    joined_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)

    pet = relationship("Pet", back_populates="members")
    user = relationship("User", back_populates="memberships")


class PetRecord(Base):
    """统一记录表。type 区分，特有字段进 payload。"""

    __tablename__ = "records"
    __table_args__ = (
        Index("idx_records_pet_time", "pet_id", "recorded_at"),
        Index("idx_records_pet_type", "pet_id", "type", "recorded_at"),
    )

    id = Column(String(36), primary_key=True, default=_uuid)
    pet_id = Column(String(36), ForeignKey("pets.id"), nullable=False)
    type = Column(String(32), nullable=False)
    recorded_at = Column(BigInteger, nullable=False)  # 事件发生时间
    value_num = Column(Float)
    value_text = Column(Text)
    unit = Column(String(16))
    payload = Column(JSONB)
    note = Column(Text)
    created_by = Column(String(36), nullable=False)
    created_at = Column(BigInteger, nullable=False)  # 入库时间，与上面区分
    updated_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)

    pet = relationship("Pet", back_populates="records")


class Attachment(Base):
    __tablename__ = "attachments"

    id = Column(String(36), primary_key=True, default=_uuid)
    record_id = Column(String(36), ForeignKey("records.id"), nullable=False)
    kind = Column(String(16), nullable=False)  # photo / file
    local_path = Column(Text)
    remote_url = Column(Text)
    width = Column(Integer)
    height = Column(Integer)
    created_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)


class Reminder(Base):
    __tablename__ = "reminders"
    __table_args__ = (Index("idx_reminders_pet_next", "pet_id", "next_at"),)

    id = Column(String(36), primary_key=True, default=_uuid)
    pet_id = Column(String(36), ForeignKey("pets.id"), nullable=False)
    type = Column(String(32), nullable=False)
    title = Column(Text, nullable=False)
    rule = Column(JSONB, nullable=False)
    next_at = Column(BigInteger, nullable=False)
    enabled = Column(Boolean, nullable=False, default=True)
    source = Column(String(16))  # auto / manual
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)


class ReminderLog(Base):
    __tablename__ = "reminder_logs"
    __table_args__ = (UniqueConstraint("reminder_id", "due_at"),)

    id = Column(String(36), primary_key=True, default=_uuid)
    reminder_id = Column(String(36), ForeignKey("reminders.id"), nullable=False)
    due_at = Column(BigInteger, nullable=False)
    done_at = Column(BigInteger)
    record_id = Column(String(36))
    action = Column(String(16))  # done / skipped / snoozed


class WalkSession(Base):
    __tablename__ = "walk_sessions"
    __table_args__ = (Index("idx_walk_sessions_pet", "pet_id", "started_at"),)

    id = Column(String(36), primary_key=True, default=_uuid)
    pet_id = Column(String(36), ForeignKey("pets.id"), nullable=False)
    started_at = Column(BigInteger, nullable=False)
    ended_at = Column(BigInteger)
    distance_m = Column(Float, nullable=False, default=0)
    duration_s = Column(Integer, nullable=False, default=0)
    region = Column(String(8), nullable=False)
    created_by = Column(String(36), nullable=False)
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)


class WalkPoint(Base):
    """轨迹点。写入最频繁的表，客户端应批量提交，不要逐点请求。"""

    __tablename__ = "walk_points"
    __table_args__ = (Index("idx_walk_points_session", "session_id", "recorded_at"),)

    id = Column(String(36), primary_key=True, default=_uuid)
    session_id = Column(String(36), ForeignKey("walk_sessions.id"), nullable=False)
    lat = Column(Float, nullable=False)
    lng = Column(Float, nullable=False)
    altitude = Column(Float)
    accuracy = Column(Float)
    recorded_at = Column(BigInteger, nullable=False)


class PetTag(Base):
    """用户自购的防丢标签（AirTag / BLE）。我们只登记，不做定位硬件。"""

    __tablename__ = "pet_tags"

    id = Column(String(36), primary_key=True, default=_uuid)
    pet_id = Column(String(36), ForeignKey("pets.id"), nullable=False)
    tag_type = Column(String(16), nullable=False)  # airtag / tile / generic_ble
    tag_name = Column(String(64))
    tag_uid = Column(String(128))
    last_seen_at = Column(BigInteger)
    created_at = Column(BigInteger, nullable=False)
    deleted_at = Column(BigInteger)


# --------------------------------------------------------------- 账号与同步


class AuthToken(Base):
    """登录令牌。

    为什么不用 JWT：令牌必须能**立刻撤销**（换手机、丢手机、被踢下线）。
    JWT 是无状态的，撤销要靠黑名单，等于又建一张表；不如一开始就用
    随机串 + 一行记录，撤销就是写一个 revoked_at。

    为什么存哈希而不是明文：这张表会出现在备份/慢查询日志/运维截图里。
    存明文等于把所有人的有效登录凭证摊在运维视野里。明文只在签发时
    回给客户端一次，之后服务端自己也拿不回来。
    """

    __tablename__ = "auth_tokens"
    __table_args__ = (Index("idx_auth_tokens_user", "user_id"),)

    # 主键是哈希值（sha256 十六进制），不是客户端手里的明文令牌。
    token = Column(Text, primary_key=True)
    user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    device_id = Column(String(64))
    created_at = Column(BigInteger, nullable=False)
    expires_at = Column(BigInteger, nullable=False)
    revoked_at = Column(BigInteger)


class VerifyCode(Base):
    """短信/邮件验证码。两个渠道共用一张表，渠道差异只体现在 channel 与发送实现。

    ip 这一列协议的 DDL 里没有，但限流需要「同一 IP 每小时 20 次」，
    而按 target 计数是另一种口径（同一个人换号就能绕开）。
    为把限流落到数据库（进程重启不丢、多 worker 共享），这里补一列 ip。
    """

    __tablename__ = "verify_codes"
    __table_args__ = (Index("idx_verify_codes_target_time", "target", "created_at"),)

    id = Column(String(36), primary_key=True, default=_uuid)
    channel = Column(String(16), nullable=False)  # sms | email
    target = Column(String(128), nullable=False)  # 手机号（E.164）或邮箱（小写）
    code = Column(String(8), nullable=False)
    purpose = Column(String(16), nullable=False)  # login | bind | invite
    tries = Column(Integer, nullable=False, default=0)
    created_at = Column(BigInteger, nullable=False)
    expires_at = Column(BigInteger, nullable=False)
    consumed_at = Column(BigInteger)
    ip = Column(String(64))


class SyncChange(Base):
    """全局变更日志：所有表的变更都往这一张表塞，客户端只认一个游标 seq。

    为什么不做「每张表一个 synced_at 列」：那样客户端要记住 N 张表各自的
    位置，还要处理「A 表拉到一半、B 表又变了」的交错；一个全局 BIGSERIAL
    游标没有这个问题，代价只是日志表会长 —— 用定期归档解决，不影响协议。

    payload 存**整行快照而不是 diff**：diff 需要双方从同一个历史点出发，
    而离线设备可能落后几百个版本，重放 diff 会一步步错下去；快照是幂等的，
    重复应用同一行结果不变。
    """

    __tablename__ = "sync_changes"
    __table_args__ = (
        Index("idx_sync_changes_seq", "seq"),
        Index("idx_sync_changes_pet", "pet_id", "seq"),
    )

    # BigInteger 主键 + autoincrement 在 PostgreSQL 上渲染成 BIGSERIAL。
    seq = Column(BigInteger, primary_key=True, autoincrement=True)
    table_name = Column(Text, nullable=False)
    row_id = Column(Text, nullable=False)
    op = Column(Text, nullable=False)  # upsert | delete（墓碑）
    pet_id = Column(String(36))  # 分发键；users 行为 NULL
    user_id = Column(String(36), nullable=False)  # 变更发起者，便于排查
    payload = Column(JSONB, nullable=False)  # 行快照，不是 diff
    changed_at = Column(BigInteger, nullable=False)  # 变更发生时间（毫秒）
