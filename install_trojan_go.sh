#!/bin/bash
# =============================================================
# Trojan-Go 一键安装脚本（含 Nginx 伪装）
# 支持：Let's Encrypt 免邮箱证书 / 自动续期 / systemd 自启
# 架构：Trojan-Go:443 → fallback → Nginx:127.0.0.1:80（伪装页）
# =============================================================

set -e

# -------- 颜色 --------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# -------- 工具函数 --------
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
confirm() { echo -e "${CYAN}[CONFIRM]${NC} $1"; }

# -------- Root 检查 --------
[[ $EUID -ne 0 ]] && error "请以 root 权限运行此脚本（sudo bash $0）"

# -------- 系统检查 --------
check_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        PKG_MGR="apt-get"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        PKG_MGR="yum"
    else
        error "不支持的操作系统，仅支持 Debian/Ubuntu/CentOS"
    fi
    info "检测到系统：$OS"
}

# -------- 安装依赖（含 Nginx） --------
install_deps() {
    info "安装基础依赖及 Nginx..."
    if [[ "$OS" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y curl wget unzip socat cron nginx
    else
        yum install -y curl wget unzip socat cronie nginx
        systemctl enable crond && systemctl start crond
    fi
    # 暂停 Nginx，让 acme.sh standalone 模式占用 80 端口申请证书
    systemctl stop nginx 2>/dev/null || true
    info "Nginx 已安装（暂停，证书申请后启动）"
}

# -------- 输入域名 --------
input_domain() {
    echo ""
    while true; do
        read -rp "请输入你的域名（例如 proxy.example.com）: " DOMAIN
        [[ -z "$DOMAIN" ]] && warn "域名不能为空，请重新输入" && continue

        echo ""
        read -rp "确认域名为：${CYAN}${DOMAIN}${NC}？(y/n): " yn
        case $yn in
            [Yy]*) break ;;
            *) warn "已取消，请重新输入域名" ;;
        esac
    done
    info "域名确认：$DOMAIN"
}

# -------- 输入端口 --------
input_port() {
    echo ""
    read -rp "请输入监听端口（默认 443，回车跳过）: " PORT
    PORT=${PORT:-443}
    if ss -tlnp | grep -q ":${PORT} "; then
        warn "端口 $PORT 已被占用"
        read -rp "强制继续？(y/n): " force
        [[ "$force" != "y" ]] && error "请释放端口后重试"
    fi
    info "监听端口：$PORT"
}

# -------- 输入密码 --------
input_password() {
    echo ""
    while true; do
        read -rsp "请输入 Trojan 密码（不回显）: " PASSWORD
        echo ""
        [[ -z "$PASSWORD" ]] && warn "密码不能为空，请重新输入" && continue

        read -rsp "请再次确认密码: " PASSWORD2
        echo ""

        if [[ "$PASSWORD" == "$PASSWORD2" ]]; then
            info "密码设置成功"
            break
        else
            warn "两次输入不一致，请重新输入"
        fi
    done
}

# -------- 申请 Let's Encrypt 证书（免邮箱） --------
install_cert() {
    info "安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s -- --no-profile
    source ~/.bashrc 2>/dev/null || true
    ACME="$HOME/.acme.sh/acme.sh"

    info "切换到 Let's Encrypt（免邮箱）..."
    "$ACME" --set-default-ca --server letsencrypt

    # 确认 80 端口已释放（Nginx 已停止）
    if ss -tlnp | grep -q ':80 '; then
        error "80 端口仍被占用，请手动检查后重试（lsof -i:80）"
    fi

    info "申请证书：$DOMAIN（standalone 模式）..."
    "$ACME" --issue -d "$DOMAIN" --standalone --key-length ec-256 \
        || error "证书申请失败，请确认域名 DNS 已正确解析到本机 IP"

    CERT_DIR="/etc/trojan-go/certs"
    mkdir -p "$CERT_DIR"

    # 证书续期后：重载 Nginx（复用证书），再重启 Trojan-Go
    "$ACME" --install-cert -d "$DOMAIN" --ecc \
        --cert-file      "$CERT_DIR/cert.crt" \
        --key-file       "$CERT_DIR/private.key" \
        --fullchain-file "$CERT_DIR/fullchain.crt" \
        --reloadcmd      "systemctl reload nginx && systemctl restart trojan-go"

    chmod 600 "$CERT_DIR/private.key"
    info "证书已安装到 $CERT_DIR"
}

# -------- 配置 Nginx 伪装（仅监听 127.0.0.1:80） --------
setup_nginx() {
    info "配置 Nginx 伪装站点..."

    NGINX_CONF_DIR="/etc/nginx"
    WEB_ROOT="/var/www/trojan-camouflage"
    mkdir -p "$WEB_ROOT"

    # 写入伪装首页（空白默认页，与官方 Nginx 默认页完全一致）
    cat > "$WEB_ROOT/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body {
        width: 35em;
        margin: 0 auto;
        font-family: Tahoma, Verdana, Arial, sans-serif;
    }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
