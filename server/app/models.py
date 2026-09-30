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
