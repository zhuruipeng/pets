#!/usr/bin/env bash
#
# 宠物服务端 —— **海外区（intl）实例** 环境准备
#
# 为什么要单独一份而不是给 02-app-setup.sh 加参数：
# 那份脚本的路径、端口、unit 名全部写死（/opt/pet-api、8200、pet-api.service），
# 硬塞参数进去会让两个区域的配置纠缠在一起 —— 改一个区域的配置时
# 另一个区域的启动命令也跟着变，这类耦合迟早出「重启了 A 结果 B 也变了」的事故。
# 复制一份、只改该改的，比抽象一层更不容易出错。
#
# 隔离做到了哪一层（重要，别只记「起了个进程」）：
#   - **独立数据库** pet_intl（不是同一个库加 REGION 字段 ——
#     那种「逻辑隔离」在一次误连 DATABASE_URL 时就会失效）
#   - 独立端口 8201
#   - 独立 systemd unit，单独启停与开机自启
#   - 独立 nginx server 块，域名 api-intl.weiyuantool.com
#   - 独立 .env，REGION=intl，ICP 展示位与跨境标志位自动关闭
#
# 幂等：venv 存在则复用、.env 存在不覆盖、unit 总是重写。
set -euo pipefail

APP_DIR=/opt/pet-api-intl
VENV="$APP_DIR/venv"
UNIT=/etc/systemd/system/pet-api-intl.service
DB_NAME=pet_intl
PORT=8201
PASS_FILE=/root/.pet-db-pass

echo "=== 海外区实例部署 ==="
echo "  目录   $APP_DIR"
echo "  端口   127.0.0.1:$PORT"
echo "  单元   $UNIT"
echo

# ---- 0. 前置检查 ------------------------------------------------------------
[ -f "$PASS_FILE" ] || {
    echo "[X] 缺 $PASS_FILE —— 先跑 01-postgres-bootstrap.sh"; exit 1; }
[ -f "$APP_DIR/requirements.txt" ] || {
    echo "[X] 缺 $APP_DIR/requirements.txt"
    echo "    先把代码传到这个目录，例如："
    echo "      rsync -av --exclude venv --exclude .env \\"
    echo "        ./app/ root@<服务器>:$APP_DIR/"
    exit 1; }
DB_PASS="$(cat "$PASS_FILE")"

# ---- 1. 数据库 --------------------------------------------------------------
# ⚠️ **必须独立数据库，不能只靠 REGION 字段区分。**
#
# 同库加字段那种做法看着一样，问题是隔离只有「应用层自觉」一道闸：
# 一次 DATABASE_URL 写错、或者某个脚本连错库，海外用户数据就写进中国区库了 ——
# 而那正是 PIPL 要避免的事，且**事后无法审计**（库里混着两类数据，
# 你根本查不出哪条是哪区的用户）。
#
# 独立库的成本是多占几百 MB，收益是隔离由数据库保证，不依赖代码不出错。
if su - postgres -c "psql -q -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" | grep -q 1; then
    echo "[=] 数据库 ${DB_NAME} 已存在"
else
    su - postgres -c "psql -q -c \"CREATE DATABASE ${DB_NAME} OWNER pet ENCODING 'UTF8' TEMPLATE template0;\""
    echo "[+] 已创建数据库 ${DB_NAME}"
fi
# PG 15 起 public schema 不再默认给普通用户 CREATE 权限，不放开的话
# 首次建表会报 "permission denied for schema public"。
su - postgres -c "psql -q -d ${DB_NAME} -c \"GRANT ALL ON SCHEMA public TO pet;\""
su - postgres -c "psql -q -d ${DB_NAME} -c \"ALTER SCHEMA public OWNER TO pet;\""
echo "[+] ${DB_NAME} 的 schema 权限就绪"

# ---- 2. venv 与依赖 ---------------------------------------------------------
if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV"
    echo "[+] 已创建 venv"
else
    echo "[=] venv 已存在，复用"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -i https://pypi.tuna.tsinghua.edu.cn/simple \
    -r "$APP_DIR/requirements.txt"
