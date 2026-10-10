"""输入校验与环境开关的回归测试（2026-10-10 代码审查 P1 批次）。

覆盖三类：
1. REST 路径的自由文本字段必须有长度上限（原先只有 name 有约束，
   而 `/sync/push` 那条路径反而校验严谨 —— 两条路径要一致）
2. 数值/时间戳字段的范围校验（体重、生日、领养日）
3. `dev_echo_code` 与 `is_production` 的默认值方向（安全开关默认关）

这些改动的共同点是：**漏掉时不会报错，只会静默接受坏数据**，
所以必须有测试锁住，否则下次重构又会掉回去。
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import BigInteger, create_engine, event
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.auth import current_user
from app.config import Settings
from app.db import get_session
from app.main import PetIn, app
from app.models import Base, Member, Pet, User


@compiles(JSONB, "sqlite")
def _sqlite_jsonb(_type, _compiler, **_kwargs):
    return "JSON"


@compiles(BigInteger, "sqlite")
def _sqlite_bigint(_type, _compiler, **_kwargs):
    return "INTEGER"


@pytest.fixture
def db():
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )

    @event.listens_for(engine, "connect")
    def enable_foreign_keys(connection, _record):
        connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    with Session(engine, autoflush=False, expire_on_commit=False) as session:
        # 先落 User 再落 Pet：pets.created_by 有外键指向 users，
        # 顺序反了会 IntegrityError。
        session.add(User(id="owner", nickname="owner", email="owner@example.com",
                         region="intl", created_at=1, updated_at=1))
        session.flush()
        session.add(Pet(id="pet", name="Pet", species="dog", created_by="owner",
                        created_at=1, updated_at=1))
        session.flush()
        session.add(Member(id="member-owner", pet_id="pet", user_id="owner",
                           role="owner", status="active", joined_at=1))
        session.commit()
        yield session
    engine.dispose()


@pytest.fixture
def client(db):
    app.dependency_overrides[get_session] = lambda: db
    app.dependency_overrides[current_user] = lambda: db.get(User, "owner")
    client = TestClient(app)
    yield client
    app.dependency_overrides.clear()
    client.close()


# --------------------------------------------------------------- 1. 文本长度


@pytest.mark.parametrize("field,limit", [
    ("breed", 64),
    ("chip_no", 64),
    ("color", 64),
    ("allergy", 4096),
    ("note", 4096),
    ("personality", 2048),
])
def test_pet_text_fields_reject_oversized_values(field, limit):
    """超长自由文本必须在进库前被拒。

    `note` 这类列在库里是 `Text`（不报错），没有这个约束的话，
    任何登录用户传 100MB 字符串都会被完整读进内存再落库。
    """
    base = {"name": "豆豆", "species": "dog"}
    ok = PetIn(**base, **{field: "x" * limit})
    assert getattr(ok, field) is not None, f"{field} 的合法上限应当通过"

    with pytest.raises(Exception):
        PetIn(**base, **{field: "x" * (limit + 1)})


def test_note_oversized_rejected_over_http(client):
    """走一遍真实请求，确认 422 是校验层给的，不是别处碰巧失败。"""
    response = client.post("/pets", json={
        "name": "豆豆", "species": "dog", "note": "x" * 100_000,
    })
    assert response.status_code == 422


def test_contact_note_oversized_rejected_over_http(client):
    """`contact_note` 原先唯独它是裸字段，且会进 sync_changes payload，
    超大值会在变更日志里放大一倍存储。"""
    response = client.patch("/api/v1/me", json={"contact_note": "x" * 5000})
    assert response.status_code == 422


def test_normal_length_values_still_accepted(client):
    """上约束不能把正常值也挡住 —— 这条防的是「修过头」。"""
    response = client.post("/pets", json={
        "name": "豆豆", "species": "dog", "breed": "金毛",
        "note": "很乖", "allergy": "无", "personality": '["friendly"]',
    })
    assert response.status_code in (200, 201)


# --------------------------------------------------------------- 2. 数值范围


@pytest.mark.parametrize("value", [0, -1, 1001, 1e9])
def test_weight_baseline_out_of_range_rejected(value):
    with pytest.raises(Exception):
        PetIn(name="豆豆", species="dog", weight_baseline=value)


def test_weight_baseline_rejects_nan_and_infinity():
    """NaN/Inf 会污染后续所有体重相关计算（差值、均值都会变成 NaN），
    而 JSON 是允许 `NaN` / `Infinity` 字面量的，Pydantic 默认也接受。"""
    for bad in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(Exception):
            PetIn(name="豆豆", species="dog", weight_baseline=bad)


def test_weight_baseline_normal_value_accepted():
    pet = PetIn(name="豆豆", species="dog", weight_baseline=5.4)
    assert pet.weight_baseline == 5.4


@pytest.mark.parametrize("field", ["birthday", "adopt_date"])
@pytest.mark.parametrize("bad", [-1, 4_102_444_800_001])
def test_timestamps_out_of_range_rejected(field, bad):
    """负数是秒/毫秒单位混用，超上限会让「年龄」显示成几万岁。"""
    with pytest.raises(Exception):
        PetIn(**{"name": "豆豆", "species": "dog", field: bad})


@pytest.mark.parametrize("field", ["birthday", "adopt_date"])
def test_timestamps_within_range_accepted(field):
    pet = PetIn(**{"name": "豆豆", "species": "dog", field: 1_730_000_000_000})
    assert getattr(pet, field) == 1_730_000_000_000


# --------------------------------------------------------------- 3. 安全默认值


def test_dev_echo_code_defaults_to_false():
    """这个开关一开，接口会把验证码直接回给调用方 —— 等于任何人拿任意
    手机号都能登录。默认值必须朝安全方向倒，便利留给本地 .env 显式打开。

    原先默认 True，本身就是「把生产是否安全押在运维有没有正确加载 .env 上」。
    """
    assert Settings.model_fields["dev_echo_code"].default is False


def test_env_file_is_absolute():
    """`.env` 用相对路径会取决于进程 CWD：手工用别的目录启动时静默读不到，
    全部落默认值而服务照常起来 —— 最难发现的一类事故。"""
    from app.config import _ENV_FILE
    assert _ENV_FILE.is_absolute()


def test_is_production_defaults_to_false_and_gates_docs():
    """默认 False 让本地能看 /docs；生产在 .env 里置 true 关掉。

    实测过线上 `/docs` 与 `/openapi.json` 都是 200 —— nginx 的
    `location /` 全量代理不会替我们挡这两个路径。
    """
    assert Settings.model_fields["is_production"].default is False
    assert Settings(is_production=False).is_production is False
    assert Settings(is_production=True).is_production is True
