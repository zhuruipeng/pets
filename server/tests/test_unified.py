"""统一账号换票的纯逻辑测试。

刻意不碰数据库、不碰网络：用注入的假 opener 替代真实 HTTP，
这样「官网返回 401 时我们判成什么」「响应字段改名时我们会不会
静默建出空手机号账号」这类真正危险的判断都能在本机跑。

只读得到 DB 的部分（按手机号找/建用户、签发令牌）属于路由层，
留给集成测试 —— 那部分没有分支，错了会立刻在联调时暴露。
"""

from __future__ import annotations

import json
import urllib.error

import pytest

from app.config import Settings
from app.unified import (
    ME_PATH,
    UnifiedAccountError,
    fetch_unified_account,
    parse_me_payload,
    unified_enabled,
)

# ------------------------------------------------------------- 测试替身


class _FakeResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body
        self.closed = False

    def read(self) -> bytes:
        return self._body

    def close(self) -> None:
        self.closed = True


def _opener(body: bytes | None = None, *, error: Exception | None = None):
    """造一个假 opener，顺便把收到的 request 记下来供断言。"""
    seen: dict[str, object] = {}

    def call(request, timeout):  # noqa: ANN001
        seen["url"] = request.full_url
        seen["headers"] = {k.lower(): v for k, v in request.header_items()}
        seen["method"] = request.get_method()
        seen["timeout"] = timeout
        if error is not None:
            raise error
        return _FakeResponse(body or b"")

    call.seen = seen  # type: ignore[attr-defined]
    return call


def _http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "https://weiyuantool.com/api/auth/me", code, "err", {}, None
    )


def _me_body(**account_overrides) -> bytes:
    account = {
        "id": 42,
        "phone": "13800138000",
        "nickname": "阿黄的主人",
        "status": "active",
    }
    account.update(account_overrides)
    return json.dumps(
        {"ok": True, "account": account, "services": []},
        ensure_ascii=False,
    ).encode("utf-8")


# ------------------------------------------------------- unified_enabled


def test_unified_enabled_on_cn_with_base_url():
    s = Settings(_env_file=None, region="cn", unified_account_base_url="https://weiyuantool.com")
    assert unified_enabled(s) is True


def test_unified_enabled_off_on_cn_without_base_url():
    s = Settings(_env_file=None, region="cn", unified_account_base_url="")
    assert unified_enabled(s) is False


def test_unified_enabled_off_on_intl_even_if_configured():
    # 海外区即使误配了地址也不启用：数据不出境是红线，不该靠运维记得别配。
    s = Settings(_env_file=None, region="intl", unified_account_base_url="https://weiyuantool.com")
    assert unified_enabled(s) is False


def test_unified_enabled_treats_whitespace_as_empty():
    s = Settings(_env_file=None, region="cn", unified_account_base_url="   ")
    assert unified_enabled(s) is False


# ------------------------------------------------------ parse_me_payload


def test_parse_me_payload_happy_path():
    body = json.loads(_me_body().decode("utf-8"))
    acc = parse_me_payload(body)
    assert acc is not None
    assert acc.account_id == "42"
    assert acc.phone == "+8613800138000"
    assert acc.nickname == "阿黄的主人"


def test_parse_me_payload_normalizes_phone_variants():
    # 官网存 11 位，客户端可能填带 +86 或带横杠的，三种必须落到同一个号码。
    for raw in ("13800138000", "+8613800138000", "138-0013-8000"):
        body = json.loads(_me_body(phone=raw).decode("utf-8"))
        acc = parse_me_payload(body)
        assert acc is not None, raw
        assert acc.phone == "+8613800138000", raw


def test_parse_me_payload_rejects_non_dict():
    assert parse_me_payload(None) is None
    assert parse_me_payload([]) is None
    assert parse_me_payload("ok") is None


def test_parse_me_payload_requires_ok_true():
    # 官网把 ok 去掉或改成别的值时必须拒绝，不能「凑合能读就用」。
    assert parse_me_payload({"account": {"id": 1, "phone": "13800138000"}}) is None
    assert parse_me_payload({"ok": False, "account": {"id": 1, "phone": "13800138000"}}) is None


def test_parse_me_payload_requires_account_dict():
    assert parse_me_payload({"ok": True}) is None
    assert parse_me_payload({"ok": True, "account": "13800138000"}) is None


