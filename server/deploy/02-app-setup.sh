#!/usr/bin/env bash
#
# 宠物服务端 —— 环境准备（venv / 依赖 / .env / systemd）
#
# 幂等：
#   - venv 已存在就复用，依赖走 pip 的增量安装；
#   - .env **已存在就不覆盖**（之后的调参都在服务器上直接改，重跑本脚本
#     不该把 APP_BUILD 冲回去）；
#   - unit 文件总是重写（它是代码的一部分，应当与仓库一致）。
set -euo pipefail

APP_DIR=/opt/pet-api
VENV="$APP_DIR/venv"
UNIT=/etc/systemd/system/pet-api.service
PASS_FILE=/root/.pet-db-pass

# ---- 0. 前置检查 ------------------------------------------------------------
[ -f "$PASS_FILE" ] || { echo "[X] 缺 $PASS_FILE —— 先跑 01-postgres-bootstrap.sh"; exit 1; }
[ -f "$APP_DIR/requirements.txt" ] || { echo "[X] 缺 $APP_DIR/requirements.txt —— 代码没传上来"; exit 1; }
DB_PASS="$(cat "$PASS_FILE")"

# ---- 1. 属主 ----------------------------------------------------------------
# 代码是从 Windows 用 tar 传上来的，解出来带着本机的 UID/GID（197108:197121），
# 在这台机器上并不存在。不改回 root 的话，服务以 root 跑时读 .env、写日志
# 是否成功全看运气（Python 只按 owner 权限位判断，问题会拖到运行期才暴露）。
chown -R root:root "$APP_DIR"
chmod 755 "$APP_DIR"
echo "[+] 属主已归 root"

# ---- 2. 虚拟环境 ------------------------------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    echo "[+] 已创建 venv（$(python3 --version)）"
else
    echo "[=] venv 已存在，复用"
fi

# 清华镜像：本机实测 pypi.org 直连 15s 才通（正好卡在超时线上），
# 镜像 3.5s。装依赖是部署里最容易莫名其妙卡住的一步。
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -i https://pypi.tuna.tsinghua.edu.cn/simple \
    -r "$APP_DIR/requirements.txt"
echo "[+] 依赖已安装："
"$VENV/bin/pip" list --format=freeze 2>/dev/null | grep -iE "^(fastapi|uvicorn|gunicorn|sqlalchemy|psycopg|pydantic)" | sed 's/^/      /'

# ---- 3. .env ---------------------------------------------------------------
if [ -f "$APP_DIR/.env" ]; then
    echo "[=] .env 已存在，不覆盖。当前配置项："
    grep -oE "^[A-Z_]+" "$APP_DIR/.env" | sed 's/^/      /'
else
    cat > "$APP_DIR/.env" <<EOF
# 宠物 App 服务端 —— 生产环境变量（中国区）
# 由 deploy/02-app-setup.sh 首次生成。之后直接改本文件并 systemctl restart pet-api。

# 部署区域。决定合规行为与默认数据域，不决定业务逻辑。
REGION=cn

DATABASE_URL=postgresql+psycopg://pet:${DB_PASS}@127.0.0.1:5432/pet

# ---- 应用内更新 ----
# APP_BUILD 必须与客户端 pubspec.yaml version 段 + 号后的数字**严格相等**。
# 客户端拿 Android versionCode 与它比大小：服务端更大才算有新版。
APP_VERSION=0.1.0
APP_BUILD=2
# 走 /download/ 而不是 /app/ —— /app/version.json 是接口路径，
# 静态文件挂在 /app/ 下会把它抢走，应用内更新会静默失效。
APP_APK_URL=https://api.pet.weiyuantool.com/download/app-cn-release.apk
APP_NOTES=首个版本：宠物健康记录与提醒、回忆相册、账号登录
APP_MIN_BUILD=0
APP_IOS_STORE_URL=

# ---- 安全开关（上线红线）----
# true 时接口会把验证码原样回显在响应里，任何人都能拿别人手机号登录。
# 开发环境靠它绕开短信通道，生产**必须** false。
DEV_ECHO_CODE=false

