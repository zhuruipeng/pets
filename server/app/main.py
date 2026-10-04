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
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import auth, feedback, members, sync, unified
from .config import Settings, get_settings
from .db import get_session, init_db
from .models import Pet


@asynccontextmanager
async def lifespan(_: FastAPI):
    # 本地开发（单进程 `uvicorn app.main:app --reload`）靠这一行自动建表。
    #
    # 生产是多 worker 的 gunicorn，**不能**依赖这里建表：两个 worker 会并发
    # 执行 create_all，表还不存在时必有一个撞上 pg_type_typname_nsp_index
    # 唯一键冲突而 boot 失败（详见 deploy/02-app-setup.sh 里 ExecStartPre 的注释）。
    # 生产由 systemd 的 ExecStartPre 先建好表，这里再跑就是 checkfirst 空转。
    init_db()
    yield


app = FastAPI(
    title="Pet API",
    version="0.1.0",
    lifespan=lifespan,
    docs_url="/docs",
)

# 账号 / 同步 / 共养三组路由都挂在 /api/v1 下（协议第五节）。
# 老的 /health、/pets、/app/version.json 没有版本前缀，保持原样不动：
# 已经上线的客户端调的就是这些无前缀路径，改了等于强制所有人升级。
API_V1 = "/api/v1"
app.include_router(auth.router, prefix=API_V1)
# 用户反馈。**不存库**，只转发到开发者邮箱 —— 理由见 feedback.py 头部。
app.include_router(feedback.router, prefix=API_V1)
app.include_router(unified.router, prefix=API_V1)
app.include_router(sync.router, prefix=API_V1)
app.include_router(members.router, prefix=API_V1)

# ------------------------------------------------------- 法律页面（静态托管）

# 应用商店（国内各家 + Google Play）上架时要求在后台填**一个可公开访问的
# 隐私政策网址**。App 内虽然也内嵌了同一份文本（assets/legal/），但商店
# 要的是 URL，审核方会自己去打开，所以必须有一个能公网访问的页面。
#
# 为什么放在本服务端而不是官网：这是宠物 App 自己的合规材料，跟着服务端
# 一起发布最直接（改文案与改接口在同一次发布里），也不必为了改一句话去动
# 另一个项目（官网 weiyuantool.com 是独立仓库与发布流程）。
LEGAL_DIR = Path(__file__).resolve().parent.parent / "legal"

# URL 段 → 文件名。**必须是白名单**：这段路径来自用户输入，
# 直接拼进 file path 就是目录穿越（`/legal/../app/config.py` 一类）。
# 用字典查表顺带把「URL 里出现 .html 后缀」换成干净的短链接。
#
# key 是「页面 + 语言」，语言默认 zh —— 不带 `?lang=en` 的请求行为与以前完全一致，
# 商店后台里原来填的中文链接不会因为这次改动而 404。
LEGAL_PAGES = {
    "privacy": "privacy-policy.html",
    "terms": "terms-of-use.html",
    "account-deletion": "account-deletion.html",
    "privacy:en": "privacy-policy.en.html",
    "terms:en": "terms-of-use.en.html",
    "account-deletion:en": "account-deletion.en.html",
}

# 常见写法都收进来，省得商店后台填错一个后缀就 404。
LEGAL_ALIASES = {
    "privacy-policy": "privacy",
    "privacy_policy": "privacy",
    "terms-of-use": "terms",
    "terms_of_use": "terms",
    "terms": "terms",
    "delete-account": "account-deletion",
    "account_deletion": "account-deletion",
}

# 英文文件没生成出来时**回落到中文，而不是 404**。
#
# 为什么不用 404：商店审核开着英文链接拿不到页面，会判定「未提供」，
# 直接拒审。而这里回落至少还有一份可读的文本（语言不对，但内容在），
# 是个明显更好看的失败。
LEGAL_EN_FALLBACK = {
    "privacy:en": "privacy",
    "terms:en": "terms",
    "account-deletion:en": "account-deletion",
}


def resolve_legal_slug(slug: str, lang: str = "zh") -> str | None:
    """把 URL 段规整成白名单里的键；不认就返回 None（调用方回 404）。

    容忍大小写、`.html` 后缀与连字符/下划线两种写法，因为这几个变体
    在不同的商店后台输入框里都出现过。规整完仍然必须在白名单里。

    `lang` 只认 `en` 与 `zh`（大小写不敏感），其它值按 zh 处理 ——
    用它拼文件名之前必须落到这两个值之一，否则 `?lang=../../etc/passwd`
    就能拼出穿越路径。
    """
    s = (slug or "").strip().lower()
    if s.endswith(".html"):
        s = s[: -len(".html")]
    s = LEGAL_ALIASES.get(s, s)
    if s not in LEGAL_PAGES and f"{s}:zh" in LEGAL_PAGES:
        s = f"{s}:zh"
    if s not in LEGAL_PAGES:
        return None

    want_en = (lang or "zh").strip().lower() == "en"
    if want_en and ":" not in s:
        en_key = f"{s}:en"
        if en_key in LEGAL_PAGES:
            return en_key
        return s  # 英文版缺失 → 回落中文
    return s


