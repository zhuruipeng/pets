"""配置层的安全测试（2026-10-11 P2）。

## 这组测试守什么

`smtp_password` 从 `str` 改成了 `pydantic` 的 `SecretStr`。理由：
授权码 = 用公司域名发信的权限，而 `str` 类型下任何一次
`repr(settings)` / `logger.info(settings)` / `model_dump()` 都会把它
**完整打印出来**。`SecretStr` 的 `repr()` 是 `'**********'`，
把「不小心打日志」这条最常见的泄露路径堵死。

改类型会带来一个**反直觉的坑**：`bool(SecretStr(""))` 是 **True**
（对象非空），所以不能再拿 `bool(settings.smtp_password)` 判「配没配」——
必须走 `settings.smtp_configured`。这组测试就是把这个坑钉死。
"""

from __future__ import annotations

from app.config import Settings


def _settings(**kw) -> Settings:
    base = {
        "smtp_host": "smtp.exmail.qq.com",
        "smtp_port": 465,
        "smtp_secure": True,
        "smtp_user": "noreply@weiyuantool.com",
        "smtp_password": "AUTH-CODE-NOT-A-PASSWORD",
        "smtp_from_email": "noreply@weiyuantool.com",
        "smtp_from_name": "My Pet",
    }
    base.update(kw)
    return Settings(**base)


# ---------------------------------------------------------------- 不泄露


def test_password_not_in_repr():
    """`repr(settings)` 里不能出现授权码明文。

    这是最实际的一条：调试时顺手 `print(settings)` 或异常里带上了
    settings，日志就会被写进 journald / 日志文件，而授权码一旦进了
    日志就等于已经泄露（日志会被备份、会被转发）。
    """
    s = _settings()
    assert "AUTH-CODE-NOT-A-PASSWORD" not in repr(s)


def test_password_not_in_str():
    s = _settings()
    assert "AUTH-CODE-NOT-A-PASSWORD" not in str(s)


def test_password_not_in_model_dump():
    """序列化（model_dump / json）也不能带明文。

    FastAPI 返回调试信息、或有人把它 dump 成 JSON 落盘，
    都会经过这条路。
    """
    s = _settings()
    dumped = s.model_dump()
    assert "AUTH-CODE-NOT-A-PASSWORD" not in str(dumped)
    # model_dump(mode="json") 也要挡住
    assert "AUTH-CODE-NOT-A-PASSWORD" not in str(s.model_dump(mode="json"))


def test_password_readable_on_demand():
    """确实要用时能取出来（发信要真的密码）。

    不能为了安全把它变得「取不出来」—— 那样只是把功能改坏。
    """
    s = _settings()
    assert s.smtp_password.get_secret_value() == "AUTH-CODE-NOT-A-PASSWORD"


# ---------------------------------------------------------------- 判「配没配」


def test_empty_password_means_not_configured():
    """⚠️ 核心的一条：空授权码必须判成「没配」。

    实测确认（pydantic 2.x）：`bool(SecretStr(""))` 是 **False** ——
    它按底层字符串的真假来判。所以 `bool(settings.smtp_password)`
    在这个版本上**恰好**是对的。

    那为什么还要有 `smtp_configured`？两个理由：

    1. **它是个隐式依赖**。`SecretStr.__bool__` 的行为是库的实现细节，
       不是接口承诺（官方文档没写这条）。哪天它改成「对象非空即真」，
       判据就静默反过来 —— 表现为「授权码没填却走了真实发信路径」。
       显式 `.get_secret_value()` 不依赖任何库的行为约定。

    2. **两个判据不等价**：`bool(pw)` 只看密码，而发信要三样齐备。
       少了 host 或 user 同样发不出去，但 `bool(settings.smtp_password)`
       会说是「已配置」。
    """
    s = _settings(smtp_password="")
    assert s.smtp_configured is False
    # 记录一下实测行为，避免后人再「发现」一次。
    assert bool(s.smtp_password) is False, (
        "若这条挂了，说明 pydantic 改了 SecretStr.__bool__ 的语义 —— "
        "正是 smtp_configured 要防的那种漂移"
    )


def test_configured_requires_all_three():
    """host / user / password 三缺一都不算配好。"""
    assert _settings().smtp_configured is True
    assert _settings(smtp_host="").smtp_configured is False
    assert _settings(smtp_user="").smtp_configured is False
    assert _settings(smtp_password="").smtp_configured is False


def test_default_settings_not_configured():
    """全默认值（什么都没配）时，不能误判成「已配置」。"""
    assert Settings().smtp_configured is False


def test_whitespace_password_is_treated_as_set():
    """纯空白授权码算「配了」—— 由 SMTP 去拒，不在配置层替它判。

    这条是记录一个**刻意的选择**：不在 `smtp_configured` 里做
    `.strip()`。空白串几乎只可能来自 `.env` 里手写错误，
    此时让它去 SMTP 认证失败并报明确的错，比在配置层静默当作
    「没配」（然后走 dev_echo_code 分支回显验证码）安全得多 ——
    后者在生产上是灾难。
    """
    s = _settings(smtp_password="   ")
    assert s.smtp_configured is True
