"""账号：验证码登录、令牌、个人资料。

设计要点（都是「为什么」）：
- **首次验证即注册**：宠物 App 的用户没有耐心填注册表单，登录与注册合成
  一步。代价是「输错一位手机号就注册出一个空账号」——用一个不会自动
  产生数据的空账号来换掉一个注册漏斗，是划算的。
- **令牌可撤销**：见 models.AuthToken 的说明。
- 认证依赖 `current_user` 从这里导出，sync / members 复用同一份实现，
  避免「某条路径忘了校验令牌」。
"""

from __future__ import annotations

import bcrypt
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .changes import record_change
from .config import Settings, get_settings
from .db import get_session
from .models import AuthToken, User, VerifyCode
from .sync_logic import (
    generate_code,
    hash_token,
    is_code_valid,
    new_token,
    normalize_target,
    now_ms,
)

router = APIRouter(tags=["auth"])

# 同一 IP 每小时的验证码请求上限。用数据库计数（不是内存字典）：
# 服务重启、多 worker、多实例都挡得住；内存计数一重启就清零，等于没限。
# 20 次足够一家人在同一个 WiFi 下各自登录，又能把短信轰炸挡在门外。
CODE_HOURLY_LIMIT = 20

# 新账号的默认昵称。空字符串会踩到 nickname NOT NULL，且客户端拿到空名字
# 显示成空白；给一个中性的占位名，用户进设置页再改。
DEFAULT_NICKNAME = "铲屎官"

ONE_HOUR_MS = 3600 * 1000


class CodeRequestIn(BaseModel):
    channel: str = Field(pattern="^(sms|email)$")
    target: str = Field(min_length=1, max_length=128)


class CodeVerifyIn(BaseModel):
    channel: str = Field(pattern="^(sms|email)$")
    target: str = Field(min_length=1, max_length=128)
    code: str = Field(min_length=4, max_length=8)
    device_id: str | None = Field(default=None, max_length=64)


class PasswordSetIn(BaseModel):
    # 6~72：6 是最低可接受强度；72 是 bcrypt 的单次输入上限（超过的部分被
    # 截断，等于允许两个不同密码「看起来都登录成功」，所以显式拦住）。
    password: str = Field(min_length=6, max_length=72)


class PasswordLoginIn(BaseModel):
    # 手机号走统一账号（cn 区）或本地账号；邮箱是 intl 区兜底。
    channel: str = Field(pattern="^(sms|email)$")
    target: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=72)
    device_id: str | None = Field(default=None, max_length=64)


class ProfilePatchIn(BaseModel):
    # 全部可选：PATCH 的语义是「只改传上来的字段」，
    # 用 exclude_unset 区分「没传」和「传了 null」。
    nickname: str | None = Field(default=None, min_length=1, max_length=64)
    phone: str | None = Field(default=None, max_length=32)
    email: str | None = Field(default=None, max_length=128)
    wechat: str | None = Field(default=None, max_length=64)
    contact_note: str | None = None


def user_out(user: User) -> dict:
    """用户对外形态。刻意不含 region 之外的内部字段。

    region 要返回：客户端 onboarding 要按区域展示合规文案（备案号等），
    以服务端为准比自己猜可靠。
    """
    return {
        "id": user.id,
        "nickname": user.nickname,
        "phone": user.phone,
        "email": user.email,
        "avatar_url": user.avatar_url,
        "wechat": user.wechat,
        "contact_note": user.contact_note,
        "region": user.region,
        "created_at": user.created_at,
        "updated_at": user.updated_at,
    }


def hash_password(plain: str) -> str:
    """把明文密码哈希成可入库的串。只存哈希，明文不入库。"""
    return bcrypt.hashpw(plain.encode("utf-8"), bcrypt.gensalt()).decode("ascii")


def verify_password(plain: str, hashed: str | None) -> bool:
    """校验明文密码是否匹配。hashed 为空（没设过密码）时直接 False。"""
    if not hashed:
        return False
    try:
        return bcrypt.checkpw(plain.encode("utf-8"), hashed.encode("ascii"))
    except ValueError:
        # 库里存的不是合法 bcrypt 串（脏数据），当不匹配处理，别让接口崩。
        return False


def _issue_token(
    session: Session, user: User, device_id: str | None, settings: Settings
) -> dict:
    """给 user 签发一个新令牌，返回与 verify_code 一致的响应体。"""
    now = now_ms()
    raw_token = new_token()
    expires_at = now + settings.token_ttl_days * 24 * 60 * 60 * 1000
    session.add(
        AuthToken(
            token=hash_token(raw_token),
            user_id=user.id,
            device_id=device_id,
            created_at=now,
            expires_at=expires_at,
        )
    )
    session.commit()
    session.refresh(user)
    # 明文令牌只在这里出现一次；库里存的是哈希，之后谁（包括我们）都取不回来。
    return {"token": raw_token, "user": user_out(user), "expires_at": expires_at}


