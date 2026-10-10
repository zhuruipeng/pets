"""中国区统一账号（出岫）换票。

背景：宠物 App 与官网的 ERP / 商城 / AI 修图共用一套手机号账号。
中国区选择「共用账号」而不是「各自一套」，是为了让用户只记一个账号 ——
这也是老板拍板的 A 方案（见 docs/账号体系复用.md）。

为什么是「宠物服务端去问官网」而不是「官网发个 JWT，宠物端自己验签」：
官网的账号令牌是**不透明随机串**（`ACCOUNT_TOKENS.issue` 发的，能不能用
要回表里查），宠物服务端无法离线验签。调 `GET /api/auth/me` 是唯一可信
来源，而且天然继承撤销语义 —— 用户在官网登出后，拿旧令牌来换票立刻失败。

代价要说清楚：换票要在两个信任域之间走一次信任传递，官网账号体系一旦
失守，宠物账号跟着失守。选 A 就接受了这个耦合（B 方案没有这个代价）。
另外换票**只在登录时发生一次**，不像每个业务请求都要校验，所以多一跳
请求是可以接受的成本。

安全约定：官网令牌**用完即弃，绝不入库**。宠物域签发自己的令牌，两边
各自独立吊销；把官网令牌存下来等于让一张凭证跨两个域长期有效。
"""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import (
    CODE_HOURLY_LIMIT,
    DEFAULT_NICKNAME,
    _client_ip,
    _prune_tokens,
    user_out,
)
from .config import Settings, get_settings
from .db import get_session
from .models import AuthToken, User
from .sync_logic import hash_token, new_token, normalize_target, now_ms

router = APIRouter(tags=["auth"])

ME_PATH = "/api/auth/me"

# 请求官网的超时。取 5 秒：换票是用户在登录界面上等着的**同步**操作，
# 卡太久不如早点告诉他「服务暂时不可用，稍后再试」。
DEFAULT_TIMEOUT_SECONDS = 5.0

# 换票接口每 IP 每小时的调用上限（2026-10-10 代码审查 P1 补）。
#
# 为什么必须限：这个接口**自己不校验任何凭据** —— 它把 `unified_token`
# 原样转发给官网，由官网判断有效性。于是它天然是一个「拿我们当代理去
# 试探官网」的放大器：攻击者可以拿随机令牌刷，每次都会让我们的两个
# gunicorn worker 各占一条出网连接 + 一个 5 秒超时窗口。
#
# 两个 worker 意味着并发只有 2，几十个并发请求就能把登录接口整体堵死
# （换票是同步阻塞的 urllib 调用，不是 async），这就是一个低成本的
# 拒绝服务入口，而且被当成攻击源的是**我们的服务器 IP**，不是攻击者的。
#
# 额度取 20：正常用户一天换票不了几次（换手机、重装、多设备），
# 20 次/小时对一家人共用出口 IP 也够。与短信验证码用同一个常量，
# 因为两者的攻击面同源（都是「无凭据的对外转发」）。
UNIFIED_HOURLY_LIMIT = CODE_HOURLY_LIMIT

ONE_HOUR_MS = 3600 * 1000


class UnifiedAccountError(Exception):
    """换票失败。reason 用来决定回给客户端哪个状态码。

    分三类而不是笼统一个「失败」：令牌无效（401，客户端该清掉本地令牌）、
    官网不可达（503，客户端该重试）、响应不合契约（502，我们的问题）。
    混成一种的话客户端只能一律「登录失败」，用户不知道要不要重试。
    """

    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail


@dataclass(frozen=True)
class UnifiedAccount:
    """宠物侧需要的全部官网账号信息。刻意只有三个字段。

    不把官网的 entitlements / erp_profiles / services 带过来：
    那些是 ERP 的授权概念，宠物权益与它无关，带过来只会诱使后续代码
    拿 ERP 权益判断宠物功能，把两个域的授权模型搅在一起。
    """

    account_id: str
    phone: str
    nickname: str


