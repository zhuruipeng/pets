#!/usr/bin/env bash
#
# 签发 api-intl 的证书并补上 443 配置 —— **等 DNS 生效后跑这个**。
#
# ## 为什么单独一个脚本
#
# 签证书的前置条件是「域名已解析到本机」，而 DNS 生效要时间
# （境内通常几分钟，境外可能更久）。所以流程天然分两段：
#
#   段一（DNS 未生效）：08-nginx-intl.sh 只写 80 段 —— 已完成
#   段二（DNS 生效后）：本脚本签证书 + 重跑 08 补 443
#
# 分开的好处是：在 DNS 没生效时反复跑本脚本是**安全的**，
# 它会自己检查并直接退出，而不是留下一堆半成品配置。
#
# ## 为什么用 webroot 而不是 standalone
#
# standalone 会让 certbot 临时停掉 nginx 80 端口 —— 而这台机器上
# 跑着官网与 ERP（生产），停 80 就等于短暂对外失联。
# webroot 只是往 /var/www/acme 写一个 challenge 文件，**不碰现有服务**。
# 中国区的证书也是 webroot 签的（见 /etc/letsencrypt/renewal/*.conf）。
set -euo pipefail

DOMAIN=api-intl.weiyuantool.com
CERTBOT=/opt/certbot/bin/certbot
ACME_DIR=/var/www/acme
CONF=/etc/nginx/conf.d/pet-api-intl.conf

echo "=== 为 ${DOMAIN} 签发证书 ==="
echo

# ---- 0. certbot 在哪 -------------------------------------------------------
if [ ! -x "$CERTBOT" ]; then
    echo "[X] 找不到 $CERTBOT"
    echo "    这台机器的 certbot 装在 /opt/certbot（venv 形式）。"
    echo "    先确认：ls /opt/certbot/bin/"
    exit 1
fi
echo "[i] certbot: $CERTBOT"

# ---- 1. DNS 前置检查 -------------------------------------------------------
# ⚠️ 这一步不是形式检查：**Let's Encrypt 签发时会从公网回连这个域名**，
# 解析不到就必然失败，而报错是 "Could not resolve host"，
# 很容易被误解成 certbot 或网络的问题。
#
# 用公共 DNS 查而不是 getent：服务器的本地解析可能命中缓存，
# 看起来正常但公网还没生效。
RESOLVED=$(dig +short A "$DOMAIN" @223.5.5.5 2>/dev/null | head -1 || true)
if [ -z "$RESOLVED" ]; then
    echo "[X] $DOMAIN 还解析不到 —— DNS 未生效，现在签必然失败。"
    echo
    echo "    请确认已添加 A 记录："
    echo "      $DOMAIN  →  124.223.174.129"
    echo
    echo "    查一下：dig +short A $DOMAIN @223.5.5.5"
    exit 1
fi
echo "[i] DNS 已解析：$DOMAIN → $RESOLVED"

if [ "$RESOLVED" != "124.223.174.129" ]; then
    echo "[!] 注意：解析到的不是本机 IP（124.223.174.129）"
    echo "    若这是 CDN 或别的机器，请先确认它会把流量转到本机 8201 端口，"
    echo "    否则 challenge 会失败。"
    read -r -p "    仍要继续吗？[y/N] " a
    [ "$a" = "y" ] || exit 1
fi

# ---- 2. 80 段必须在位 -------------------------------------------------------
# certbot 要往 /var/www/acme/.well-known/acme-challenge/ 写文件，
# nginx 得能把那个路径暴露出去，否则校验请求拿不到文件。
if ! grep -q "acme-challenge" "$CONF" 2>/dev/null; then
    echo "[X] $CONF 里没有 acme-challenge 的 location"
    echo "    先跑一次 bash deploy/08-nginx-intl.sh（它会写 80 段）"
    exit 1
fi
echo "[i] acme-challenge 路径已就位"
systemctl reload nginx
sleep 1

# ---- 3. 签发 ---------------------------------------------------------------
# --non-interactive 避免它想问你问题而卡住（没有 TTY 时会直接失败）。
# --keep-until-expiring 已有证书时不重签：续签有时间窗口，
#   每次都重签会撞上 Let's Encrypt 的速率限制（每周 5 次）。
echo
echo "→ 请求签发（可能需要 10-30 秒）..."
if "$CERTBOT" certonly \
    --webroot -w "$ACME_DIR" \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --keep-until-expiring \
    --no-eff-email; then
    echo
    echo "[+] 证书已就位"
else
    echo
    echo "[X] 签发失败。常见原因："
    echo "  · DNS 没真正生效（Let's Encrypt 从公网回连，用 dig 确认）"
    echo "  · 防火墙没放行 80 —— 检查：ss -ltnp | grep :80"
    echo "  · 已触发速率限制（每周 5 次）—— 等一周，或用 --dry-run 先测"
    exit 1
fi

# ---- 4. 补 443 段 ----------------------------------------------------------
echo
echo "=== 重跑 08-nginx-intl.sh 补 443 段 ==="
bash /opt/pet-api-intl/deploy/08-nginx-intl.sh

# ---- 5. 验证 ---------------------------------------------------------------
echo
echo "=== 验证 ==="
echo -n "  http  →  "
curl -s -o /dev/null -w "%{http_code}\n" "http://$DOMAIN/health" --max-time 15
echo -n "  https →  "
curl -s "https://$DOMAIN/health" --max-time 15
echo
echo "  证书："
"$CERTBOT" certificates 2>/dev/null | grep -A2 "$DOMAIN" | head -4
