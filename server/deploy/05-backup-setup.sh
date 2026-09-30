#!/usr/bin/env bash
#
# 宠物 API —— 安装数据库备份的 systemd 定时任务（幂等）
#
# 真正的备份逻辑在同目录的 04-backup-db.sh，本脚本只负责让它按点跑起来。
set -euo pipefail

UNIT=/etc/systemd/system/pet-backup.service
TIMER=/etc/systemd/system/pet-backup.timer

[ -f /opt/pet-api/deploy/04-backup-db.sh ] || {
    echo "[X] 缺 /opt/pet-api/deploy/04-backup-db.sh"; exit 1
}
chmod +x /opt/pet-api/deploy/04-backup-db.sh

cat > "$UNIT" <<'EOF'
[Unit]
Description=宠物 API PostgreSQL 备份（含归档可读性校验）
After=network-online.target postgresql.service
Requires=postgresql.service

[Service]
Type=oneshot
# 备份脚本自己从 /root/.pet-db-pass 读密码，不需要 EnvironmentFile。
ExecStart=/opt/pet-api/deploy/04-backup-db.sh
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=每天备份宠物 API 数据库

[Timer]
# 03:40 —— 刻意错开这台机器上已有的定时任务：
#   ERP PostgreSQL 备份 00:20 / 12:20，Let's Encrypt 续期 03:17 / 15:17，
#   ERP 异地备份另有自己的时点。挤在一起不仅抢磁盘 IO，还会让
#   「某个时段磁盘被写满」这类事故集中爆发、难以归因。
OnCalendar=*-*-* 03:40:00
# 加一点随机延迟，避免与其它机器在同一秒打同一个目标。
RandomizedDelaySec=600
Persistent=true
# 机器关机错过了点，开机后补跑一次（备份不能因为关机就整天空缺）。
Unit=pet-backup.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --quiet pet-backup.timer
systemctl start pet-backup.timer

echo "[+] 已安装并启用 pet-backup.timer"
echo
echo "[i] 定时器状态："
systemctl list-timers pet-backup.timer --no-pager | head -3
echo
echo "[i] 备份配置："
systemctl cat pet-backup.timer --no-pager | grep -E "OnCalendar|Randomized|Persistent"