def _bearer_token(authorization: str | None) -> str:
    """从 Authorization 头里抠出 Bearer 令牌。

    不用 FastAPI 的 HTTPBearer 是因为它对大小写、前缀格式的宽容度不由我们
    控制；这里自己解析，错误信息也更可控（客户端联调时能一眼看出是没带
    令牌还是格式写错）。
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="missing authorization header")
    parts = authorization.split(None, 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].strip():
        raise HTTPException(status_code=401, detail="malformed authorization header")
    return parts[1].strip()


def _resolve_token(session: Session, authorization: str | None) -> tuple[AuthToken, User]:
    """把请求头里的令牌解析成一个有效会话（令牌行 + 用户）。"""
    raw = _bearer_token(authorization)
    row = session.get(AuthToken, hash_token(raw))
    now = now_ms()
    if row is None or row.revoked_at is not None or row.expires_at <= now:
        # 三种情况合并成同一个错误：不告诉攻击者「这个令牌存在但过期了」，
        # 那等于确认了令牌有效，泄露信息。
        raise HTTPException(status_code=401, detail="invalid or expired token")
    user = session.get(User, row.user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="user not found")
    return row, user


def current_user(
    authorization: str | None = Header(default=None),
    session: Session = Depends(get_session),
) -> User:
    """FastAPI 依赖：拿到当前登录用户，失败抛 401。"""
    _, user = _resolve_token(session, authorization)
    return user


def _dispatch_code(channel: str, target: str, code: str, purpose: str) -> None:
    """把验证码真正发出去（短信/邮件）。**目前是占位实现，什么也不发。**

    TODO(M5)：按 settings.sms_provider / settings.email_provider 分发：
    - 中国区短信必须先做模板报备，未报备的内容会被运营商拦截；
    - 海外区可先用邮件兜底（成本低、无模板限制）；
    - 发送失败**不能让验证码行回滚**：用户没收到可以重发，
      但如果因为发送失败把码也丢了，重发逻辑会因为「查不到刚发的码」而异常。
      所以这里不抛异常，失败只记日志（日志接入在 v2）。
    """
    return None


def _client_ip(request: Request) -> str:
    """取请求来源 IP 用于限流。

    优先取 X-Forwarded-For 的第一段：生产环境服务在 Nginx 后面，
    request.client.host 恒为反代地址，按它限流等于所有用户共用一个额度。
    本地直连（没有该头）时退回 socket 对端地址。
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