HTMLEOF

    # 写入 Nginx 站点配置
    # 关键：只绑定 127.0.0.1:80，外部无法直接访问
    cat > "$NGINX_CONF_DIR/conf.d/trojan-camouflage.conf" << EOF
server {
    listen 127.0.0.1:80;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index index.html;

    # 隐藏 Nginx 版本号
    server_tokens off;

    # 基础安全响应头
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # 关闭访问日志，避免伪装流量写盘
    access_log off;
    error_log  /dev/null;
}
EOF

    # 禁用默认 Nginx 站点（避免端口冲突）
    if [[ -f "$NGINX_CONF_DIR/sites-enabled/default" ]]; then
        rm -f "$NGINX_CONF_DIR/sites-enabled/default"
        info "已禁用 Nginx default 站点"
    fi

    # 测试 Nginx 配置
    nginx -t || error "Nginx 配置测试失败，请检查 $NGINX_CONF_DIR/conf.d/trojan-camouflage.conf"

    # 启动 Nginx 并设为开机自启
    systemctl enable nginx
    systemctl start nginx
    sleep 1

    if systemctl is-active --quiet nginx; then
        info "Nginx 伪装站点启动成功（监听 127.0.0.1:80）"
    else
        journalctl -u nginx --no-pager -n 10
        error "Nginx 启动失败"
    fi
}

# -------- 写入 Trojan-Go 配置文件 --------
write_config() {
    mkdir -p /etc/trojan-go
    cat > /etc/trojan-go/config.json << EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": ${PORT},
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "${PASSWORD}"
    ],
    "ssl": {
        "cert": "/etc/trojan-go/certs/fullchain.crt",
        "key":  "/etc/trojan-go/certs/private.key",
        "sni":  "${DOMAIN}",
        "fallback_port": 80
    },
    "mux": {
        "enabled": true,
        "concurrency": 8,
        "idle_timeout": 60
    },
    "websocket": {
        "enabled": false,
        "path": "/ws",
        "host": "${DOMAIN}"
    },
    "router": {
        "enabled": true,
        "bypass": ["geoip:cn", "geoip:private"],
        "block": ["geosite:category-ads"],
        "proxy": ["any"]
    },
    "log_level": 1
}
EOF
    info "Trojan-Go 配置文件写入：/etc/trojan-go/config.json"
}

# -------- 配置 systemd 服务（依赖 Nginx 先启动） --------
setup_service() {
    cat > /etc/systemd/system/trojan-go.service << EOF
[Unit]
Description=Trojan-Go Service
Documentation=https://p4gefau1t.github.io/trojan-go/
After=network-online.target nss-lookup.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable trojan-go
    systemctl restart trojan-go
    sleep 2

    if systemctl is-active --quiet trojan-go; then
        info "Trojan-Go 服务启动成功，已设置开机自启"
    else
        warn "服务启动异常，查看日志："
        journalctl -u trojan-go --no-pager -n 20
        error "请检查配置或证书后重试"
    fi
}

# -------- 配置证书自动续期 --------
setup_auto_renew() {
    CRON_CHECK=$(crontab -l 2>/dev/null | grep acme.sh || true)
    if [[ -z "$CRON_CHECK" ]]; then
        warn "acme.sh cron 未检测到，手动添加..."
        (crontab -l 2>/dev/null; echo "0 3 * * * $HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh > /dev/null 2>&1") | crontab -
    fi
    info "证书自动续期已配置（每天 03:00 检查，续期后自动重启服务）"
}

# -------- 配置防火墙（开443，封外部80） --------
setup_firewall() {
    info "配置防火墙规则..."

    if command -v ufw &>/dev/null; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1
        ufw deny  80/tcp        >/dev/null 2>&1
        info "ufw：已开放 $PORT / 已封锁外部 80 端口"

    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --permanent --remove-service=http   >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1
        info "firewalld：已开放 $PORT / 已移除 http(80) 规则"

    else
        warn "未检测到防火墙工具，请手动确认："
        warn "  - 开放端口 $PORT（对外）"
        warn "  - 封锁端口 80（对外） ← Nginx 只绑 127.0.0.1 本身已安全"
    fi
}

# -------- 验证整体运行状态 --------
verify_install() {
    echo ""
    info "验证安装状态..."

    if systemctl is-active --quiet nginx; then
        echo -e "  ${GREEN}✓${NC} Nginx 运行正常（伪装站点 127.0.0.1:80）"
    else
        echo -e "  ${RED}✗${NC} Nginx 未运行"
    fi

    if systemctl is-active --quiet trojan-go; then
        echo -e "  ${GREEN}✓${NC} Trojan-Go 运行正常（端口 $PORT）"
    else
        echo -e "  ${RED}✗${NC} Trojan-Go 未运行"
    fi

    if [[ -f "/etc/trojan-go/certs/fullchain.crt" ]]; then
        EXPIRE=$(openssl x509 -noout -enddate -in /etc/trojan-go/certs/fullchain.crt 2>/dev/null \
            | cut -d= -f2 || echo "未知")
        echo -e "  ${GREEN}✓${NC} TLS 证书有效，到期时间：$EXPIRE"
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80/ 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        echo -e "  ${GREEN}✓${NC} 伪装页响应正常（HTTP $HTTP_CODE）"
    else
        echo -e "  ${YELLOW}!${NC} 伪装页响应：HTTP $HTTP_CODE（请检查 Nginx）"
    fi
}

