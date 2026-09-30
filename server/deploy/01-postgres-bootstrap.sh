#!/usr/bin/env bash
#
# 宠物服务端 —— PostgreSQL 初始化（幂等，可反复执行）
#
# 这台服务器上还跑着生产 ERP（erp_company_1..9、erp_platform）与 Ledgerly
# （ledgerly、ledgerly_test）。本脚本**只碰 pet 这一个库和 pet 这一个角色**，
# 不执行任何 DROP，不修改任何已有对象的权限。
#
# 密码只生成一次，落在 /root/.pet-db-pass（600）。重跑不会改密码 ——
# 改了就会和已经写好的 .env 对不上，服务会在重启后连不上库。
set -euo pipefail

DB_NAME=pet
DB_USER=pet
PASS_FILE=/root/.pet-db-pass

# ---- 1. 密码 ----------------------------------------------------------------
if [ ! -f "$PASS_FILE" ]; then
    openssl rand -hex 24 > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    echo "[+] 已生成数据库密码 -> $PASS_FILE"
else
    echo "[=] 复用已有密码 $PASS_FILE（不重新生成，避免与 .env 失联）"
fi
DB_PASS="$(cat "$PASS_FILE")"

# ---- 2. 角色 ----------------------------------------------------------------
role_exists="$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"")"
if [ "$role_exists" = "1" ]; then
    su - postgres -c "psql -q -c \"ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';\""
    echo "[=] 角色 ${DB_USER} 已存在，已同步密码"
else
    su - postgres -c "psql -q -c \"CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';\""
    echo "[+] 已创建角色 ${DB_USER}"
fi

# ---- 3. 数据库 --------------------------------------------------------------
db_exists="$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"")"
if [ "$db_exists" = "1" ]; then
    echo "[=] 数据库 ${DB_NAME} 已存在"
else
    # TEMPLATE template0 是为了不与现有库的 locale 设置耦合；
    # 显式 ENCODING UTF8 保证昵称、备注里的中文与 emoji 存得下。
    su - postgres -c "psql -q -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0;\""
    echo "[+] 已创建数据库 ${DB_NAME}"
fi

# ---- 4. schema 权限 ---------------------------------------------------------
# PostgreSQL 15 起 public schema 不再默认给普通用户 CREATE 权限，
# 而应用启动时是 create_all（要建表）。不放开这一步，服务会在
# 初始化阶段直接崩，报 "permission denied for schema public"。
su - postgres -c "psql -q -d ${DB_NAME} -c \"GRANT ALL ON SCHEMA public TO ${DB_USER};\""
su - postgres -c "psql -q -d ${DB_NAME} -c \"ALTER SCHEMA public OWNER TO ${DB_USER};\""
echo "[+] public schema 权限已放开给 ${DB_USER}"

# ---- 5. 自检 ----------------------------------------------------------------
echo -n "[i] 连接自检: "
PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -tAc \
    "SELECT 'user=' || current_user || ' db=' || current_database();"

echo -n "[i] 建表权限自检: "
PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -tAc \
    "CREATE TABLE _perm_probe(id int); DROP TABLE _perm_probe; SELECT '可以建表';" | tail -1

echo
echo "[OK] PostgreSQL 就绪。连接串（供 .env 使用）："
echo "     postgresql+psycopg://${DB_USER}:***@127.0.0.1:5432/${DB_NAME}"
