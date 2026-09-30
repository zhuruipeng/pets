#!/usr/bin/env bash
#
# 宠物 API —— PostgreSQL 备份（由 pet-backup.service 调用，也可手工执行）
#
# 设计取向：**宁要一个验证过的简单备份，不要一个没人验证过的精巧方案。**
# 所以这里只做三件事，但每一件都是硬要求：
#
#   1. 用 -Fc（自定义格式）而不是纯 SQL：体积小、pg_restore 能选表恢复、
#      还自带校验和 —— 纯文本 SQL 被截断时往往看不出问题。
#   2. dump 完立刻用 pg_restore -l 列出归档目录。**一个从没被验证过的
#      备份等于没有备份**：磁盘写满、连接中断都会留下一个大小正常、
#      但恢复不出来的文件，而这类失败在真正需要它的那天才会暴露。
#      这一步失败就返回非零，让 systemd 记成失败。
#   3. 把表数量写进日志。"备份成功但内容是空的" 是最坏的一类静默故障：
#      文件在、校验过、恢复出来一个空库。
set -euo pipefail

BACKUP_DIR=/root/pet_backups
PASS_FILE=/root/.pet-db-pass
DB=pet
DB_USER=pet
KEEP_DAYS=14

[ -f "$PASS_FILE" ] || { echo "[X] 缺 $PASS_FILE"; exit 1; }
DB_PASS="$(cat "$PASS_FILE")"

mkdir -p "$BACKUP_DIR"
# 700：备份里有全部用户数据（手机号、宠物档案、照片记录），不该对同机其他账号可读。
chmod 700 "$BACKUP_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/${DB}-${STAMP}.dump"

echo "[i] 开始备份 $(date '+%F %T')"
PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" -d "$DB" \
    --format=custom --compress=6 --file="$OUT"

# ---- 校验（缺了这一步，本脚本就只是个「看起来在工作」的脚本）----------------
if ! pg_restore --list "$OUT" > /dev/null 2>&1; then
    echo "[X] 归档不可读，可能已损坏：$OUT" >&2
    exit 1
fi

# 注意 grep -c 在没有匹配时返回 1，会触发 set -e，所以兜一个 || true。
TABLE_DATA="$(pg_restore --list "$OUT" | grep -c 'TABLE DATA' || true)"
SIZE="$(du -h "$OUT" | cut -f1)"
echo "[+] 备份完成：$OUT（$SIZE，$TABLE_DATA 段表数据）"

if [ "$TABLE_DATA" -eq 0 ]; then
    echo "[X] 归档里没有任何表数据 —— 要么库是空的，要么 dump 有问题" >&2
    exit 1
fi

# ---- 保留策略 ---------------------------------------------------------------
# 14 天足够覆盖「改坏了过几天才发现」这类事故；再长的历史不如加异地副本。
DELETED="$(find "$BACKUP_DIR" -maxdepth 1 -name "${DB}-*.dump" -type f -mtime +${KEEP_DAYS} -print -delete | wc -l)"
[ "$DELETED" -gt 0 ] && echo "[i] 已清理 $DELETED 个超过 ${KEEP_DAYS} 天的旧备份"

echo "[i] 现有备份："
ls -1t "$BACKUP_DIR"/${DB}-*.dump 2>/dev/null | head -5 | while read -r f; do
    printf "      %s  %s\n" "$(du -h "$f" | cut -f1)" "$f"
done
echo "[i] 磁盘余量：$(df -h / | awk 'NR==2{print $4" 可用 / "$2" 总"}')"