def unified_enabled(settings: Settings) -> bool:
    """这个部署是否提供统一账号登录。

    两道门：区域必须是 cn（海外区没有出岫账号，且数据不出境），
    且必须配了官网地址（没配说明这个环境还没接，别让客户端把
    「功能存在但没接好」和「功能不存在」混淆）。
    """
    return settings.region == "cn" and bool(settings.unified_account_base_url.strip())


def _looks_like_phone(value: str) -> bool:
    """归一化之后还像不像手机号：+ 开头，后面 6~15 位数字（E.164 上限）。

    为什么要在归一化之后再检一遍：normalize_target 对「既不是 + 开头也不是
    纯数字」的输入会**原样返回**（它不做猜测）。如果官网那边 phone 字段变成
    空字符串或带字母，原样返回的结果会被当成手机号写进 users 唯一键，
    于是每次登录都建一个新用户。这里挡一道。
    """
    if not value.startswith("+"):
        return False
    digits = value[1:]
    return digits.isdigit() and 6 <= len(digits) <= 15


def parse_me_payload(payload: Any) -> UnifiedAccount | None:
    """从官网 `/api/auth/me` 的响应里取出宠物侧要的三样东西。

    只认「ok=true 且 account 里有合法手机号」这一种形态。官网字段改名或
    改成嵌套结构时，这里明确返回 None 让上层报 502，而不是拼出一个
    phone 为空的「账号」—— 空手机号能让唯一键判断失效，每次登录都新建
    用户，是最坏的一类静默错误。
    """
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        return None

    account = payload.get("account")
    if not isinstance(account, dict):
        return None

    account_id = account.get("id")
    if account_id in (None, ""):
        return None

    phone = normalize_target("sms", str(account.get("phone") or ""))
    if not _looks_like_phone(phone):
        return None

    # 昵称缺失时退回手机号：nickname 在库里是 NOT NULL，空串会显示成空白。
    nickname = str(account.get("nickname") or "").strip() or phone
    return UnifiedAccount(
        account_id=str(account_id),
        phone=phone,
        nickname=nickname,
    )


def _urlopen(request: urllib.request.Request, timeout: float):
    """默认的网络出口。抽成函数是为了让测试能注入假实现。"""
    # URL 来自配置（运维可控），不是用户输入，因此不构成 SSRF 面。
    return urllib.request.urlopen(request, timeout=timeout)  # noqa: S310