# 中国区登录走官网统一账号（A 方案），验证码由官网发出，本服务端只换票。
# 必须带 www：裸域会让客户端那个 POST 撞上 301（Dart 的 HttpClient
# 不跟随非 GET 的 301），表现是「发验证码失败」而手工 GET 探测一切正常。
UNIFIED_ACCOUNT_BASE_URL=https://www.weiyuantool.com

# 短信通道：cn 区已不需要（验证码走官网），海外区也建议走邮件。
SMS_PROVIDER=
EMAIL_PROVIDER=

# ---- 邮件通道（SMTP）----
# 海外区发验证码用。腾讯企业邮箱的 SMTP 参数就是下面这一组，
# 零第三方依赖（Python 标准库 smtplib）。
#
# ⚠️ SMTP_PASSWORD 填**授权码**，不是登录密码。
# 企业邮箱后台「设置 → 客户端设置」里单独生成，形如 16 位随机串。
# 写成登录密码会在发信时 535 认证失败，而报错完全看不出这个原因。
#
# ⚠️ 这三项属于密钥。.env 权限是 600，**不要提交进仓库**。
SMTP_HOST=smtp.exmail.qq.com
SMTP_PORT=465
# 465 = 隐式 TLS（腾讯企业版就是它）。改 587 必须同时把这里改 false，
# 端口与 TLS 方式配错会在握手阶段就失败，报错看不出是端口问题。
SMTP_SECURE=true
SMTP_USER=noreply@weiyuantool.com
SMTP_PASSWORD=
# 发件地址必须与后台已验证的发件人一致，否则邮件进垃圾箱 ——
# 表现是「服务端说发出去了、用户说没收到」，日志一切正常。
SMTP_FROM_NAME=My Pet
SMTP_FROM_EMAIL=noreply@weiyuantool.com
EOF
    chmod 600 "$APP_DIR/.env"
    echo "[+] 已生成 /opt/pet-api/.env（600）"
fi

# ---- 4. systemd -------------------------------------------------------------
cat > "$UNIT" <<'EOF'
[Unit]
Description=Pet API (宠物 App 服务端，中国区)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
WorkingDirectory=/opt/pet-api
# 环境的唯一来源。改配置只改这个文件，不散落在 unit 里。
EnvironmentFile=/opt/pet-api/.env

# 建表放在服务启动**之前**，不要丢给每个 worker 的 lifespan 去各做一遍。
#
# 实测（2026-10-01 首次部署）：两个 worker 并发执行 create_all，表当时还不存在，
# 于是两边同时发 CREATE TABLE，其中一个必然撞上
#     UniqueViolation: duplicate key value violates unique constraint
#     "pg_type_typname_nsp_index"  DETAIL: Key (typname, typnamespace)=(users, 2200)
# 该 worker boot 失败 → gunicorn 主进程以 code=3 退出 → systemd 重启一次才起来。
# 结果是「第一次启动必失败、第二次才好」，而且只在表不存在时暴露，
# 所以本地单进程 uvicorn 开发时永远看不到。
#
# 表建好之后 create_all 走 checkfirst（先查 information_schema）直接跳过，
# 不会产生 DDL，因此这里跑一次就彻底消除竞态。
# main.py 的 lifespan 里那份 init_db() 保留着，是给本地开发兜底的，别删。
ExecStartPre=/opt/pet-api/venv/bin/python -c "from app.db import init_db; init_db()"

# 两个 worker：数据库调用是同步的，单进程时一个慢查询会把所有请求排在同一队。
# 只绑 127.0.0.1 —— 对外只经 nginx，不直接暴露端口。
ExecStart=/opt/pet-api/venv/bin/gunicorn app.main:app \
    --worker-class uvicorn.workers.UvicornWorker \
    --workers 2 \
    --bind 127.0.0.1:8200 \
    --access-logfile - \
    --error-logfile -
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
echo "[+] 已写入 $UNIT"

systemctl daemon-reload
systemctl enable --quiet pet-api.service
echo "[+] 已设置开机自启"

echo
echo "[OK] 环境就绪。下一步：systemctl start pet-api"
