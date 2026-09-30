"""区域与运行环境配置。

中国区与海外区共用同一套服务端代码，靠环境变量 REGION 区分部署。
数据分区：中国用户数据只存中国节点，海外用户数据只存海外节点，
因此不需要做 PIPL 出境评估，也不需要 GDPR 的 SCCs。

用法：
    REGION=cn   uvicorn app.main:app --host 0.0.0.0 --port 8000
    REGION=intl uvicorn app.main:app --host 0.0.0.0 --port 8000
"""

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

Region = Literal["cn", "intl"]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # 部署区域。决定合规行为与默认数据域，不决定业务逻辑。
    region: Region = "intl"

    # 数据库。两区各自独立，绝不互连。
    database_url: str = "postgresql+psycopg://pet:pet@localhost:5432/pet"

    # 逆地理编码 Key（服务端备用通道；客户端也各有一套）
    amap_key: str = ""
    mapbox_token: str = ""

    # 对象存储（照片）
    storage_bucket: str = ""
    storage_region: str = ""

    # ---- 应用内更新 ----
    # 客户端启动时会 GET /app/version.json，拿这份配置和自己本机的
    # versionName / versionCode 比。**发新版时只改这几个环境变量并重启服务，
    # 不用动代码**，这是把它做成接口而不是静态文件的原因。
    #
    # app_build 必须与客户端 pubspec.yaml 的 version 段（+ 号后的数字）
    # 严格同源递增：客户端拿 versionCode 比大小，比错了会反复提示更新。
    app_version: str = "0.1.0"
    app_build: int = 1

    # APK 直链。可以放在对象存储/CDN，不必与接口同域 ——
    # 但要保证是 **HTTPS**：Android 9+ 默认禁止明文 HTTP。
    app_apk_url: str = ""

    # 更新说明，纯文本，换行即分段。
    app_notes: str = ""

    # 低于这个 build 强制更新。用来推掉有严重问题的版本；
    # 留 0 表示不强制。
    app_min_build: int = 0

    # 海外区 iOS 跳商店用。国内不上 App Store，留空即可。
    app_ios_store_url: str = ""

    # ---- 账号与验证码 ----
    # 登录令牌有效期。用「天」而不是「秒」是因为这是个产品决策（用户多久
    # 要重新登录一次），不是调参项；30 天兼顾了「不用天天登录」与「丢了手机
    # 不至于永久有效」。令牌可被 /auth/logout 立即撤销，所以这个值不承担安全兜底。
    token_ttl_days: int = 30

    # 验证码有效期 5 分钟：短到被猜中的窗口很小，长到用户找得到手机。
    code_ttl_seconds: int = 300

    # 同一 target 的重发间隔。防的是「点一下没收到就连点十下」，
    # 顺带把短信费用按住。调大不影响正常用户（重发一次就够）。
    code_resend_seconds: int = 60

    # 是否在响应里回显验证码。**只能在开发/联调环境开启** ——
    # 默认 True 是为了「不接短信服务商也能把整条登录链路跑通」；
    # 上线前必须置 false，否则任何人都能拿别人的手机号直接登录。
    dev_echo_code: bool = True

    # 短信/邮件服务商标识。留空表示「没有配置真实通道」，此时只写库不发码，
    # 依赖 dev_echo_code 回显。中国区短信需模板报备，海外区可用邮件兜底。
    #
    # 注意（A 方案之后）：**中国区已不再需要这两个通道** —— cn 区登录走官网
    # 统一账号，验证码由官网的阿里云短信发出去，本服务端只负责换票
    # （见 unified.py）。这里保留是为海外区（邮件兜底）和本地联调。
    sms_provider: str = ""
    email_provider: str = ""

    # ---- 统一账号（仅中国区，A 方案）----
    # 官网账号域地址，例如 https://weiyuantool.com。
    # 留空 = 这个部署不提供统一账号登录，/api/v1/auth/unified 直接 404。
    # 海外区即使误配了也不会启用：unified_enabled() 同时要求 region == "cn"。
    unified_account_base_url: str = ""

    # 换票时请求官网的超时（秒）。换票发生在登录界面上，属于用户等待中的
    # 同步操作，宁可早点报「稍后再试」也不要让界面一直转。
    unified_account_timeout_seconds: float = 5.0

    # 是否强制要求备案号展示（中国区合规）
    @property
    def requires_icp_display(self) -> bool:
        return self.region == "cn"

    @property
    def allows_cross_border(self) -> bool:
        """永远返回 False。

        这是架构红线：数据不出境。凡是想做跨境同步的需求，
        都应该改成「两区各自独立」，而不是放开这个开关。
        """
        return False


@lru_cache
def get_settings() -> Settings:
    return Settings()
