"""法律页面（隐私政策 / 用户协议 / 注销说明）的测试。

这些页面是**应用商店上架的前置条件**：国内各家商店与 Google Play 都要求在
后台填一个可公开访问的隐私政策网址，审核方会自己去打开。所以「404 了」
「文件没打进镜像」「页面里的链接指向一个不存在的地址」都是会直接卡住上架
的问题，值得用测试钉住 —— 而且它们全都是纯文件，零依赖、秒级可跑。

刻意不去测 HTTP 层（TestClient 需要拉起整个 app 与数据库）：路由只有
「查白名单 → 读文件 → 返回」三步，真正会错的是白名单判定和文件本身。
"""

from __future__ import annotations

import re

import pytest

from app.main import LEGAL_ALIASES, LEGAL_DIR, LEGAL_PAGES, resolve_legal_slug

# --------------------------------------------------------- 白名单与路径穿越


@pytest.mark.parametrize(
    "slug,expected",
    [
        ("privacy", "privacy"),
        ("terms", "terms"),
        ("account-deletion", "account-deletion"),
    ],
)
def test_canonical_slugs(slug, expected):
    assert resolve_legal_slug(slug) == expected


@pytest.mark.parametrize(
    "slug",
    [
        "privacy-policy",
        "privacy-policy.html",
        "PRIVACY",
        "Privacy-Policy.HTML",
        "privacy_policy",
    ],
)
def test_privacy_variants_all_resolve_to_same_page(slug):
    # 商店后台的输入框各式各样，链接后缀写错一个字符就是 404，
    # 而审核方看到 404 会直接判「未提供隐私政策」。
    assert resolve_legal_slug(slug) == "privacy"


@pytest.mark.parametrize(
    "slug",
    ["terms-of-use", "terms-of-use.html", "TERMS", "terms_of_use"],
)
def test_terms_variants(slug):
    assert resolve_legal_slug(slug) == "terms"


@pytest.mark.parametrize(
    "slug",
    ["account_deletion", "delete-account", "account-deletion.html"],
)
def test_deletion_variants(slug):
    assert resolve_legal_slug(slug) == "account-deletion"


@pytest.mark.parametrize(
    "slug",
    [
        "",
        "   ",
        "nope",
        # 目录穿越的几种写法：全都不该通过。这是这个函数存在的首要理由。
        "../app/config",
        "../../etc/passwd",
        "..%2fapp%2fconfig",
        "privacy/../../app/config",
        "privacy-policy.html/../../../app/config",
        ".",
        "..",
    ],
)
def test_rejects_everything_else(slug):
    assert resolve_legal_slug(slug) is None


def test_alias_table_only_points_at_real_keys():
    # 别名表写错一个目标，就是一条永远 404 的链接。
    for alias, target in LEGAL_ALIASES.items():
        assert target in LEGAL_PAGES, alias


# ------------------------------------------------------------- 文件本身


def test_every_whitelisted_page_has_a_file():
    missing = [f for f in LEGAL_PAGES.values() if not (LEGAL_DIR / f).is_file()]
    assert missing == [], f"缺文件: {missing}（会被打成 503，商店审核看到就卡住）"


@pytest.mark.parametrize("key,filename", sorted(LEGAL_PAGES.items()))
def test_page_is_a_complete_html_document(key, filename):
    text = (LEGAL_DIR / filename).read_text(encoding="utf-8")
    assert text.startswith("<!DOCTYPE html>")
    assert '<html lang="zh-CN">' in text
    assert '<meta charset="utf-8">' in text
    # 手机上看是常态，没有 viewport 会缩成一团。
    assert "width=device-width" in text
    assert re.search(r"<title>.+</title>", text)
    assert "</html>" in text


