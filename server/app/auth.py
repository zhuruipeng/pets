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

import logging
import smtplib
from email.header import Header as EmailHeader
from email.mime.text import MIMEText
from email.utils import formataddr, parseaddr

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

# 邮件发送的日志。
#
# ⚠️ **必须显式设 level，否则成功日志会被静默丢弃。**
#
# 踩过的坑：gunicorn worker 里没有给应用配 logging handler，
# root logger 的默认级别是 **WARNING**，于是 `log.info("code email sent")`
# **被直接丢掉** —— 表现是「发成功了但日志里什么都没有」。
#
# 那个 bug 比「完全没日志」更坏：发失败时 log.error() 仍会输出（root 有
# lastResort handler），于是日志里只有失败、没有成功。你看到一片空白时
# 无法判断是「没发」还是「发了但没记」—— 而这两者的排查方向完全相反。
#
# `propagate=False` 是为了不让这条日志重复出现在 root 的 handler 里
# （gunicorn 的 errorlog 已占用 stdout/stderr）。
log = logging.getLogger("auth.sms")
log.setLevel(logging.INFO)
log.propagate = False
if not log.handlers:
    # 用 basicConfig 会去配置 root，那会污染整个应用的日志策略；
    # 这里只给自己挂一个 StreamHandler，范围最小。
    _h = logging.StreamHandler()
    _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(_h)

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
    # ⚠️ 原先唯独这个字段是裸的 `str | None = None`（2026-10-10 补）。
    # 它会被 `record_change` 写进 sync_changes 的 payload，
    # 所以超大值不仅撑爆 users 表，还会在变更日志里**放大一倍**。
    contact_note: str | None = Field(default=None, max_length=1000)


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


# 每个用户最多保留多少个「还有用」的令牌行（2026-10-10 代码审查 P1 补）。
#
# 问题：`auth_tokens` 原先**只增不减** —— 每次登录都插一行，登出只写
# `revoked_at` 不删，过期也只是不认。一个人天天登录，一年就是 365 行，
# 十年 3650 行；这张表还带一个 `idx_auth_tokens_user` 索引，所以
# 每次 `_resolve_token` 的 `session.get(AuthToken, hash)` 虽然走主键，
# 但表的体积和索引维护成本是无谓的。
#
# 保留 20 个活跃令牌：正常用户手上不会同时有 20 台设备。超出的按
# 「已失效优先、其次最旧」清理，**不会踢掉正在用的设备**。
#
# ⚠️ 清理只在签发时顺带做（不是定时任务）：签发是低频动作，代价可以
# 忽略；而引入定时任务要多一套调度和运维。代价是「一个用户彻底不登录
# 了，他那堆令牌就永远留着」—— 但那种行的 `expires_at` 已经过期，
# 不再构成安全面，只是占体积。真要清理，运维侧加一条 cron 即可。
MAX_TOKENS_PER_USER = 20


def _prune_tokens(session: Session, user_id: str) -> int:
    """清掉该用户多余的令牌行，返回删除条数。

    保留策略：按 `created_at` 从新到旧排序，**留下最新的
    `MAX_TOKENS_PER_USER - 1` 行**（第 20 个位置留给即将签发的新令牌），
    其余全部删除。

    为什么不留「未过期优先」而要按时间硬删：一个用户手上同时有 20 个
    未过期令牌，本身就说明这不是正常使用（正常人到不了 20 台设备）。
    而且把「已撤销的排在新令牌前面」不会带来任何好处 —— 已撤销的行
    本来就没有安全价值，留着只是占体积，不如按时间一刀切、逻辑单一。
    """
    stale = session.execute(
        select(AuthToken)
        .where(AuthToken.user_id == user_id)
        .order_by(AuthToken.created_at.desc())
        .offset(MAX_TOKENS_PER_USER - 1)
    ).scalars().all()

    for row in stale:
        session.delete(row)
    return len(stale)


def _issue_token(
    session: Session, user: User, device_id: str | None, settings: Settings
) -> dict:
    """给 user 签发一个新令牌，返回与 verify_code 一致的响应体。

    所有签发路径（验证码登录、密码登录、CN 区官网换票）都要走这里 ——
    走别的路会绕过令牌清理，让 `auth_tokens` 重新变成只增不减。
    """
    now = now_ms()
    _prune_tokens(session, user.id)
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