def test_parse_me_payload_requires_account_id():
    body = json.loads(_me_body().decode("utf-8"))
    body["account"].pop("id")
    assert parse_me_payload(body) is None


def test_parse_me_payload_rejects_empty_phone():
    # 这是最要命的一种：空手机号会绕过 users 唯一键，每次登录新建一个账号。
    for bad in ("", "   ", None):
        body = json.loads(_me_body(phone=bad).decode("utf-8"))
        assert parse_me_payload(body) is None, bad


def test_parse_me_payload_rejects_phone_like_garbage():
    for bad in ("abc", "13800138000abc", "+", "+abc", "++86"):
        body = json.loads(_me_body(phone=bad).decode("utf-8"))
        assert parse_me_payload(body) is None, bad


def test_parse_me_payload_falls_back_to_phone_as_nickname():
    for missing in ("", None, "   "):
        body = json.loads(_me_body(nickname=missing).decode("utf-8"))
        acc = parse_me_payload(body)
        assert acc is not None
        assert acc.nickname == "+8613800138000"


# -------------------------------------------------- fetch_unified_account


def test_fetch_sends_bearer_header_and_hits_me_path():
    opener = _opener(_me_body())
    acc = fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert acc.phone == "+8613800138000"
    assert opener.seen["url"] == "https://weiyuantool.com" + ME_PATH
    assert opener.seen["headers"]["authorization"] == "Bearer tok-12345678"
    assert opener.seen["method"] == "GET"


def test_fetch_strips_trailing_slash_in_base_url():
    opener = _opener(_me_body())
    fetch_unified_account("https://weiyuantool.com/", "tok-12345678", opener=opener)
    # 拼成 //api/auth/me 的话，nginx 上通常会被重定向，多一跳且可能丢 Authorization。
    assert opener.seen["url"] == "https://weiyuantool.com" + ME_PATH


def test_fetch_passes_timeout_through():
    opener = _opener(_me_body())
    fetch_unified_account("https://weiyuantool.com", "tok-12345678", timeout=2.5, opener=opener)
    assert opener.seen["timeout"] == 2.5


@pytest.mark.parametrize("code", [401, 403])
def test_fetch_maps_auth_failures_to_invalid_token(code):
    opener = _opener(error=_http_error(code))
    with pytest.raises(UnifiedAccountError) as exc:
        fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert exc.value.reason == "invalid_token"


@pytest.mark.parametrize("code", [500, 502, 504, 422])
def test_fetch_maps_other_statuses_to_unreachable(code):
    # 422（我们请求写错了）也归不可达：不能告诉用户「你的令牌废了」，
    # 那会让他去重新登录，而真正的问题在我们这边。
    opener = _opener(error=_http_error(code))
    with pytest.raises(UnifiedAccountError) as exc:
        fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert exc.value.reason == "unreachable"


def test_fetch_maps_network_error_to_unreachable():
    opener = _opener(error=urllib.error.URLError("connection refused"))
    with pytest.raises(UnifiedAccountError) as exc:
        fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert exc.value.reason == "unreachable"


def test_fetch_maps_timeout_to_unreachable():
    opener = _opener(error=TimeoutError("timed out"))
    with pytest.raises(UnifiedAccountError) as exc:
        fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert exc.value.reason == "unreachable"


def test_fetch_maps_non_json_body_to_bad_response():
    opener = _opener(b"<html>502 Bad Gateway</html>")
    with pytest.raises(UnifiedAccountError) as exc:
        fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert exc.value.reason == "bad_response"


def test_fetch_maps_unusable_payload_to_bad_response():
    opener = _opener(json.dumps({"ok": True, "account": {"id": 1}}).encode())
    with pytest.raises(UnifiedAccountError) as exc:
        fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    assert exc.value.reason == "bad_response"


def test_fetch_closes_response():
    opener = _opener(_me_body())
    fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=opener)
    # 不关响应会漏连接；本机测试看不出来，压测时才会现形。
    assert opener.seen.get("closed", True) is True


def test_fetch_does_not_use_default_opener_when_injected():
    # 注入 opener 时绝不该落到真实网络：本机跑测试不该发出任何请求。
    calls = {"n": 0}

    def call(request, timeout):  # noqa: ANN001
        calls["n"] += 1
        return _FakeResponse(_me_body())

    fetch_unified_account("https://weiyuantool.com", "tok-12345678", opener=call)
    assert calls["n"] == 1
