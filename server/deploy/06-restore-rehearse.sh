#!/usr/bin/env bash
#
# 宠物 API —— 备份恢复演练
#
# 为什么值得单独写一个脚本：备份文件「存在」和「能恢复」是两件事。
# 磁盘写满、pg_dump 中途被杀、PostgreSQL 大版本升级导致归档格式不兼容 ——
# 这几种情况都会留下一个大小看着正常、却恢复不出来的文件。而它们只在真正
# 需要恢复的那一天暴露，那天你没有第二次机会。
#
# 本脚本把最近一次备份恢复到一个**一次性临时库**，比对对方与生产的表结构、
# 索引数量、每张表的行数，然后删掉临时库。全程不碰生产库、
# 不影响正在运行的 pet-api 服务。
#
# 什么时候跑：每次升级 PostgreSQL 大版本之后、换服务器之后，
# 以及每隔几个月随手跑一次。
set -euo pipefail

PASS_FILE=/root/.pet-db-pass
BACKUP_DIR=/root/pet_backups
PROD_DB=pet
REHEARSE_DB=pet_restore_rehearsal
DB_USER=pet

[ -f "$PASS_FILE" ] || { echo "[X] 缺 $PASS_FILE"; exit 1; }
DB_PASS="$(cat "$PASS_FILE")"
export PGPASSWORD="$DB_PASS"

DUMP="$(ls -1t "$BACKUP_DIR"/${PROD_DB}-*.dump 2>/dev/null | head -1 || true)"
[ -n "$DUMP" ] || { echo "[X] $BACKUP_DIR 下没有备份文件"; exit 1; }

echo "[i] 待验证的备份：$DUMP（$(du -h "$DUMP" | cut -f1)）"

# 只允许操作名字带这个后缀的库，防手滑删到生产库。
case "$REHEARSE_DB" in
    pet_restore_rehearsal*) ;;
    *) echo "[X] 临时库名不合规：$REHEARSE_DB"; exit 1 ;;
esac

cleanup() {
    su - postgres -c "psql -q -c \"DROP DATABASE IF EXISTS ${REHEARSE_DB};\"" 2>/dev/null || true
}
trap cleanup EXIT

echo "[i] 建临时库 $REHEARSE_DB"
su - postgres -c "psql -q -c \"DROP DATABASE IF EXISTS ${REHEARSE_DB};\"" 2>/dev/null || true
su - postgres -c "psql -q -c \"CREATE DATABASE ${REHEARSE_DB} OWNER ${DB_USER} ENCODING 'UTF8' TEMPLATE template0;\""
su - postgres -c "psql -q -d ${REHEARSE_DB} -c \"ALTER SCHEMA public OWNER TO ${DB_USER};\""

echo "[i] 恢复中…"
# --exit-on-error：演练的意义就是暴露问题，不要让 pg_restore 跳过错误继续跑
# 然后报一个「成功」。
if pg_restore -h 127.0.0.1 -U "$DB_USER" -d "$REHEARSE_DB" --no-owner --exit-on-error "$DUMP"; then
    echo "[+] 恢复命令成功返回"
else
    echo "[X] 恢复失败 —— 这个备份不可用，需要排查" >&2
    exit 1
fi

echo
echo "=== 比对 ==="
q() { psql -h 127.0.0.1 -U "$DB_USER" -d "$1" -tAc "$2"; }

printf "  %-22s %-12s %-12s\n" "项目" "生产库" "恢复库"
for item in "表:SELECT count(*) FROM pg_tables WHERE schemaname='public'" \
            "索引:SELECT count(*) FROM pg_indexes WHERE schemaname='public'" \
            "约束:SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace"; do
    label="${item%%:*}"
    sql="${item#*:}"
    printf "  %-20s %-12s %-12s\n" "$label" "$(q "$PROD_DB" "$sql")" "$(q "$REHEARSE_DB" "$sql")"
done

echo
echo "  表清单差异（无输出 = 完全一致）："
diff <(q "$PROD_DB" "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1") \
     <(q "$REHEARSE_DB" "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1") \
     && echo "      ✓ 一致"

echo
echo "  各表行数（生产 / 恢复）："
psql -h 127.0.0.1 -U "$DB_USER" -d "$PROD_DB" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1" | while read -r t; do
    [ -z "$t" ] && continue
    printf "      %-24s %6s / %6s\n" "$t" \
        "$(q "$PROD_DB" "SELECT count(*) FROM \"$t\"")" \
        "$(q "$REHEARSE_DB" "SELECT count(*) FROM \"$t\"")"
done

echo
echo "[OK] 演练结束，临时库将在退出时删除。"
