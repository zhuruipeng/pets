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
    # lang 必须与页面语言一致。原先这里硬断言 zh-CN，加了英文版之后
    # 英文页声明错语言会被屏幕阅读器按中文念 —— 审核也可能挑出来。
    expected_lang = "en" if key.endswith(":en") else "zh-CN"
    assert f'<html lang="{expected_lang}">' in text
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
    # 运营方名：中文页用全称，英文页用英文名。两条都要能查到。
    operator = "Linyi Weiyuan Tools" if key.endswith(":en") else "临沂未远工具"
    assert operator in text, f"{filename} 里找不到运营方名（{operator}）"


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

    ⚠️ 链接上可能带 `?lang=en`，校验时要把查询参数剥掉：
    之前没有语言参数，slug 就是整个段；现在 `privacy?lang=en` 整串拿去查表会
    查不到，误报成死链。
    """
    text = (LEGAL_DIR / filename).read_text(encoding="utf-8")
    for raw in re.findall(r'href="/legal/([^"]+)"', text):
        slug, _, query = raw.partition("?")
        assert resolve_legal_slug(slug) is not None, f"{filename} 里有死链: /legal/{raw}"
        # 带 ?lang=en 的链接必须真的能拿到英文页，否则等于把用户送去中文页
        if query == "lang=en":
            assert resolve_legal_slug(slug, "en").endswith(":en"), (
                f"{filename} 里 /legal/{raw} 声称是英文版，但英文版解析不到"
            )


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


# ---------------------------------------------------------------- 多语言版
#
# 海外版（com.weiyuantool.pet）上架要求隐私政策是英文的，而商店后台会同时
# 打开 App 内版本与网页版本对照。两处不一致 → 要求补材料，所以双语都要有。
#
# `lang` 是**用户输入**，会参与拼文件名，因此归一化必须在白名单判定之前完成 ——
# 这是本组测试的重点，不是 lang=en 能不能取到英文页。


@pytest.mark.parametrize(
    "slug,expected",
    [
        ("privacy", "privacy:en"),
        ("terms", "terms:en"),
        ("account-deletion", "account-deletion:en"),
        # 别名写法同样要跟到英文版
        ("privacy-policy", "privacy:en"),
        ("PRIVACY", "privacy:en"),
        ("terms-of-use.html", "terms:en"),
        ("delete-account", "account-deletion:en"),
    ],
)
def test_lang_en_resolves_to_english(slug, expected):
    assert resolve_legal_slug(slug, "en") == expected


@pytest.mark.parametrize("lang", ["zh", "", "ZH", "zh-CN", "zh_cn", None])
def test_non_en_lang_falls_back_to_chinese(lang):
    """没传、传中文、传中文地区码 —— 一律中文，行为与加英文版之前完全一致。

    这条很重要：商店后台里原来填的中文链接不能因为这次改动而变样。
    """
    assert resolve_legal_slug("privacy", lang) == "privacy"


def test_lang_is_case_insensitive():
    assert resolve_legal_slug("privacy", "EN") == "privacy:en"
    assert resolve_legal_slug("privacy", "En") == "privacy:en"


@pytest.mark.parametrize(
    "lang",
    [
        "../../../etc/passwd",
        "..%2f..%2f..%2fetc%2fpasswd",
        "en/../../app/config",
        "..",
        "/etc/passwd",
        "en;rm -rf /",
    ],
)
def test_lang_cannot_traverse_path(lang):
    """`lang` 参与拼文件名，穿越必须被挡住。

    这是加 `lang` 参数引入的新面 —— 原先只有 slug 一个用户输入参与拼路径。
    归一化把这个值收窄到 `en` / 非 en 两支，任何穿越写法都落不到文件名上。
    """
    got = resolve_legal_slug("privacy", lang)
    # 要么被拒（None），要么安全地落在白名单键上。
    if got is not None:
        assert got in LEGAL_PAGES


def test_lang_en_falls_back_to_chinese_when_english_file_missing(monkeypatch):
    """英文文件没打进镜像时回落中文，**不是 404**。

    商店审核拿着英文链接看到 404 会直接判「未提供隐私政策」而拒审；
    语言不对但内容在，明显是更好的失败。

    做法：把 `LEGAL_PAGES["privacy:en"]` 指向一个**不存在的文件名**，
    而不是去 mock `Path.is_file` —— 后者会把 `is_file` 打成实例方法，
    而 `Path.is_file` 实际上是个不接受额外位置参数的内部实现，
    mock 起来比绕开它脆弱得多。
    """
    import app.main as main_mod

    monkeypatch.setitem(
        main_mod.LEGAL_PAGES, "privacy:en", "definitely-not-shipped.html"
    )

    # 不抛异常，且返回的页面是中文版（lang="zh-CN"）
    resp = main_mod.legal_page("privacy", "en")
    assert '<html lang="zh-CN">' in resp.body.decode("utf-8")


def test_lang_en_never_404s_even_when_english_file_missing(monkeypatch):
    """缺文件时的状态码只能是 503，绝不能是 404。

    404 在商店审核眼里等于「未提供隐私政策」，直接拒审；503 至少表达了
    「临时故障，稍后重试」。这条守住状态码别退化。

    注意中文文件是存在的，所以函数会**成功回落并返回中文页**而不抛异常 ——
    这正是回落逻辑该有的行为。抛异常只发生在连中文文件都没有时（见下一条）。
    """
    import app.main as main_mod

    monkeypatch.setitem(
        main_mod.LEGAL_PAGES, "privacy:en", "definitely-not-shipped.html"
    )

    # 回落成功：返回 200 内容为中文页
    resp = main_mod.legal_page("privacy", "en")
    assert '<html lang="zh-CN">' in resp.body.decode("utf-8")

    # 连中文文件也缺时 → 503，不是 404
    # ⚠️ 要改的是 `"privacy"` 键（中文版的键名就是 "privacy"，没有 ":zh" 后缀）——
    # 写成 "privacy:zh" 改的是一个根本不存在的键，回落照样成功，测试就废了。
    monkeypatch.setitem(
        main_mod.LEGAL_PAGES, "privacy", "also-not-shipped.html"
    )
    with pytest.raises(main_mod.HTTPException) as exc:
        main_mod.legal_page("privacy", "en")
    assert exc.value.status_code == 503, "缺文件时必须是 503，404 会被判未提供"


def test_english_files_exist_and_declare_lang_en():
    """三个英文页都在，且 <html lang> 是 en。

    lang 声明错了，屏幕阅读器会按中文念英文内容，审核也可能挑出来。
    """
    for key, filename in LEGAL_PAGES.items():
        if not key.endswith(":en"):
            continue
        path = LEGAL_DIR / filename
        assert path.is_file(), f"缺少英文版 {filename}"
        head = path.read_text(encoding="utf-8")[:400]
        assert '<html lang="en">' in head, f"{filename} 的 html lang 不是 en"

