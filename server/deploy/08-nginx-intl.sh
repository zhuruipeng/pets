#!/usr/bin/env bash
#
# 宠物服务端 —— 海外区 nginx 反向代理（api-intl.weiyuantool.com）
#
# ## 为什么要独立域名，而不是在现有 api.pet.weiyuantool.com 上加路径前缀
#
# 技术上 `/intl/api/v1` 也能分流，但有三个实际代价：
# 1. **客户端要改路径前缀**，而现有代码把 `/api/v1` 写死在多处
#    （sync_api / unified_api / auth），改前缀要动一批常量；
# 2. **限流与日志混在一起** —— 两区共用一个 access log，出问题时
#    分不清是哪区的请求，而「数据不出境」这件事出了错必须能追溯到具体区域；
# 3. **证书**。独立域名 = 独立证书 = App Store 后台能填一个干净的海外地址。
#
# 独立域名的代价只是多一条 DNS 记录，值得。
#
# ## 这台机器上还有另外两条业务线
#
#   caiwu-erp.conf     官网 weiyuantool.com + ERP（**生产，最要紧**）
#   ledgerly-api.conf  Ledgerly  api.weiyuantool.com
#   pet-api.conf       中国区  api.pet.weiyuantool.com
#   本文件              海外区  api-intl.weiyuantool.com
#
# 各自一个文件、互不引用，本脚本只写自己那一个。
#
# ## ⚠️ 最要命的一点（照抄 03-nginx.sh 的设计，别改）
#
# **证书不存在时绝不能把 443 段写进配置。** nginx reload 时会去读
# ssl_certificate 指向的文件，文件不在就直接启动失败 —— 而此刻
# nginx 正在给生产官网与 ERP 挡流量。为了一个还没上线的 App 把在跑的
# 生意打掉，不可接受。所以：证书在 → 写 80+443；不在 → 只写 80。
set -euo pipefail

DOMAIN=api-intl.weiyuantool.com
CONF=/etc/nginx/conf.d/pet-api-intl.conf
UPSTREAM=127.0.0.1:8201
ACME_DIR=/var/www/acme

echo "=== 海外区 nginx 配置 ==="
echo "  域名  $DOMAIN"
echo "  后端  $UPSTREAM"
echo

# ---- 1. ACME 目录 -----------------------------------------------------------
# 中国区的 03-nginx.sh 已经建过，这里 mkdir -p 是幂等的，
# 不会影响那边（同一个路径、同一个用途）。
mkdir -p "$ACME_DIR"
chmod 755 "$ACME_DIR"

# ---- 2. 证书是否就位 --------------------------------------------------------
HAS_CERT=no
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] \
   && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
    HAS_CERT=yes
fi
echo "[i] 证书状态：$HAS_CERT"

# ---- 3. 备份现有配置 --------------------------------------------------------
BACKUP=""
if [ -f "$CONF" ]; then
    BACKUP="${CONF}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONF" "$BACKUP"
    echo "[i] 已备份原配置 -> $BACKUP"
fi

# ---- 4. 80 段（总是写，ACME challenge 需要）---------------------------------
cat > "$CONF" <<'EOF'
# 宠物 App API 海外区 —— added 2026-10-04.
#
# ⚠️ 本文件只服务 api-intl.weiyuantool.com（海外区，REGION=intl）。
# 中国区在 api.pet.weiyuantool.com，由 pet-api.conf 管，两者互不引用。
#
# 这里的请求**全部来自海外用户**，落在 REGION=intl 的实例上，
# 那个实例连的是独立的 pet_intl 数据库 —— 隔离由数据库保证，
# 不依赖应用层「记得传对 REGION」。

server {
    listen 80;
    server_name api-intl.weiyuantool.com;

    # 证书签发期间 certbot webroot 会打这里。
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type "text/plain";
    }

    location / {
        # 证书还没签出来时，这个反代是空转的（后端可能没起）。
        # 没关系 —— 80 段只服务 challenge，HTTPS 才是真正入口。
        proxy_pass http://127.0.0.1:8201;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
EOF
echo "[+] 已写入 80 段"

# ---- 5. 443 段（仅在证书就位时）---------------------------------------------
if [ "$HAS_CERT" = "yes" ]; then
cat >> "$CONF" <<EOF

server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 12m;

    # 路径**不做任何改写**：应用自己拥有 /api/v1、/health、/app/version.json、
    # /legal 这些绝对路径。这里加前缀的话，客户端与文档里的 URL 都会对不上。
    location / {
        proxy_pass http://${UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
EOF
    echo "[+] 已写入 443 段（证书已就位）"
else
    echo "[!] 证书尚未签发，只写入 80 段 —— 443 段留到 certbot 之后再补"
    echo "    这是有意为之：证书文件不存在时 nginx 会启动失败，"
    echo "    而那会连累这台机器上的官网与 ERP。"
fi

# ---- 6. 语法校验（失败就还原，绝不带着坏配置 reload）------------------------
if nginx -t 2>&1 | sed 's/^/    /'; then
    systemctl reload nginx
    echo "[+] nginx 已 reload"
    echo
    if [ "$HAS_CERT" = "no" ]; then
        echo "下一步 —— 先把 DNS 指过来，再签证书："
        echo "  1) 加 A 记录 api-intl -> 本机公网 IP"
        echo "     （deploy/dns-add-record.py 可参考，但请先手动确认，别直接跑）"
        echo "  2) 签证书："
        echo "     certbot certonly --webroot -w $ACME_DIR -d $DOMAIN"
        echo "  3) 重跑本脚本补 443 段：bash deploy/08-nginx-intl.sh"
    fi
else
    if [ -n "$BACKUP" ]; then
        cp -a "$BACKUP" "$CONF"
        echo "[X] 校验失败，已还原到 $BACKUP"
    else
        rm -f "$CONF"
        echo "[X] 校验失败，已删除本文件（原不存在）"
    fi
    echo "[X] nginx **未 reload**，现有站点不受影响"
    exit 1
fi

echo
echo "[i] 当前 server_name 一览（确认没动到别人）："
grep -rhE "^\s*server_name" /etc/nginx/conf.d/*.conf | sort -u | sed 's/^/      /'
