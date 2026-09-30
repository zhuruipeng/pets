"""数据库连接。中国区与海外区各自独立部署，绝不互连。"""

from collections.abc import Iterator

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from .config import get_settings
from .models import Base

settings = get_settings()

engine = create_engine(settings.database_url, pool_pre_ping=True, future=True)

SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def _migrate() -> None:
    """轻量迁移：为已存在的表补新列（create_all 不会改已存在的表）。

    这里只放「加一列」这种幂等、可反复执行、不丢数据的迁移，比引入整套
    Alembic 轻。每条都用 `ADD COLUMN IF NOT EXISTS`（PG 支持）保证幂等，
    本地开发、生产 ExecStartPre 都跑这一段，谁都不会重复加。

    注意：SQLite 不支持 `ADD COLUMN IF NOT EXISTS`，但服务端只跑 PG，
    本地纯逻辑测试（mock session）也不触达这里，故无碍。
    """
    with engine.begin() as conn:
        conn.execute(
            text("ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT")
        )


def init_db() -> None:
    """MVP 阶段直接 create_all，再补轻量迁移。

    上线前应换成 Alembic 迁移——因为「加字段」这种事一定会发生，
    而 create_all 不会改已存在的表。眼下用 _migrate 兜住加列。
    """
    Base.metadata.create_all(engine)
    _migrate()


def get_session() -> Iterator[Session]:
    with SessionLocal() as session:
        yield session
