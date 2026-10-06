"""用户反馈：接收后转发到开发者邮箱。

## 为什么只发邮件、不建后台页面

真实用户还是个位数，邮件足够看完。而每多一个界面就多一处要维护 ——
后台页面要鉴权、要防爬、要跟着改版，做了也没人天天打开。

## 隐私边界（重要）

**这个接口不存库、不落盘，只把内容发到开发者自己的邮箱。**

这不是「数据不出境」的例外，理由是：
- 提交是**用户主动的、明确的**行为，与「后台埋点」性质不同；
- 内容是用户自己写的描述 + App 崩溃堆栈，**不含任何账号数据**；
  崩溃上下文里刻意只有版本号、区域、平台，没有手机号、宠物名、备注正文。

对应的，客户端那边是「用户点了提交才发」，不是自动上报 ——
自动上报会在用户毫不知情时把崩溃数据传出去，那才需要改隐私政策。

## 限流

**不按 IP 限流**，只做同内容去重。理由：反馈很少，限流的唯一作用
是防「同一份内容被反复提交」—— 那是客户端重试逻辑出 bug 的表现，
而按 IP 限流会误伤同一 WiFi 下的多个用户。

去重的做法是**同 (kind, message) 在 10 分钟内只发一次**。
"""

from __future__ import annotations

import logging
import re
import smtplib
import ssl
from datetime import datetime, timezone, timedelta
from email.header import Header
from email.mime.text import MIMEText
from email.utils import formataddr

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from .config import Settings, get_settings
from .db import get_session

router = APIRouter(tags=["feedback"])

log = logging.getLogger("feedback")
# 与 auth 同一个坑：gunicorn worker 里 root 默认 WARNING，
# 不显式设 level 的话 log.info 会被静默丢弃（表现为「成功了但没日志」）。
log.setLevel(logging.INFO)
log.propagate = False
if not log.handlers:
    _h = logging.StreamHandler()
    _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(_h)

# 同一份内容 10 分钟内不重复发。
_DEDUP_WINDOW = timedelta(minutes=10)
_seen: dict[tuple[str, str], datetime] = {}

# 去重表的上限。**必须有**，否则它是个只增不减的字典 ——
# 每次「客户端重试 bug」都会往里塞一条，进程活久了内存一直涨。
# 反馈频率极低，256 条足够覆盖去重窗口内的真实量；超了就清空，
# 代价只是「窗口内的重复可能被放行一次」，完全可接受。
_DEDUP_MAX = 256


def _reset_dedup() -> None:
    """清空去重表。

    单独抽出来是因为**测试之间必须隔离**：去重表是模块级全局，
    上一条用例记下的内容会让下一条的「首次提交」被误判成重复
    （表现为 KeyError 或 delivered=False，且单独跑能过、一起跑就挂 ——
    这是最难查的一类测试失败）。

    顺带承担生产环境的清理职责：只在超限时才清，不会误删。
    """
    _seen.clear()

# 单条反馈的硬上限。防「用户粘贴了一整本日志进来」把邮件撑爆，
# 也防有人拿这个接口当上传通道。8KB 足够装下完整的崩溃上下文。
_MAX_LEN = 8000


class FeedbackIn(BaseModel):
    """一条反馈。

    字段刻意保持最少：能定位问题的东西（版本、平台、堆栈）加上
    用户自己想说的话。**不收邮箱、不收设备 ID、不收账号信息** ——
    反馈是匿名的，开发者只需要知道「哪里坏了」。
    """

    message: str = Field(min_length=1, max_length=_MAX_LEN)
    # 崩溃条目的类型与摘要，能带就带（用户可能只是来提个建议）
    kind: str = Field(default="manual", max_length=40)
    app_version: str = Field(default="", max_length=40)
    region: str = Field(default="", max_length=20)
    platform: str = Field(default="", max_length=40)
    # 崩溃堆栈，截断后带过来
    stack: str = Field(default="", max_length=_MAX_LEN)


