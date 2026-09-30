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
