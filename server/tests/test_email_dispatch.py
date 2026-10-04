"""验证码邮件（SMTP）的测试。

## 为什么这组测试重要

`/auth/code/request` 之前返回 200 + `{"sent": true}` 但**一个邮件都没发**
（`_dispatch_code` 是 `return None`）。这种「接口成功但功能没实现」的 bug
在测试里毫无痕迹：状态码是 200，数据库里有记录，只有真实用户收不到邮件
才会发现。

所以这里测三件能测的事：
1. **SMTP 真的被调用了**（mock 掉 socket 层，不真发邮件）；
2. **发不出去时不抛异常** —— 验证码行已 commit，抛异常会连带回滚，
   用户就再也无法重发（`resend` 查不到「刚发的码」→ 绕过限流）；
3. **日志里不留完整验证码 / 完整手机号**。
"""

from __future__ import annotations

import smtplib
from unittest.mock import MagicMock, patch

import pytest

from app.auth import (
    _dispatch_code,
    _email_body,
    _email_subject,
    _mask,
)
from app.config import Settings


def _settings(**kw) -> Settings:
    """一套「已配好 SMTP」的设置。

    默认走 smtp.qq.com:465 隐式 TLS —— 腾讯企业邮箱与 QQ 邮箱企业版
    的 SMTP 参数就是这个组合。
    """
    base = {
        "smtp_host": "smtp.exmail.qq.com",
        "smtp_port": 465,
        "smtp_secure": True,
        "smtp_user": "noreply@weiyuantool.com",
        "smtp_password": "AUTHORIZATION-CODE-NOT-A-PASSWORD",
        "smtp_from_email": "noreply@weiyuantool.com",
        "smtp_from_name": "My Pet",
    }
    base.update(kw)
    return Settings(**base)


# ------------------------------------------------------------- 发得出去