@router.post("/auth/code/request")
def request_code(
    payload: CodeRequestIn,
    request: Request,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> dict:
    """发送登录验证码。"""
    target = normalize_target(payload.channel, payload.target)
    if not target:
        raise HTTPException(status_code=400, detail="invalid target")

    now = now_ms()
    ip = _client_ip(request)

    # 同 target 的重发间隔。按 target（而不是按 IP）限：被刷的是这个号码，
    # 换台设备连点照样要挡。
    resend_after = now - settings.code_resend_seconds * 1000
    recent = session.execute(
        select(VerifyCode.id)
        .where(VerifyCode.target == target, VerifyCode.created_at > resend_after)
        .limit(1)
    ).first()
    if recent is not None:
        raise HTTPException(status_code=429, detail="code already sent, please retry later")

    # 按 IP 的小时上限。两道限流互补：前者防单号被刷，后者防一个人
    # 拿号码库批量试探。
    ip_count = session.execute(
        select(func.count())
        .select_from(VerifyCode)
        .where(VerifyCode.ip == ip, VerifyCode.created_at > now - ONE_HOUR_MS)
    ).scalar_one()
    if ip_count >= CODE_HOURLY_LIMIT:
        raise HTTPException(status_code=429, detail="too many requests from this address")

    code = generate_code()
    session.add(
        VerifyCode(
            channel=payload.channel,
            target=target,
            code=code,
            purpose="login",
            tries=0,
            created_at=now,
            expires_at=now + settings.code_ttl_seconds * 1000,
            ip=ip,
        )
    )
    session.commit()

    _dispatch_code(payload.channel, target, code, "login")

    body = {"sent": True, "expires_in": settings.code_ttl_seconds}
    if settings.dev_echo_code:
        # 仅在开发/联调环境回显。上线必须把 dev_echo_code 置 false，
        # 否则响应体里的码等于把账号直接送人。
        body["dev_code"] = code
    return body


@router.post("/auth/code/verify")
def verify_code(
    payload: CodeVerifyIn,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> dict:
    """校验验证码；通过则签发令牌，首次登录顺带注册。"""
    target = normalize_target(payload.channel, payload.target)
    now = now_ms()

    row = (
        session.execute(
            select(VerifyCode)
            .where(
                VerifyCode.channel == payload.channel,
                VerifyCode.target == target,
                VerifyCode.purpose == "login",
            )
            .order_by(VerifyCode.created_at.desc())
            .limit(1)
        )
        .scalars()
        .first()
    )
    if row is None:
        raise HTTPException(status_code=400, detail="no code requested for this target")

    ok, reason = is_code_valid(
        {
            "consumed_at": row.consumed_at,
            "expires_at": row.expires_at,
            "tries": row.tries,
            "code": row.code,
        },
        now,
        payload.code,
    )
    if not ok:
        # 只有「码不对」才累加计数：已消费/已过期/已锁定的码再输错，
        # 不是新的尝试，累加只会让计数语义变得没人看得懂。
        if reason == "mismatch":
            row.tries = (row.tries or 0) + 1
            session.commit()
        raise HTTPException(status_code=400, detail=f"code {reason}")

    row.consumed_at = now

    # 手机按 phone 找、邮箱按 email 找。两个字段互不覆盖：同一个人既绑手机
    # 又绑邮箱时，两次登录应落到同一个账号上（后续 bind 流程负责互相补全）。
    if payload.channel == "sms":
        user = session.execute(select(User).where(User.phone == target)).scalars().first()
    else:
        user = session.execute(select(User).where(User.email == target)).scalars().first()

    if user is None:
        user = User(nickname=DEFAULT_NICKNAME, region=settings.region, created_at=now, updated_at=now)
        if payload.channel == "sms":
            user.phone = target
        else:
            user.email = target
        session.add(user)
        # 先 flush 拿到自生成的 id，令牌行才有 user_id 可写。
        session.flush()

    raw_token = new_token()
    expires_at = now + settings.token_ttl_days * 24 * 60 * 60 * 1000
    session.add(
        AuthToken(
            token=hash_token(raw_token),
            user_id=user.id,
            device_id=payload.device_id,
            created_at=now,
            expires_at=expires_at,
        )
    )
    session.commit()
    session.refresh(user)

    # 明文令牌只在这里出现一次；库里存的是哈希，之后谁（包括我们）都取不回来。
    return {"token": raw_token, "user": user_out(user), "expires_at": expires_at}


@router.post("/auth/password/set")
def set_password(
    payload: PasswordSetIn,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """设置或更换登录密码（需已登录）。

    登录后才允许设密码：首次验证码登录后客户端弹「设个密码下次免短信」。
    已设过的再调就是改密码。明文只在请求体里出现一次，入库前就哈希。
    """
    user.password_hash = hash_password(payload.password)
    user.updated_at = now_ms()
    session.commit()
    return {"ok": True}


@router.post("/auth/password/login")
def password_login(
    payload: PasswordLoginIn,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> dict:
    """手机号/邮箱 + 密码登录，通过则签发令牌。

    安全口径：查无此号、该号没设过密码、密码不对，三种情况**返回同一个错误**
    （401 + 同一句 detail）。不区分这三种，等于不告诉试探者「这个号到底
    注册过没有」「它有没有设密码」——每多泄露一点都方便撞库。
    """
    target = normalize_target(payload.channel, payload.target)
    if not target:
        raise HTTPException(status_code=400, detail="invalid target")

    if payload.channel == "sms":
        user = session.execute(select(User).where(User.phone == target)).scalars().first()
    else:
        user = session.execute(select(User).where(User.email == target)).scalars().first()

    # 统一错误：不区分「号不存在」与「密码错」，也不透露是否设过密码。
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="invalid phone/email or password")

    return _issue_token(session, user, payload.device_id, settings)


@router.post("/auth/logout")
def logout(
    authorization: str | None = Header(default=None),
    session: Session = Depends(get_session),
) -> dict:
    """撤销当前令牌。只撤销这一个设备，其他设备保持登录。"""
    row, _ = _resolve_token(session, authorization)
    row.revoked_at = now_ms()
    session.commit()
    return {"ok": True}


@router.get("/me")
def get_me(user: User = Depends(current_user)) -> dict:
    return {"user": user_out(user)}


@router.patch("/me")
def patch_me(
    payload: ProfilePatchIn,
    user: User = Depends(current_user),
    session: Session = Depends(get_session),
) -> dict:
    """改资料。只改传上来的字段。"""
    now = now_ms()
    updates = payload.model_dump(exclude_unset=True)

    # 联系方式要做和登录一样的归一化：如果这里存 +8613800138000、注册流程存
    # 13800138000，同一个号码会查出两条记录，「用手机号登录」立刻失效。
    if "phone" in updates and updates["phone"] is not None:
        updates["phone"] = normalize_target("sms", updates["phone"])
    if "email" in updates and updates["email"] is not None:
        updates["email"] = normalize_target("email", updates["email"])

    for key, value in updates.items():
        setattr(user, key, value)
    user.updated_at = now
    session.flush()

    # 资料变更也要进同步日志，否则别的设备永远看不到新昵称/联系方式。
    # users 行没有 pet_id（它不属于任何宠物），所以 pet_id 传 None。
    record_change(
        session,
        table_name="users",
        row_id=user.id,
        op="upsert",
        pet_id=None,
        user_id=user.id,
        payload={
            "id": user.id,
            "nickname": user.nickname,
            "phone": user.phone,
            "email": user.email,
            "wechat": user.wechat,
            "contact_note": user.contact_note,
            "updated_at": now,
        },
        changed_at=now,
    )
    session.commit()
    session.refresh(user)
    return {"user": user_out(user)}
