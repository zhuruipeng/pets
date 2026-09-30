"""数据库连接。中国区与海外区各自独立部署，绝不互连。"""

from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from .config import get_settings
from .models import Base

settings = get_settings()

engine = create_engine(settings.database_url, pool_pre_ping=True, future=True)

SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def init_db() -> None:
    """MVP 阶段直接 create_all。

    上线前应换成 Alembic 迁移——因为「加字段」这种事一定会发生，
    而 create_all 不会改已存在的表。
    """
    Base.metadata.create_all(engine)


def get_session() -> Iterator[Session]:
    with SessionLocal() as session:
        yield session