# -------- 输出客户端信息 --------
print_client_info() {
    echo ""
    echo -e "${GREEN}============================================"
    echo -e "  Trojan-Go 安装完成！"
    echo -e "============================================${NC}"
    echo ""
    echo -e "  ${CYAN}服务器地址${NC}：$DOMAIN"
    echo -e "  ${CYAN}端口${NC}      ：$PORT"
    echo -e "  ${CYAN}密码${NC}      ：$PASSWORD"
    echo -e "  ${CYAN}SNI${NC}       ：$DOMAIN"
    echo -e "  ${CYAN}协议${NC}      ：trojan"
    echo ""
    echo -e "  ${YELLOW}伪装站点${NC}  ：Nginx 空白默认页（127.0.0.1:80，对外不可见）"
    echo -e "  ${YELLOW}证书路径${NC}  ：/etc/trojan-go/certs/"
    echo -e "  ${YELLOW}配置路径${NC}  ：/etc/trojan-go/config.json"
    echo -e "  ${YELLOW}Nginx配置${NC} ：/etc/nginx/conf.d/trojan-camouflage.conf"
    echo ""
    echo -e "  ${YELLOW}查看日志${NC}  ：journalctl -u trojan-go -f"
    echo -e "  ${YELLOW}重启全部${NC}  ：systemctl restart nginx trojan-go"
    echo -e "  ${YELLOW}手动续期${NC}  ：~/.acme.sh/acme.sh --renew -d $DOMAIN --ecc --force"
    echo ""

    TROJAN_URL="trojan://${PASSWORD}@${DOMAIN}:${PORT}?sni=${DOMAIN}#TrojanGo-${DOMAIN}"
    echo -e "  ${CYAN}Trojan URL（导入客户端）${NC}："
    echo -e "  $TROJAN_URL"
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "  ${YELLOW}流量架构${NC}："
    echo -e "  外部流量 ──► Trojan-Go :${PORT} (TLS)"
    echo -e "                 │"
    echo -e "    ┌────────────┴────────────┐"
    echo -e "    │ 合法 Trojan 客户端      │ 其他/探测流量"
    echo -e "    ▼                         ▼"
    echo -e "  代理出站              Nginx 127.0.0.1:80"
    echo -e "                        └── 返回空白默认页"
    echo ""
}

# -------- 主流程 --------
main() {
    echo -e "${CYAN}"
    echo "  ████████╗██████╗  ██████╗      ██╗ █████╗ ███╗   ██╗     ██████╗  ██████╗ "
    echo "     ██╔══╝██╔══██╗██╔═══██╗     ██║██╔══██╗████╗  ██║    ██╔════╝ ██╔═══██╗"
    echo "     ██║   ██████╔╝██║   ██║     ██║███████║██╔██╗ ██║    ██║  ███╗██║   ██║"
    echo "     ██║   ██╔══██╗██║   ██║██   ██║██╔══██║██║╚██╗██║    ██║   ██║██║   ██║"
    echo "     ██║   ██║  ██║╚██████╔╝╚█████╔╝██║  ██║██║ ╚████║    ╚██████╔╝╚██████╔╝"
    echo "     ╚═╝   ╚═╝  ╚═╝ ╚═════╝  ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝     ╚═════╝  ╚═════╝ "
    echo -e "${NC}"
    echo "  一键安装脚本（含 Nginx 伪装）| Debian/Ubuntu/CentOS"
    echo ""

    check_os
    install_deps
    input_domain
    input_port
    input_password

    echo ""
    confirm "即将开始安装，配置如下："
    echo -e "  域名：${CYAN}$DOMAIN${NC}"
    echo -e "  端口：${CYAN}$PORT${NC}"
    echo -e "  密码：${CYAN}$(echo "$PASSWORD" | sed 's/./*/g')${NC}（已隐藏）"
    echo -e "  伪装：${CYAN}Nginx 空白默认页（仅 127.0.0.1:80）${NC}"
    echo ""
    read -rp "确认开始安装？(y/n): " start_yn
    [[ "$start_yn" != "y" && "$start_yn" != "Y" ]] && error "已取消安装"

    install_cert        # 1. 申请证书（standalone，需80空闲）
    setup_nginx         # 2. 启动 Nginx 伪装站点（127.0.0.1:80）
    install_trojan_go   # 3. 安装 Trojan-Go 二进制
    write_config        # 4. 写入 Trojan-Go 配置
    setup_service       # 5. 配置 systemd（After=nginx）
    setup_auto_renew    # 6. 证书自动续期
    setup_firewall      # 7. 防火墙：开443，封外部80
    verify_install      # 8. 健康检查
    print_client_info   # 9. 输出客户端信息
}

main "$@"