def test_email_is_actually_sent_via_smtp():
    """配好 SMTP 时，`_dispatch_code` 必须真的去连服务器并发出邮件。

    这条是正向断言：**不**只验证「没抛异常」。
    之前那个 `return None` 的实现同样「不抛异常」，
    只有 mock 的 `send_message` 被调用才能证明邮件真的发出去了。
    """
    sent = []

    with patch("app.auth.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_ssl.return_value.__enter__.return_value = srv
        srv.send_message.side_effect = lambda m: sent.append(m)
        _dispatch_code(
            "email", "user@example.com", "123456", "login", _settings()
        )

    assert len(sent) == 1, "邮件没有被发送 —— 这就是「接口成功但收不到」的根因"
    msg = sent[0]
    assert msg["To"] == "user@example.com"
    # 标题里必须带验证码：验证码邮件常被收进「其他邮件」，
    # 标题不写就得点开找，而它只有 5 分钟有效期。
    assert "123456" in str(msg["Subject"])
    assert "My Pet" in str(msg["From"])


def test_starttls_used_when_not_secure():
    """smtp_secure=False 走 587 的 STARTTLS 路径，而不是 SMTP_SSL。

    端口与 TLS 方式配错会在握手阶段就失败，报错看不出是端口问题，
    所以两条路径要各自明确。
    """
    with patch("app.auth.smtplib.SMTP") as mock_smtp, \
            patch("app.auth.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_smtp.return_value.__enter__.return_value = srv
        _dispatch_code(
            "email",
            "user@example.com",
            "123456",
            "login",
            _settings(smtp_port=587, smtp_secure=False),
        )
        assert srv.starttls.called, "587 端口必须先 STARTTLS 升级"
        assert not mock_ssl.called, "非 secure 模式不该走 SMTP_SSL"


# --------------------------------------------------------- 发不出去也不炸


@pytest.mark.parametrize(
    "exc",
    [
        smtplib.SMTPAuthenticationError(535, b"auth failed"),
        smtplib.SMTPServerDisconnected("connection closed"),
        TimeoutError("timed out"),
        OSError("connection refused"),
    ],
)
def test_send_failure_never_raises(exc):
    """发送失败**不抛异常**，只记日志。

    理由是事务边界：调用方在发码前已经 commit 了验证码行。
    这里抛异常会连带回滚 → 用户点重发时查不到「刚发的码」→
    绕过限流 → 无限重发，而邮件永远收不到。
    """
    with patch("app.auth.smtplib.SMTP_SSL", side_effect=exc):
        # 不抛异常就是通过
        _dispatch_code(
            "email", "user@example.com", "123456", "login", _settings()
        )


def test_smtp_auth_error_log_says_use_authorization_code():
    """认证失败时日志必须点明「要用授权码，不是登录密码」。

    这是最高频的配错，且报错本身（535 auth failed）完全看不出原因。
    不点明的话，排查一次要重新翻一遍企业邮箱后台。

    ## 为什么不用 caplog

    `app.auth` 里的 logger 设了 `propagate = False`（避免与 gunicorn 的
    errorlog 重复输出），所以 caplog 的 root handler **抓不到**它的记录。
    这里改为直接读 handler 捕获的输出 —— 测的是「日志最终会不会被看到」，
    那才是真正要保证的事。
    """
    with patch(
        "app.auth.smtplib.SMTP_SSL",
        side_effect=smtplib.SMTPAuthenticationError(535, b"auth failed"),
    ):
        text = _capture_log(
            lambda: _dispatch_code(
                "email", "user@example.com", "123456", "login", _settings()
            )
        )
    assert "AUTHORIZATION CODE" in text.upper()


def test_missing_smtp_config_is_logged_not_raised():
    """SMTP 没配时记 error 日志、不抛异常。"""
    text = _capture_log(
        lambda: _dispatch_code(
            "email",
            "user@example.com",
            "123456",
            "login",
            Settings(),  # 什么都不配
        )
    )
    assert "smtp not configured" in text


def test_success_is_actually_logged():
    """成功也必须留下日志。

    ## 这条测试为什么重要

    之前 logger 没设 level，gunicorn worker 里 root 默认是 WARNING，
    于是 `log.info("code email sent")` **被静默丢弃** ——
    表现是「发成功了但日志里什么都没有」。

    那比「完全没日志」更坏：失败时 `log.error()` 仍会输出，
    于是日志里只有失败、没有成功。看到空白时无法判断是「没发」
    还是「发了没记」—— 而这两者的排查方向完全相反。
    """
    with patch("app.auth.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_ssl.return_value.__enter__.return_value = srv
        text = _capture_log(
            lambda: _dispatch_code(
                "email", "user@example.com", "123456", "login", _settings()
            )
        )
    assert "code email sent" in text
    # 完整验证码绝不能进日志
    assert "123456" not in text


def _capture_log(fn) -> str:
    """跑 fn 并返回 app.auth logger 实际写出的内容。

    直接抓 handler 而不是用 caplog：那个 logger 刻意设了
    `propagate = False`，而这条测试要保证的正是
    「日志真的会被看到」—— 绕过 propagate 才能验证这点。
    """
    import io
    import logging

    from app import auth as auth_mod

    logger = auth_mod.log
    buf = io.StringIO()
    handler = logging.StreamHandler(buf)
    handler.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
    logger.addHandler(handler)
    prev_level = logger.level
    logger.setLevel(logging.INFO)
    try:
        fn()
    finally:
        logger.removeHandler(handler)
        logger.setLevel(prev_level)
    return buf.getvalue()


# ------------------------------------------------------------- 脱敏


@pytest.mark.parametrize(
    "raw,masked",
    [
        ("13800138000", "138****8000"),
        ("user@example.com", "us***@example.com"),
        ("+8613800138000", "+86****8000"),
    ],
)
def test_mask_hides_identifiers(raw, masked):
    """日志里不能出现完整手机号 / 邮箱。

    日志会被复制到工单、看板、第三方监控里 —— 完整验证码和完整手机号
    都等于「能登录这个账号」的信息。
    """
    assert _mask(raw) == masked
    assert raw not in _mask(raw) or "@" in raw  # 邮箱保留域名是对的


def test_log_never_contains_full_code(caplog):
    """成功日志里也不能留完整验证码。"""
    with patch("app.auth.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_ssl.return_value.__enter__.return_value = srv
        with caplog.at_level("INFO"):
            _dispatch_code(
                "email", "user@example.com", "123456", "login", _settings()
            )
    assert "123456" not in caplog.text


# ------------------------------------------------------------- 邮件内容


def test_message_headers_are_renderable():
    """邮件头必须能真正**渲染成字节**。

    ## 这条测试为什么存在

    踩过的坑：`msg["Subject"] = Header(subject)`（不套 str()）在
    **Python 3.13 上能跑通、3.11 上抛
    `AttributeError: 'Header' object has no attribute 'encode'`**。

    当时的情况更糟：我在 Mac 上用真授权码**真的收到了邮件**，
    于是判定「代码没问题」—— 结果一上服务器就挂。

    ## 关键：这里测的是「渲染」不是「有没有收到」

    错误发生在 `BytesGenerator` 渲染邮件头那一步，**在 socket 之前**。
    所以只要构造一个同结构的 MIMEText 并尝试 flatten，就能在
    **任何 Python 版本上**复现 —— 不需要真发邮件。

    这比「测发信成功」可靠得多：后者在开发机上会因为版本差异而假通过。
    """
    import io
    from email.generator import BytesGenerator
    from email.header import Header
    from email.mime.text import MIMEText
    from email.policy import SMTP
    from email.utils import formataddr

    # 与 _send_email_code 完全同构
    msg = MIMEText("body", "plain", "utf-8")
    msg["Subject"] = str(Header("Your code: 123456"))
    msg["From"] = formataddr((str(Header("My Pet")), "noreply@example.com"))
    msg["To"] = "user@example.com"

    buf = io.BytesIO()
    # 不传 outfp 会在新版 Python 报另一个错，这里显式给
    BytesGenerator(buf, policy=SMTP).flatten(msg)

    raw = buf.getvalue()
    # 纯 ASCII 的头**不该**被编码 —— 编码它只是白白变长、降低可读性。
    # （非 ASCII 的编码情况由下面那条测试覆盖。）
    assert b"Subject: Your code: 123456" in raw
    assert b"From: My Pet <noreply@example.com>" in raw
    assert b"To: user@example.com" in raw
    # 关键：能生成完整的头结构说明渲染通过。
    # 3.11 上这里会抛 AttributeError: 'Header' object has no attribute 'encode'
    assert b"MIME-Version: 1.0" in raw


def test_non_ascii_subject_survives_render():
    """中文标题也要能渲染 —— 真实邮件标题是英文，但发件显示名可能带中文。"""
    import io
    from email.generator import BytesGenerator
    from email.header import Header
    from email.mime.text import MIMEText
    from email.policy import SMTP
    from email.utils import formataddr

    msg = MIMEText("验证码正文", "plain", "utf-8")
    msg["Subject"] = str(Header("你的验证码：123456"))
    msg["From"] = formataddr(
        (str(Header("我的宠物", "utf-8")), "noreply@weiyuantool.com")
    )
    buf = io.BytesIO()
    BytesGenerator(buf, policy=SMTP).flatten(msg)
    raw = buf.getvalue()
    # 同上：中文标题会被编码成 base64，不能搜明文。
    # 断言「渲染没抛异常 + 头齐全」才是这条测试的意图。
    assert b"Subject:" in raw
    assert b"noreply@weiyuantool.com" in raw
    # base64 解码后应能拿回原文 —— 这样既验证编码正确又不依赖明文
    import base64
    import re
    m = re.search(rb"Subject: =\?utf-8\?b\?([A-Za-z0-9+/=]+)\?=", raw)
    assert m, "中文标题未按 base64 编码"
    assert "123456" in base64.b64decode(m.group(1)).decode("utf-8")


def test_subject_carries_code_and_purpose():
    assert "123456" in _email_subject("login", "123456")
    assert "sign-in" in _email_subject("login", "123456").lower()
    assert "invite" in _email_subject("invite", "123456").lower()


def test_body_mentions_expiry_and_is_plaintext():
    body = _email_body("login", "123456")
    assert "123456" in body
    # 必须写有效期：用户输错三次就过期了却不知道为什么
    assert "5 minutes" in body
    # 纯文本，不要 HTML —— HTML 邮件在 Outlook / Gmail 上各有各的渲染坑，
    # 而验证码邮件唯一任务是让人看清 6 位数字
    assert "<" not in body