def fetch_unified_account(
    base_url: str,
    token: str,
    *,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    opener: Callable[..., Any] | None = None,
) -> UnifiedAccount:
    """拿官网令牌去问官网「这是谁」。失败抛 UnifiedAccountError。

    用标准库 urllib 而不是 httpx/requests：宠物服务端目前零 HTTP 客户端依赖
    （requirements.txt 里只有 fastapi/sqlalchemy 那几个），官网那套也是
    同一风格。为一个登录时要调一次的接口引一个依赖不划算。
    """
    url = base_url.strip().rstrip("/") + ME_PATH
    request = urllib.request.Request(url, method="GET")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/json")

    call = opener or _urlopen
    try:
        response = call(request, timeout)
        try:
            raw = response.read()
        finally:
            response.close()
    except urllib.error.HTTPError as exc:
        # 401/403 是「令牌不认」，其余状态码归入不可达：5xx 是官网自己出问题，
        # 422 之类是我们请求写错了 —— 都不该让客户端以为自己的令牌废了。
        if exc.code in (401, 403):
            raise UnifiedAccountError("invalid_token", f"upstream {exc.code}") from exc
        raise UnifiedAccountError("unreachable", f"upstream {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise UnifiedAccountError("unreachable", str(exc)) from exc

    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UnifiedAccountError("bad_response", str(exc)) from exc

    account = parse_me_payload(payload)
    if account is None:
        raise UnifiedAccountError("bad_response", "account payload unusable")
    return account


class UnifiedExchangeIn(BaseModel):
    # 官网令牌长度不做严格约束（可能换实现），只挡住空串和明显离谱的值。
    unified_token: str = Field(min_length=8, max_length=512)
    device_id: str | None = Field(default=None, max_length=64)


# 按 IP 的滑动窗口：{ip: [时间戳, ...]}，时间戳递增。
_RATE_WINDOW: dict[str, list[int]] = {}
_RATE_LOCK = threading.Lock()


def _enforce_unified_rate_limit(ip: str) -> None:
    """按 IP 的滑动窗口限流。见调用处的长注释（讲清了为什么不用落库计数）。"""
    now = now_ms()
    window_start = now - ONE_HOUR_MS
    with _RATE_LOCK:
        stamps = _RATE_WINDOW.setdefault(ip, [])
        # 只留窗口内的；stamps 是递增 append 的，从头删即可。
        while stamps and stamps[0] <= window_start:
            stamps.pop(0)
        if len(stamps) >= UNIFIED_HOURLY_LIMIT:
            raise HTTPException(
                status_code=429, detail="too many token exchanges from this address"
            )
        stamps.append(now)


@router.post("/auth/unified")
def exchange_unified_token(
    payload: UnifiedExchangeIn,
    request: Request,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> dict:
    """用官网账号令牌换一个宠物域令牌。

    这是 A 方案里唯一的新接口。客户端在 cn 区先走官网的
    `/api/auth/sms/send` + `/api/auth/login-sms` 拿到账号令牌，再来这里换票。
    """
    if not unified_enabled(settings):
        # 能力不存在（而不是「你没权限」），所以 404 比 403 准确：
        # 海外节点上这个接口就是没接，客户端不该把它当成一个可重试的失败。
        raise HTTPException(status_code=404, detail="unified account not enabled")

    # ⚠️ 限流必须在**任何出网动作之前**（2026-10-10 代码审查 P1 补）。
    #
    # 这个接口是「无凭据的对外转发」：拿任意字符串都能让我们去请求官网。
    # 放在 `fetch_unified_account` 之后限流等于没限 —— 请求已经发出去了，
    # 攻击者要消耗的出网连接和 worker 时间都已经消耗掉了。
    #
    # 为什么不用短信那套「落库计数」：换票不产生任何可计数的数据库行，
    # 失败的尝试更是一条都不该落库（那是另一种写入放大），专门为限流建表
    # 成本高于收益。代价是**多 worker 时额度按 worker 翻倍**、重启清零 ——
    # 够用来防「单点刷爆」，不够用来精确计费。
    _enforce_unified_rate_limit(_client_ip(request))

    try:
        account = fetch_unified_account(
            settings.unified_account_base_url,
            payload.unified_token,
            timeout=settings.unified_account_timeout_seconds,
        )
    except UnifiedAccountError as exc:
        if exc.reason == "invalid_token":
            raise HTTPException(status_code=401, detail="unified token rejected") from exc
        if exc.reason == "unreachable":
            # 关键：官网不可达时**不建任何用户**。让一次网络抖动建出半个账号，
            # 用户下次登录会看到两个自己，而且没法合并。
            raise HTTPException(status_code=503, detail="unified account unavailable") from exc
        raise HTTPException(status_code=502, detail="unified account response invalid") from exc

    now = now_ms()
    user = session.execute(select(User).where(User.phone == account.phone)).scalars().first()

    if user is None:
        user = User(
            nickname=account.nickname or DEFAULT_NICKNAME,
            phone=account.phone,
            region=settings.region,
            created_at=now,
            updated_at=now,
        )
        session.add(user)
        session.flush()
    # 已存在的用户只补手机号之外的东西**一概不动** —— 包括昵称。
    # 宠物 App 里的昵称是宠物圈里展示的名字，用户可能刻意和 ERP 账号名不同；
    # 每次登录都同步成官网昵称，等于把用户改过的名字反复抹掉。

    raw_token = new_token()
    expires_at = now + settings.token_ttl_days * 24 * 60 * 60 * 1000
    # ⚠️ 令牌清理要和 auth.py 的两条签发路径保持一致（2026-10-10 P1）。
    # 三处签发如果有一处漏了，那条路径上 `auth_tokens` 就会只增不减。
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

    return {
        "token": raw_token,
        "user": user_out(user),
        "expires_at": expires_at,
        # 回给客户端只为展示/排错，不承担认证作用。
        "unified": {"account_id": account.account_id, "phone": account.phone},
    }
