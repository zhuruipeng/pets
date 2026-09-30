#!/usr/bin/env bash
#
# 宠物服务端 —— nginx 反向代理（幂等，可在签发证书前后各跑一次）
#
# ⚠️ 这台机器上 nginx 同时承载三条业务线：
#      caiwu-erp.conf     官网 weiyuantool.com + ERP（生产，最要紧）
#      ledgerly-api.conf  Ledgerly  api.weiyuantool.com
#      pet-api.conf       本文件新增，api.pet.weiyuantool.com
#   三者各自一个文件、互不引用。本脚本只写第三个。
#
# ⚠️ 最要命的一点：**证书还不存在时，绝不能把 443 段写进配置**。
#   nginx 在启动/reload 时会去读 ssl_certificate 指向的文件，文件不在就直接
#   启动失败。此刻 nginx 正在给生产 ERP 挡流量，一旦它 reload 失败、
#   再赶上服务器重启，官网和 ERP 会一起挂掉 —— 为了上一个还没上线的 App
#   把在跑的生意打掉，是不可接受的代价。
#   所以：证书在 → 写 80+443；证书不在 → 只写 80（够 ACME challenge 用），
#   等 certbot 签完再跑一遍本脚本补上 443。
set -euo pipefail

DOMAIN=api.pet.weiyuantool.com
CONF=/etc/nginx/conf.d/pet-api.conf
APK_DIR=/var/www/pet-apk
ACME_DIR=/var/www/acme

# ---- 1. 静态目录 ------------------------------------------------------------
mkdir -p "$APK_DIR" "$ACME_DIR"
chmod 755 "$APK_DIR" "$ACME_DIR"
echo "[+] 静态目录就绪：$APK_DIR（APK 直链）、$ACME_DIR（ACME challenge）"

# ---- 2. 证书是否就位 --------------------------------------------------------
HAS_CERT=no
if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] \
   && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
    HAS_CERT=yes
fi
echo "[i] 证书状态：$HAS_CERT"

# ---- 3. 生成配置 ------------------------------------------------------------
# 先备份现有配置（如果有），nginx -t 失败时好还原 —— 这个文件一旦写坏，
# 受影响的是整台机器上所有站点的下一次 reload。
BACKUP=""
if [ -f "$CONF" ]; then
    BACKUP="${CONF}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONF" "$BACKUP"
    echo "[i] 已备份原配置 -> $BACKUP"
fi

cat > "$CONF" <<'EOF'
# 宠物 App API —— added 2026-10-01.
#
# This file owns exactly one server_name. The ERP site in caiwu-erp.conf and
# Ledgerly in ledgerly-api.conf are untouched by it, and none of the three
# files reference each other.
#
# The certificate comes from Let's Encrypt via certbot, issued through the ACME
# challenge served out of /var/www/acme and renewed by certbot-renew.timer.
# The challenge location has to stay reachable over plain HTTP or renewal will
# fail silently in three months' time.

server {
    listen 80;
    server_name api.pet.weiyuantool.com;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type "text/plain";
    }

    # APK 直链（应用内更新下载用）。
    # 单独走 /download/ 前缀，**不能**挂在 /app/ 下 —— /app/version.json
    # 是 FastAPI 的接口，被静态规则抢走的话应用内更新会静默失效（客户端
    # 拿到一段 HTML 或 404，然后当作「检查更新失败」悄悄放弃）。
    location /download/ {
        alias /var/www/pet-apk/;
        autoindex off;
        default_type application/vnd.android.package-archive;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF

if [ "$HAS_CERT" = "yes" ]; then
cat >> "$CONF" <<'EOF'

server {
    listen 443 ssl;
    http2 on;
    server_name api.pet.weiyuantool.com;

    ssl_certificate     /etc/letsencrypt/live/api.pet.weiyuantool.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.pet.weiyuantool.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 照片附件走 multipart 上传；应用层自己有更严的限制，这里是兜底。
    client_max_body_size 12m;

    # 显式给 /app/ 以外的接口让路：这条只拦 /download/。
    location /download/ {
        alias /var/www/pet-apk/;
        autoindex off;
        default_type application/vnd.android.package-archive;
    }

    # API 绑在 127.0.0.1:8200，nginx 是唯一入口。路径不做任何改写：
    # 应用自己拥有 /api/v1、/health、/app/version.json、/legal 这些绝对路径。
    location / {
        proxy_pass http://127.0.0.1:8200;
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
    echo "[+] 已写入 80 + 443 两段（证书已就位）"
else
    echo "[!] 证书尚未签发，只写入 80 段 —— 443 段留到 certbot 之后再补"
    echo "    这是有意为之：证书文件不存在时 nginx 会启动失败，"
    echo "    而那会连累这台机器上的官网与 ERP。"
fi

# ---- 4. 语法校验（失败就还原，绝不带着坏配置 reload）------------------------
if nginx -t 2>&1 | sed 's/^/    /'; then
    systemctl reload nginx
    echo "[+] nginx 已 reload"
    echo
    echo "[i] 当前 server_name 一览（确认没动到别人）："
    grep -rhE "^\s*server_name" /etc/nginx/conf.d/*.conf | sort -u | sed 's/^/      /'
else
    echo "[X] nginx -t 失败，回滚"
    if [ -n "$BACKUP" ]; then
        cp -a "$BACKUP" "$CONF"
        echo "    已还原 $CONF"
    else
        rm -f "$CONF"
        echo "    已删除新配置（本次是首次创建）"
    fi
    exit 1
fi
