"""FastAPI 入口。

中国区与海外区共用这一份代码，通过 REGION 环境变量区分部署。
两区的差异只体现在运行时配置上（合规开关、逆地理服务商），
不体现在业务逻辑分支里——一旦出现 `if region == "cn"` 写在业务代码中，
就说明该差异应该被抽象到 config 或客户端 region.dart。

启动：
    REGION=cn   uvicorn app.main:app --host 0.0.0.0 --port 8000
    REGION=intl uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import time
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .db import get_session, init_db
from .models import Pet


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(
    title="Pet API",
    version="0.1.0",
    lifespan=lifespan,
    docs_url="/docs",
)


def _now_ms() -> int:
    return int(time.time() * 1000)


# --------------------------------------------------------------- 健康检查


@app.get("/health", tags=["meta"])
def health(settings: Settings = Depends(get_settings)) -> dict:
    """部署自检。返回当前区域与合规开关，用于确认 flavor / 环境变量注入正确。"""
    return {
        "status": "ok",
        "region": settings.region,
        "icp_display_required": settings.requires_icp_display,
        "cross_border_allowed": settings.allows_cross_border,  # 恒为 false
    }


# --------------------------------------------------------------- 数据模型


class PetIn(BaseModel):
    name: str = Field(min_length=1, max_length=64)
    species: str = Field(pattern="^(dog|cat|other)$")
    breed: str | None = None
    gender: str | None = Field(default=None, pattern="^(male|female|unknown)$")
    birthday: int | None = None
    birthday_estimated: bool = False
    adopt_date: int | None = None
    weight_baseline: float | None = None
    neutered: bool = False
    chip_no: str | None = None
    color: str | None = None
    allergy: str | None = None
    note: str | None = None


class PetOut(PetIn):
    id: str
    created_by: str
    created_at: int
    updated_at: int
    archived_at: int | None = None


def _to_out(pet: Pet) -> PetOut:
    return PetOut(
        id=pet.id,
        name=pet.name,
        species=pet.species,
        breed=pet.breed,
        gender=pet.gender,
        birthday=pet.birthday,
        birthday_estimated=pet.birthday_estimated,
        adopt_date=pet.adopt_date,
        weight_baseline=pet.weight_baseline,
        neutered=pet.neutered,
        chip_no=pet.chip_no,
        color=pet.color,
        allergy=pet.allergy,
        note=pet.note,
        created_by=pet.created_by,
        created_at=pet.created_at,
        updated_at=pet.updated_at,
        archived_at=pet.archived_at,
    )


# --------------------------------------------------------------- 宠物


@app.get("/pets", response_model=list[PetOut], tags=["pets"])
def list_pets(
    session: Session = Depends(get_session),
    owner: str = Query(..., description="当前用户 id"),
    include_archived: bool = False,
) -> list[PetOut]:
    stmt = select(Pet).where(Pet.deleted_at.is_(None), Pet.created_by == owner)
    if not include_archived:
        stmt = stmt.where(Pet.archived_at.is_(None))
    rows = session.execute(stmt.order_by(Pet.created_at)).scalars().all()
    return [_to_out(p) for p in rows]


@app.post("/pets", response_model=PetOut, status_code=201, tags=["pets"])
def create_pet(
    payload: PetIn,
    session: Session = Depends(get_session),
    owner: str = Query(..., description="当前用户 id"),
) -> PetOut:
    now = _now_ms()
    pet = Pet(**payload.model_dump(), created_by=owner, created_at=now, updated_at=now)
    session.add(pet)
    session.commit()
    session.refresh(pet)
    return _to_out(pet)


@app.get("/pets/{pet_id}", response_model=PetOut, tags=["pets"])
def get_pet(pet_id: str, session: Session = Depends(get_session)) -> PetOut:
    pet = session.get(Pet, pet_id)
    if pet is None or pet.deleted_at is not None:
        raise HTTPException(status_code=404, detail="pet not found")
    return _to_out(pet)


@app.patch("/pets/{pet_id}", response_model=PetOut, tags=["pets"])
def update_pet(
    pet_id: str,
    payload: PetIn,
    session: Session = Depends(get_session),
) -> PetOut:
    pet = session.get(Pet, pet_id)
    if pet is None or pet.deleted_at is not None:
        raise HTTPException(status_code=404, detail="pet not found")

    for key, value in payload.model_dump().items():
        setattr(pet, key, value)
    pet.updated_at = _now_ms()

    session.commit()
    session.refresh(pet)
    return _to_out(pet)


@app.delete("/pets/{pet_id}", status_code=204, tags=["pets"])
def delete_pet(pet_id: str, session: Session = Depends(get_session)) -> None:
    """软删除。同步场景下硬删会丢数据，务必保持这个行为。"""
    pet = session.get(Pet, pet_id)
    if pet is None:
        raise HTTPException(status_code=404, detail="pet not found")
    now = _now_ms()
    pet.deleted_at = now
    pet.updated_at = now
    session.commit()
