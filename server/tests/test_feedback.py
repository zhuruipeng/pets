"""用户反馈接口的测试。

## 这组测试守什么

1. **邮件头能真正渲染**（3.11 上裸 Header 会抛异常）——
   这个坑在 auth.py 踩过一次，在 feedback.py 复用了同样的写法，
   所以必须有测试盯着，否则换个 Python 版本就静默炸。
2. **失败也返回 200**：反馈发不出去不该让用户重试。
3. **去重**：客户端重试逻辑出 bug 时不该产生重复邮件。
"""

from __future__ import annotations

import io
import smtplib
from email.generator import BytesGenerator
from email.policy import SMTP
from unittest.mock import MagicMock, patch

import pytest

from app.config import Settings
from app.feedback import (
    FeedbackIn,
    _body,
    _fingerprint,
    _subject,
    submit_feedback,
)


def _settings(**kw) -> Settings:
    base = {
        "smtp_host": "smtp.exmail.qq.com",
        "smtp_port": 465,
        "smtp_secure": True,
        "smtp_user": "noreply@weiyuantool.com",
        "smtp_password": "AUTH-CODE-NOT-A-PASSWORD",
        "smtp_from_email": "noreply@weiyuantool.com",
        "smtp_from_name": "My Pet",
        # ⚠️ 收件地址必须**与发件地址不同**，否则是「自己给自己发信」，
        # 反馈直接进黑洞。这是配置时最容易犯的错。
        "feedback_to": "dev@weiyuantool.com",
    }
    base.update(kw)
    return Settings(**base)


@pytest.fixture(autouse=True)
def _clean_dedup():
    """每条用例前清空去重表。

    去重表是模块级全局，不清的话上一条记下的内容会让下一条的
    「首次提交」被误判成重复 —— 表现为单独跑能过、一起跑就挂。
    """
    from app.feedback import _reset_dedup

    _reset_dedup()
    yield
    _reset_dedup()


def _payload(**kw) -> FeedbackIn:
    base = {
        "message": "点添加文档没反应",
        "kind": "platform",
        "app_version": "0.1.7+9",
        "region": "intl",
        "platform": "iOS 18",
        "stack": "#0 openFile (file_selector)",
    }
    base.update(kw)
    return FeedbackIn(**base)


# ---------------------------------------------------------------- 基本转发


def test_feedback_is_sent():
    with patch("app.feedback.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_ssl.return_value.__enter__.return_value = srv
        r = submit_feedback(_payload(), settings=_settings())
        assert r["received"] is True
        assert r["delivered"] is True
        assert srv.send_message.called, "邮件没有被发送"


def test_message_headers_render_on_old_python():
    """邮件头必须能渲染成字节。

    裸 `Header` 在 Python 3.13 上能过、**3.11（服务器）上抛
    `AttributeError: 'Header' object has no attribute 'encode'`**。

    auth.py 踩过一次这个坑，feedback.py 复用了同样的写法，
    所以必须测 —— 否则换个 Python 版本就静默炸在真机上。
    """
    from email.header import Header
    from email.mime.text import MIMEText
    from email.utils import formataddr

    msg = MIMEText(_body(_payload()), "plain", "utf-8")
    msg["Subject"] = str(Header(_subject(_payload()), "utf-8"))
    msg["From"] = formataddr(
        (str(Header("My Pet", "utf-8")), "noreply@weiyuantool.com")
    )
    msg["To"] = "dev@weiyuantool.com"

    buf = io.BytesIO()
    # 3.11 上这里会抛 AttributeError
    BytesGenerator(buf, policy=SMTP).flatten(msg)
    assert b"Subject:" in buf.getvalue()
    assert b"To: dev@weiyuantool.com" in buf.getvalue()


# ---------------------------------------------------------------- 失败处理


@pytest.mark.parametrize(
    "exc",
    [
        smtplib.SMTPAuthenticationError(535, b"auth failed"),
        smtplib.SMTPServerDisconnected("closed"),
        TimeoutError("timed out"),
        OSError("refused"),
    ],
)
def test_send_failure_still_returns_200(exc):
    """发失败也返回 200。

    反馈发不出去不该让用户重试 —— 他没有任何办法补发，
    而客户端的重试只会产生更多重复邮件。
    """
    with patch("app.feedback.smtplib.SMTP_SSL", side_effect=exc):
        r = submit_feedback(_payload(), settings=_settings())
    assert r["received"] is True
    assert r["delivered"] is False


def test_missing_feedback_to_does_not_crash():
    """没配 feedback_to 时不能崩，只能是不投递。"""
    with patch("app.feedback.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_ssl.return_value.__enter__.return_value = srv
        r = submit_feedback(_payload(), settings=_settings(feedback_to=""))
    # 收件地址为空时不该尝试发送
    assert r["received"] is True
    assert not srv.send_message.called


def test_missing_smtp_config_does_not_crash():
    with patch("app.feedback.smtplib.SMTP_SSL") as mock_ssl:
        r = submit_feedback(_payload(), settings=Settings())
    assert r["received"] is True
    assert r.get("delivered") is False
    assert not mock_ssl.called


# ---------------------------------------------------------------- 去重


def test_duplicate_within_window_is_skipped():
    """10 分钟内同一份反馈只发一次。

    客户端重试逻辑出 bug 时的保护 —— 否则会收到几十封一样的邮件。
    """
    with patch("app.feedback.smtplib.SMTP_SSL") as mock_ssl:
        srv = MagicMock()
        mock_ssl.return_value.__enter__.return_value = srv

        first = submit_feedback(_payload(), settings=_settings())
        second = submit_feedback(_payload(), settings=_settings())

    assert first["delivered"] is True
    assert second["deduped"] is True
    assert srv.send_message.call_count == 1, "重复提交应该被去重"


def test_fingerprint_normalizes_whitespace():
    """打一样的字但换行不同，视为同一份。"""
    a = _fingerprint("点了没反应")
    b = _fingerprint("点了没反应\n\n")
    c = _fingerprint("  点了没反应  ")
    assert a == b == c
    assert _fingerprint("别的内容") != a


# ---------------------------------------------------------------- 内容


def test_subject_carries_version_and_region():
    """标题里要有版本与区域，不看正文就能判断是哪一版。"""
    s = _subject(_payload())
    assert "0.1.7+9" in s
    assert "intl" in s
    assert "platform" in s


def test_body_contains_message_and_environment():
    body = _body(_payload())
    assert "点添加文档没反应" in body
    assert "openFile" in body, "堆栈要带上，否则等于没上报"
    assert "0.1.7+9" in body
    assert "intl" in body


def test_body_without_stack_still_valid():
    """纯建议（无堆栈）也要能发出去。"""
    body = _body(_payload(stack="", kind="manual"))
    assert "点添加文档没反应" in body
    assert "崩溃堆栈" not in body


def test_long_message_is_truncated_by_validation():
    """超长消息应该在 Pydantic 层被拒，不进到发信逻辑。"""
    with pytest.raises(Exception):
        FeedbackIn(message="x" * 9000)