@app.get("/legal/{slug}", response_class=HTMLResponse, tags=["meta"])
def legal_page(slug: str, lang: str = "zh") -> HTMLResponse:
    """隐私政策 / 用户协议 / 注销说明。纯静态，不读数据库、不涉用户数据。

    `?lang=en` 出英文版（给海外版 App 与商店后台填英文链接用）；
    不带或传其它值一律中文 —— `lang` 只在 resolve_legal_slug 里归一化到
    `zh` / `en` 两个值之后才参与拼路径。
    """
    key = resolve_legal_slug(slug, lang)
    if key is None:
        raise HTTPException(status_code=404, detail="page not found")

    path = LEGAL_DIR / LEGAL_PAGES[key]
    if not path.is_file():
        # 英文文件没进镜像时回落中文（商店审核宁可看到语言不对的内容，
        # 也不要 404 —— 404 会被判成「未提供隐私政策」）。
        fb = LEGAL_EN_FALLBACK.get(key)
        if fb and fb != key and (LEGAL_DIR / LEGAL_PAGES[fb]).is_file():
            return HTMLResponse(
                (LEGAL_DIR / LEGAL_PAGES[fb]).read_text(encoding="utf-8")
            )
        # 文件根本没被打进镜像（比如 Dockerfile 只 COPY 了 app/）时，
        # 503 比 404 准确：不是「这个页面不存在」，是「这个部署缺文件」。
        # 商店审核遇到 404 会认为你没提供，遇到 503 至少知道是临时故障。
        raise HTTPException(status_code=503, detail="legal page unavailable")

    return HTMLResponse(path.read_text(encoding="utf-8"))


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


@app.get("/app/version.json", tags=["meta"])
def app_version(settings: Settings = Depends(get_settings)) -> dict:
    """应用内更新的版本清单。

    为什么是接口而不是静态文件：发新版时只改环境变量重启服务即可，
    不必上服务器替换 JSON、也不用担心两区文件不一致（中国区与海外区
    是两个独立部署，静态文件很容易只改了一边）。

    客户端逻辑（见 app/lib/services/app_update_service.dart）：
    - 用 **build** 比大小，version 只用于展示；
    - `localBuild < min_build` → 强制更新，没有「稍后」；
    - **任何字段缺失/格式不对，客户端会静默放弃更新**，
      所以这里宁可返回慢一点也不要抛异常。
    """
    return {
        "version": settings.app_version,
        "build": settings.app_build,
        "url": settings.app_apk_url,
        "notes": settings.app_notes,
        "minBuild": settings.app_min_build,
        "iosStoreUrl": settings.app_ios_store_url or None,
        "region": settings.region,
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
    # 个性特点：与客户端一致的 JSON 数组字符串。
    personality: str | None = None


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
        personality=pet.personality,
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


# 注意这里**故意不写 `-> None` 返回注解**。
#
# 本文件开头有 `from __future__ import annotations`，所有注解都变成字符串，
# FastAPI 会在注册路由时把 `"None"` 求值成 `NoneType` —— 它不等于 Python 的
# `None`，于是 FastAPI 认为这个 204 路由带了一个 response_model，直接断言失败：
#
#     AssertionError: Status code 204 must not have a response body
#
# 报错发生在**导入模块时**，也就是服务根本起不来。而报错信息指向 204 与响应体，
# 完全不提注解的事，很容易被误诊成「204 不能这么写」。
# （`response_class=Response` 也救不了，实测同样断言失败。）
#
# 换个返回注解也不行：写 `-> None` 会让 200 路由在校验响应时要求「必须返回
# None」，返回 dict 就 500。所以这类「什么都不返回」的路由，唯一稳妥的写法
# 就是**不写返回注解**。
@app.delete("/pets/{pet_id}", status_code=204, tags=["pets"])
def delete_pet(pet_id: str, session: Session = Depends(get_session)):
    """软删除。同步场景下硬删会丢数据，务必保持这个行为。"""
    pet = session.get(Pet, pet_id)
    if pet is None:
        raise HTTPException(status_code=404, detail="pet not found")
    now = _now_ms()
    pet.deleted_at = now
    pet.updated_at = now
    session.commit()