@pytest.mark.parametrize("key,filename", sorted(LEGAL_PAGES.items()))
def test_page_has_substance(key, filename):
    # 一行占位符也能「返回 200」，但那过不了审核。
    text = (LEGAL_DIR / filename).read_text(encoding="utf-8")
    assert len(text) > 3000, f"{filename} 太短，像是占位页"
    assert "临沂未远工具" in text


@pytest.mark.parametrize("key,filename", sorted(LEGAL_PAGES.items()))
def test_page_has_contact_email(key, filename):
    # 商店要求隐私政策里必须有可联系到运营者的方式。
    text = (LEGAL_DIR / filename).read_text(encoding="utf-8")
    assert "zhuruipeng@weiyuantool.com" in text


@pytest.mark.parametrize("key,filename", sorted(LEGAL_PAGES.items()))
def test_internal_links_all_resolve(key, filename):
    """页面里写的每个 /legal/xxx 链接都必须能落到一个真实页面上。

    这条抓的是「三页互链时把一个 slug 写错」—— 点进去 404，
    但页面本身返回 200，人工抽查很容易漏。
    """
    text = (LEGAL_DIR / filename).read_text(encoding="utf-8")
    for slug in re.findall(r'href="/legal/([^"]+)"', text):
        assert resolve_legal_slug(slug) is not None, f"{filename} 里有死链: /legal/{slug}"


@pytest.mark.parametrize("key,filename", sorted(LEGAL_PAGES.items()))
def test_no_unfinished_placeholders(key, filename):
    text = (LEGAL_DIR / filename).read_text(encoding="utf-8")
    for bad in ("TODO", "FIXME", "待填", "xxx@", "<待"):
        assert bad not in text, f"{filename} 里还有未完成标记: {bad}"


# ------------------------------------------------------------- 路由函数本体


def test_route_returns_html():
    # 直接调路由函数，不经过 TestClient：TestClient 会跑 lifespan（init_db），
    # 而本机/CI 上不一定有 PostgreSQL。这里要验的只是「白名单 → 读文件 →
    # 返回 HTML」这段，不涉及数据库。
    from fastapi.responses import HTMLResponse

    from app.main import legal_page

    resp = legal_page("privacy")
    assert isinstance(resp, HTMLResponse)
    assert resp.status_code == 200
    body = resp.body.decode("utf-8")
    assert "隐私政策" in body
    assert "临沂未远工具" in body


def test_route_404_for_unknown_slug():
    from fastapi import HTTPException

    from app.main import legal_page

    with pytest.raises(HTTPException) as exc:
        legal_page("nope")
    assert exc.value.status_code == 404


def test_route_503_when_file_missing(monkeypatch, tmp_path):
    # 文件没打进镜像时（比如 Dockerfile 只 COPY 了 app/）必须是 503 而不是 404：
    # 审核方看到 404 会判「未提供隐私政策」，503 至少知道是部署故障可重试。
    from fastapi import HTTPException

    from app import main as main_mod

    monkeypatch.setattr(main_mod, "LEGAL_DIR", tmp_path)
    with pytest.raises(HTTPException) as exc:
        main_mod.legal_page("privacy")
    assert exc.value.status_code == 503


def test_mounting_app_does_not_crash():
    """整个 app 能装配起来。

    这条守的是一个真实踩过的坑：`from __future__ import annotations` 之下，
    一个 `status_code=204` 的路由只要写了 `-> None` 返回注解，FastAPI 在注册
    路由时就会断言失败（Status code 204 must not have a response body），
    而那发生在**导入模块时** —— 服务根本起不来，且报错完全不提注解。
    """
    from app.main import app

    # 用 openapi() 拿路由表，而不是遍历 app.routes 取 path：
    # FastAPI 0.142+ 用 _IncludedRouter 懒加载嵌套路由，app.routes 里这些
    # include_router 出来的项 path 是 None，直接 getattr 会漏掉 /api/v1/*。
    paths = set(app.openapi()["paths"].keys())
    assert "/legal/{slug}" in paths
    assert "/api/v1/auth/unified" in paths