def _dispatch_code(
    channel: str,
    target: str,
    code: str,
    purpose: str,
    settings: Settings,
) -> None:
    """把验证码真正发出去。**邮件（SMTP）已实现，短信仍是占位。**

    ## 为什么失败只记日志、不抛异常

    调用方在**发码之前**已经把验证码行写库并 commit 了。如果这里抛异常，
    整条记录会随事务回滚 —— 于是「发送失败」变成「这行记录不存在」，
    用户点重发时 `_recent_code` 查不到刚发的码，走不到限流分支，
    于是无限重发；而用户那边永远收不到码。**失败要留在「码已生成」这个状态**
    （用户可以重发），只把「发不出去」这件事记下来。

    ## 邮件为什么用 SMTP

    腾讯企业邮箱原生支持 SMTP，Python 的 `smtplib` 是标准库 ——
    零新增依赖。选 Resend/SendGrid 这类 HTTP API 的话要引 requests/httpx、
    多一份服务商密钥管理，收益仅是投递率略好；先把链路跑通更重要。

    ## 投递失败的常见原因（排查时按这个顺序看）

    1. **用了登录密码而不是授权码** —— 企业邮箱的 SMTP 密码在后台单独生成，
       用登录密码会 535 认证失败；
    2. **From 地址不是已验证的发件人** —— 服务端认为发出去了，邮件进垃圾箱，
       表现为「用户说没收到」但日志一切正常；
    3. **端口与 TLS 方式不匹配** —— 465 配隐式 TLS，587 配 STARTTLS，
       配错会在握手阶段就失败。
    """
    if channel == "email":
        _send_email_code(target, code, purpose, settings)
        return

    # 短信：仍未实现。理由写在 config.sms_provider 的注释里 ——
    # 中国区短信要先做模板报备，未报备的内容会被运营商拦截。
    log.warning(
        "sms channel configured but not implemented; code=%s target=%s purpose=%s",
        code[:2] + "****",  # 日志里不要留完整验证码
        _mask(target),
        purpose,
    )


def _mask(target: str) -> str:
    """日志里脱敏：手机号留前 3 后 4，邮箱留域名。

    完整验证码和完整手机号都不该进日志 —— 日志会被复制到工单、看板、
    第三方监控里，等于把「能登录这个账号」的信息散出去。
    """
    if "@" in target:
        local, _, domain = target.partition("@")
        return f"{local[:2]}***@{domain}"
    return target[:3] + "****" + target[-4:] if len(target) > 7 else "***"


def _send_email_code(
    to_addr: str, code: str, purpose: str, settings: Settings
) -> None:
    """通过 SMTP 发验证码邮件。**任何失败都只记日志。**"""
    if not settings.smtp_host or not settings.smtp_user:
        log.error(
            "smtp not configured (host=%r user=%r); cannot send code to %s",
            settings.smtp_host, settings.smtp_user, _mask(to_addr),
        )
        return

    from_addr = settings.smtp_from_email or settings.smtp_user
    subject = _email_subject(purpose, code)
    body = _email_body(purpose, code)

    msg = MIMEText(body, "plain", "utf-8")
    # Encode the subject before Python 3.11's SMTP renderer folds headers.
    # Keep the email Header distinct from FastAPI's request Header dependency.
    msg["Subject"] = EmailHeader(subject).encode()
    msg["From"] = formataddr((settings.smtp_from_name, from_addr))
    msg["To"] = to_addr

    try:
        if settings.smtp_secure:
            # 465：连接即 TLS。context 不传则用 smtplib 默认的严格校验。
            with smtplib.SMTP_SSL(
                settings.smtp_host, settings.smtp_port, timeout=20
            ) as srv:
                srv.login(settings.smtp_user, settings.smtp_password)
                srv.send_message(msg)
        else:
            # 587：先明文连上再 STARTTLS 升级。
            with smtplib.SMTP(
                settings.smtp_host, settings.smtp_port, timeout=20
            ) as srv:
                srv.starttls()
                srv.login(settings.smtp_user, settings.smtp_password)
                srv.send_message(msg)
    except smtplib.SMTPAuthenticationError:
        # 最常见的一种：把登录密码当成了授权码。错误信息里说清楚。
        log.error(
            "smtp auth failed for %s — check that smtp_password is the "
            "AUTHORIZATION CODE, not the account login password "
            "(host=%s port=%s)",
            settings.smtp_user, settings.smtp_host, settings.smtp_port,
        )
    except Exception:
        # 网络超时 / 证书问题 / 端口不通 / 被限流。全部记栈，别只记 str(e) ——
        # 握手失败时 str(e) 往往只有一句「Connection refused」，没有栈很难定位。
        log.exception(
            "smtp send failed (host=%s port=%s secure=%s) to %s",
            settings.smtp_host, settings.smtp_port, settings.smtp_secure,
            _mask(to_addr),
        )
    else:
        log.info("code email sent to %s (purpose=%s)", _mask(to_addr), purpose)


