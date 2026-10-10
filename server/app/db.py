"""数据库连接。中国区与海外区各自独立部署，绝不互连。"""

from collections.abc import Iterator

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from .config import get_settings
from .models import Base

settings = get_settings()

# 连接池参数（2026-10-10 代码审查 P1 补）。
#
# 原先只写了 `pool_pre_ping=True`，其余全用 SQLAlchemy 默认值。默认值在
# 这里有两个具体问题：
#
# 1. **`pool_recycle` 默认 -1（永不回收）**。
#    PostgreSQL 侧有 `idle_in_transaction_session_timeout` / 云厂商的
#    NAT / 防火墙空闲超时，会**单方面**把连接掐掉。服务端不知道，池子里
#    留着的是一条已经死掉的 socket，下次借出去就报
#    `server closed the connection unexpectedly`。
#    这类错误的特点是「偶发、重启就好、抓不到规律」—— 因为它取决于
#    两次请求之间的空闲时长。
#    `pool_pre_ping` 能挡住大部分（借出前先 ping），但它在 pool 满、
#    连接被并发借出时会漏，且 ping 本身要一次往返。设成 30 分钟回收
#    是更根本的兜底：**保证连接不会被闲置到对方先超时**。取 1800 秒
#    是因为腾讯云 PG 的默认空闲断开在 1 小时量级，取一半留足余量。
#
# 2. **`pool_size` 默认 5 / `max_overflow` 默认 10**。
#    生产是 2 个 gunicorn worker，每个 worker 一个独立进程、各有一个池，
#    所以实际上限是 2 × (5 + 10) = 30 条连接。我们用的是最低配的 PG
#    实例（连接数上限通常 100，还要给备份/运维留），30 条已经吃掉了
#    可观比例；而且真打到 30 条并发时，瓶颈早就不在数据库了。
#    收紧到 3 + 5 = 8/worker，全局 16 条，够用且把上限钉死。
#
# 顺带 `pool_timeout=10`：默认 30 秒意味着池子被占满时，一个请求会
# **静默挂 30 秒**才报错。对移动端用户来说 10 秒已经是「卡住了」，
# 早点返回 500 让客户端重试体验更好。
engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_recycle=1800,
    pool_size=3,
    max_overflow=5,
    pool_timeout=10,
    future=True,
)

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
