#!/usr/bin/env bash
#
# 验证 ExecStartPre 建表的必要性 —— 正反对比，跑在**一次性临时库**上。
#
# 背景：首次部署时 systemd 报 `activating (auto-restart)`，日志里
#   psycopg.errors.UniqueViolation: duplicate key value violates unique
#   constraint "pg_type_typname_nsp_index"  DETAIL: Key (typname, typnamespace)=(users, 2200)
# 即两个 worker 并发对空库执行 create_all，一方建表、另一方也建 → 撞唯一键。
#
# 本脚本用同一份代码、同一个数据库用户，只改一个变量：
#   A 组：先跑一次 init_db()（= systemd ExecStartPre 做的事）再起双 worker
#   B 组：不跑，直接起双 worker
# 期望 A 成功、B 失败。若 B 也成功，说明我诊断错了，得回去重查。
#
# 安全：库名必须以 pet_verify_ 开头才允许 DROP，防止手滑删到生产库。
set -uo pipefail

APP_DIR=/opt/pet-api
PY="$APP_DIR/venv/bin/python"
GUN="$APP_DIR/venv/bin/gunicorn"
DB_PASS="$(cat /root/.pet-db-pass)"

safe_mkdb() {
    case "$1" in
        pet_verify_*) ;;
        *) echo "!! 拒绝操作非临时库: $1"; return 1 ;;
    esac
    su - postgres -c "psql -q -c \"DROP DATABASE IF EXISTS $1;\"" 2>/dev/null
    su - postgres -c "psql -q -c \"CREATE DATABASE $1 OWNER pet ENCODING 'UTF8' TEMPLATE template0;\""
    su - postgres -c "psql -q -d $1 -c \"GRANT ALL ON SCHEMA public TO pet; ALTER SCHEMA public OWNER TO pet;\""
}

safe_rmdb() {
    case "$1" in
        pet_verify_*) su - postgres -c "psql -q -c \"DROP DATABASE IF EXISTS $1;\"" ;;
        *) echo "!! 拒绝删除非临时库: $1" ;;
    esac
}

# $1=库名 $2=是否先建表(yes/no) $3=端口
run_case() {
    local db="$1" pre="$2" port="$3"
    local env_file="/tmp/${db}.env"
    local log_file="/tmp/${db}.log"

    cat > "$env_file" <<EOF
REGION=cn
DATABASE_URL=postgresql+psycopg://pet:${DB_PASS}@127.0.0.1:5432/${db}
DEV_ECHO_CODE=false
EOF

    if [ "$pre" = "yes" ]; then
        ( set -a; . "$env_file"; set +a; cd "$APP_DIR"; "$PY" -c "from app.db import init_db; init_db()" ) \
            && echo "    [ExecStartPre] init_db() 完成 (exit 0)" \
            || { echo "    [ExecStartPre] init_db() 失败"; return 1; }
    else
        echo "    [ExecStartPre] 跳过 —— 模拟「没有这一步」的情形"
    fi

    ( set -a; . "$env_file"; set +a; cd "$APP_DIR"; \
      "$GUN" app.main:app --worker-class uvicorn.workers.UvicornWorker \
        --workers 2 --bind "127.0.0.1:${port}" ) > "$log_file" 2>&1 &
    local pid=$!
    sleep 8

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/health")"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    # 用 "Application startup complete" 数真正活下来的 worker；
    # "Booting worker with pid" 只是尝试启动的日志行，撞车时照样会打印。
    local viol booted
    viol="$(grep -c 'UniqueViolation' "$log_file")"
    booted="$(grep -c 'Application startup complete' "$log_file")"

    echo "    /health = HTTP ${code}"
    echo "    真正启动完成的 worker 数 = ${booted} / 2"
    echo "    唯一键冲突次数 = ${viol}"
    echo "    表数量 = $(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U pet -d "$db" -tAc \
        "SELECT count(*) FROM pg_tables WHERE schemaname='public';")"
    rm -f "$env_file"
}

echo "=============================================================="
echo "A 组：先 ExecStartPre 建表，再启动双 worker（= 现在的生产配置）"
echo "=============================================================="
safe_mkdb pet_verify_with
run_case pet_verify_with yes 8201

echo
echo "=============================================================="
echo "B 组：不建表，直接启动双 worker（= 修复前的行为）"
echo "=============================================================="
safe_mkdb pet_verify_without
run_case pet_verify_without no 8202

echo
echo "=============================================================="
echo "结论"
echo "=============================================================="
if grep -q 'UniqueViolation' /tmp/pet_verify_with.log; then
    echo "  A 组也撞了 —— 修复无效，需重查"
elif grep -q 'UniqueViolation' /tmp/pet_verify_without.log; then
    echo "  A 组干净、B 组撞车 —— 竞态确诊，ExecStartPre 修复有效"
else
    echo "  B 组居然没撞 —— 竞态这次没复现（并发窗口很窄），不能据此认为不需要 ExecStartPre"
fi

# ---- 清理（放在结论之后，别把结论要读的日志先删了）------------------------
safe_rmdb pet_verify_with
safe_rmdb pet_verify_without
echo
echo "临时库已删除。当前 pet 相关数据库："
su - postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datname LIKE 'pet%' ORDER BY 1;\""
echo "（日志留在 /tmp/pet_verify_with.log 与 /tmp/pet_verify_without.log，可复核）"