echo "[+] 依赖已安装"

# ---- 3. .env ----------------------------------------------------------------
if [ -f "$APP_DIR/.env" ]; then
    echo "[=] .env 已存在，不覆盖。当前配置项："
    grep -oE "^[A-Z_]+" "$APP_DIR/.env" | sed 's/^/      /'
else
    cat > "$APP_DIR/.env" <<EOF
# 宠物 App 服务端 —— **海外区**（intl）
# 由 deploy/07-app-setup-intl.sh 首次生成。之后改本文件并 systemctl restart pet-api-intl。

# 区域标记。这个值决定三件事：合规开关默认值、存储域、以及 /health 的自检输出。
REGION=intl

# ⚠️ 独立数据库，不是中国区那个 pet 库。见脚本头部「隔离做到了哪一层」。
DATABASE_URL=postgresql+psycopg://pet:${DB_PASS}@127.0.0.1:5432/${DB_NAME}

# ---- 邮件通道（SMTP）----
# 海外区用邮件发验证码（腾讯企业邮箱，零第三方依赖）。
#
# ⚠️ SMTP_PASSWORD 填**授权码**，不是登录密码。企业邮箱后台
# 「设置 → 客户端设置」单独生成，形如 16 位随机串。用登录密码会 535 认证失败。
SMTP_HOST=smtp.exmail.qq.com
SMTP_PORT=465
# 465 = 隐式 TLS。改 587 必须同时改 false，配错会在握手阶段就失败。
SMTP_SECURE=true
SMTP_USER=noreply@weiyuantool.com
SMTP_PASSWORD=
SMTP_FROM_NAME=My Pet
SMTP_FROM_EMAIL=noreply@weiyuantool.com

# ---- 应用内更新 ----
# 海外区与国内区分开版本号：两端用户装的包不同，versionCode 混用会导致
# 中国区用户被提示更新到「海外版」。
APP_VERSION=0.1.7
APP_BUILD=9
APP_APK_URL=
APP_NOTES=Overseas build
APP_MIN_BUILD=0
APP_IOS_STORE_URL=

# ---- 安全开关 ----
# true 时接口把验证码原样回显 —— 生产**必须** false。
# 靠它可以先不接邮件通道就把登录链路跑通，但**只限本地联调**。
DEV_ECHO_CODE=false

# 中国区的统一账号通道在海外区不提供。
UNIFIED_ACCOUNT_BASE_URL=
EOF
    chmod 600 "$APP_DIR/.env"
    echo "[+] 已生成 $APP_DIR/.env（600）"
fi

# ---- 4. systemd -------------------------------------------------------------
# ⚠️ `PrivateTmp=true` 与中国区一致：gunicorn 与 gunicorn 共享 /tmp 会互相
# 看见对方正在写的文件（上传的文档、导出的图片），两个区同时跑时这会变成
# 跨区的数据可见性问题。各自一个私有 /tmp 就隔开了。
cat > "$UNIT" <<EOF
[Unit]
Description=Pet API (宠物 App 服务端，海外区)
After=network.target postgresql.service

[Service]
Type=notify
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStartPre=$VENV/bin/python -c "from app.db import init_db; init_db()"
ExecStart=$VENV/bin/gunicorn app.main:app \\
    --worker-class uvicorn.workers.UvicornWorker \\
    --workers 2 \\
    --bind 127.0.0.1:$PORT \\
    --access-logfile - \\
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
systemctl enable --quiet pet-api-intl.service
echo "[+] 已设置开机自启"

echo
echo "[OK] 海外区环境就绪。接下来："
echo "  1) 填 SMTP 授权码：nano $APP_DIR/.env"
echo "  2) 起服务：       systemctl start pet-api-intl"
echo "  3) 自检：         curl -s localhost:$PORT/health"
echo "     期望看到 region=intl、icp_display_required=false"
echo
echo "     cross_border_allowed 会是 false —— **这是对的，别当 bug 修**。"
echo "     那条是架构红线（数据不出境），对每个区域恒为 false；"
echo "     海外区的隔离靠的是独立数据库 pet_intl，不是这个标志位。"