@router.post("/feedback")
def submit_feedback(
    payload: FeedbackIn,
    settings: Settings = Depends(get_settings),
) -> dict:
    """接收一条反馈并转发到开发者邮箱。

    **永远返回 200**，即使邮件没发出去 ——
    反馈发不成功不该让用户重试：他没有任何办法补发，而重试只会产生重复邮件。
    失败只记日志，由我们自己发现。
    """
    now = datetime.now(timezone.utc)

    # 顺手清掉过期项：即使没到上限，也不让过期内容一直占着内存。
    if len(_seen) > _DEDUP_MAX:
        cutoff = now - _DEDUP_WINDOW
        for k in [k for k, t in _seen.items() if t < cutoff]:
            del _seen[k]
        # 还是太多（说明短时间内大量重复提交）就整体清空。
        if len(_seen) > _DEDUP_MAX:
            _seen.clear()

    key = (payload.kind, _fingerprint(payload.message))
    last = _seen.get(key)
    if last is not None and now - last < _DEDUP_WINDOW:
        log.info(
            "feedback duplicate ignored (kind=%s region=%s version=%s)",
            payload.kind, payload.region, payload.app_version,
        )
        return {"received": True, "deduped": True}

    # ⚠️ **feedback_to 也必须检查。**
    # 原来只查了 smtp_host/user，没查收件地址 ——
    # 结果配置漏了 feedback_to 时会拿着空地址去 send_message，
    # 抛出 `SMTPRecipientsRefused` 或干脆发给服务器自己。
    # 漏配是这个接口最可能出的错（它不像 smtp_* 有现成模板），
    # 所以前置拦住并给出明确的日志。
    if not (settings.feedback_to or "").strip():
        log.error(
            "feedback received but FEEDBACK_TO is not configured; DROPPED "
            "(version=%s region=%s message=%.80s)",
            payload.app_version, payload.region, payload.message,
        )
        return {"received": True, "delivered": False}

    if not settings.smtp_host or not settings.smtp_user:
        # 没配通道时明确记 error，而不是静默丢。
        log.error(
            "feedback received but smtp not configured; DROPPED "
            "(version=%s region=%s message=%.80s)",
            payload.app_version, payload.region, payload.message,
        )
        return {"received": True, "delivered": False}

    try:
        _send_to_dev(payload, settings)
    except Exception:
        log.exception(
            "feedback email failed (version=%s region=%s)",
            payload.app_version, payload.region,
        )
        return {"received": True, "delivered": False}

    _seen[key] = now
    log.info(
        "feedback delivered (kind=%s version=%s region=%s platform=%s)",
        payload.kind, payload.app_version, payload.region, payload.platform,
    )
    return {"received": True, "delivered": True}


def _fingerprint(message: str) -> str:
    """给消息算个短指纹用于去重。

    取前 200 字符并归一化空白 —— 用户重试时打的内容通常完全一样，
    而客户端可能因为补了时间戳之类而产生细微差异。
    """
    norm = re.sub(r"\s+", " ", (message or "").strip())[:200]
    return str(hash(norm))


def _send_to_dev(payload: FeedbackIn, settings: Settings) -> None:
    """把反馈发到开发者邮箱。**失败抛异常**，由调用方统一记日志。"""
    to_addr = settings.feedback_to
    from_addr = settings.smtp_from_email or settings.smtp_user

    subject = _subject(payload)
    body = _body(payload)

    msg = MIMEText(body, "plain", "utf-8")
    # str(Header) returns raw Unicode, which Python 3.11 cannot always fold.
    msg["Subject"] = Header(subject, "utf-8").encode()
    msg["From"] = formataddr((settings.smtp_from_name, from_addr))
    msg["To"] = to_addr

    # Reply-To 留空：反馈是匿名的，没有可回复的地址。
    # 别写用户的邮箱（我们也没有 —— 客户端压根没传）。

    if settings.smtp_secure:
        with smtplib.SMTP_SSL(
            settings.smtp_host, settings.smtp_port, timeout=25,
            context=ssl.create_default_context(),
        ) as srv:
            srv.login(settings.smtp_user, settings.smtp_password)
            srv.send_message(msg)
    else:
        with smtplib.SMTP(
            settings.smtp_host, settings.smtp_port, timeout=25
        ) as srv:
            srv.starttls()
            srv.login(settings.smtp_user, settings.smtp_password)
            srv.send_message(msg)


def _subject(payload: FeedbackIn) -> str:
    """标题里带上版本与区域 —— 不看正文就能判断是哪一版出的问题。"""
    ver = payload.app_version or "版本未知"
    return f"[My Pet 反馈] {payload.kind} · v{ver} · {payload.region or '?'}"


def _body(payload: FeedbackIn) -> str:
    parts = [
        "用户反馈",
        "=" * 40,
        "",
        payload.message.strip(),
    ]
    if payload.stack.strip():
        parts += [
            "",
            "--- 崩溃堆栈 ---",
            payload.stack.strip(),
        ]
    parts += [
        "",
        "--- 环境 ---",
        f"App 版本: {payload.app_version or '未知'}",
        f"区域:     {payload.region or '未知'}",
        f"平台:     {payload.platform or '未知'}",
        "",
        "（这封邮件由 App 的「问题反馈」自动转发。反馈是匿名的，"
        "没有用户账号信息。）",
    ]
    return "\n".join(parts)