def _email_subject(purpose: str, code: str) -> str:
    """邮件标题里带验证码。

    理由：验证码邮件常被归到「其他邮件」或收在通知栏里，标题不写验证码
    用户得点开去找 —— 而验证码有 5 分钟有效期。
    """
    label = {
        "login": "Your My Pet sign-in code",
        "invite": "Your My Pet invite code",
    }.get(purpose, "Your My Pet verification code")
    return f"{label}: {code}"


def _email_body(purpose: str, code: str) -> str:
    """正文：纯文本、无 HTML。

    HTML 邮件在 Outlook / Gmail 上各有各的渲染坑（默认字体、间距失效），
    而验证码邮件的唯一任务是让人看清那 6 位数字 —— 纯文本反而最可靠。
    """
    ttl = 5
    if purpose == "invite":
        head = "You have been invited to co-care for a pet on My Pet."
    else:
        head = "Use this code to sign in to My Pet."
    return (
        f"{head}\n\n"
        f"{code}\n\n"
        f"The code expires in {ttl} minutes and can only be used once.\n"
        f"If you did not request it, you can ignore this email — "
        f"no one can sign in without this code.\n\n"
        f"-- My Pet"
    )


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

    # ⚠️ **没有真实通道时不能返回 `sent: true`。**
    #
    # 实测过的坑：`_dispatch_code` 至今是 `return None`（占位实现，什么也不发），
    # 而接口照样 200 + `{"sent": true}`。客户端于是显示「验证码已发送」，
    # 用户盯着手机等一分钟什么都没有 —— **界面在撒谎，比报错难查十倍**。
    #
    # 更隐蔽的是：生产环境正确地把 `dev_echo_code` 关了（必须关，回显等于
    # 把验证码送给任何人），于是「靠 dev_code 兜底」这条路也没了，
    # 结果是**登录彻底不可用却没有任何一处报错**。
    #
    # 所以这里前置判断：既没有服务商、又不开回显，就明确告诉调用方
    # 「通道没配」，让它去报错，而不是假装发出去。
    # 邮件通道是否真的可用：**看 SMTP 有没有配齐**，而不是看 email_provider
    # 这个标志位。后者只是一个「打算用邮件」的意图标记，为空不代表发不出去。
    has_provider = (
        bool(settings.smtp_host and settings.smtp_user and settings.smtp_password)
        if payload.channel == "email"
        else bool(settings.sms_provider)
    )
    if not has_provider and not settings.dev_echo_code:
        # 通道没配且不能回显 → 登录不可能成功。
        # 503 而不是 400：这是**服务端配置缺失**，不是用户请求有问题，
        # 客户端重试多少次都一样，区别对待才能在监控里看出问题。
        raise HTTPException(
            status_code=503,
            detail="verification channel is not configured on this server",
        )

    _dispatch_code(payload.channel, target, code, "login", settings)

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
    _prune_tokens(session, user.id)
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

    # phone/email 同时是已验证的登录标识。普通资料编辑不能完成换绑，
    # 否则任意账号可冒用别人号码并劫持后续登录/共养邀请。
    for key in ("phone", "email"):
        if key in updates and updates[key] != getattr(user, key):
            raise HTTPException(status_code=400,
                                detail="login identifier changes require verification")

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
