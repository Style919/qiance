#!/bin/bash
# =============================================================
# Trojan-Go 一键安装脚本（含 Nginx 伪装）
# 支持：Let's Encrypt 免邮箱证书 / 自动续期 / systemd 自启
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
confirm() { echo -e "${CYAN}[CONFIRM]${NC} $1"; }

[[ $EUID -ne 0 ]] && error "请以 root 权限运行此脚本（sudo bash $0）"

# -------- 系统检查（正确区分 Ubuntu / Debian / CentOS） --------
check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu)                            OS="ubuntu"; PKG_MGR="apt-get" ;;
            debian)                            OS="debian"; PKG_MGR="apt-get" ;;
            centos|rhel|fedora|rocky|almalinux) OS="centos"; PKG_MGR="yum"   ;;
            *)                                 OS="$ID";    PKG_MGR="apt-get" ;;
        esac
        OS_DESC="${PRETTY_NAME:-$ID}"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"; PKG_MGR="yum"
        OS_DESC=$(cat /etc/redhat-release)
    else
        error "不支持的操作系统，仅支持 Debian/Ubuntu/CentOS"
    fi
    info "检测到系统：$OS_DESC"
}

# -------- 安装依赖 --------
install_deps() {
    info "安装基础依赖及 Nginx..."
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq
        apt-get install -y curl wget unzip socat cron nginx
    else
        yum install -y curl wget unzip socat cronie nginx
        systemctl enable crond && systemctl start crond
    fi
    systemctl stop nginx 2>/dev/null || true
    info "Nginx 已安装（暂停，证书申请后启动）"
}

# -------- 输入域名（printf 避免颜色乱码，回车=确认） --------
input_domain() {
    echo ""
    while true; do
        printf "请输入你的域名（例如 proxy.example.com）: "
        read -r DOMAIN
        [[ -z "$DOMAIN" ]] && warn "域名不能为空，请重新输入" && continue

        echo ""
        printf "确认域名为：\033[0;36m%s\033[0m？(回车或 y 确认 / n 重新输入): " "$DOMAIN"
        read -r yn
        case "${yn:-y}" in
            [Yy]*|"") break ;;
            *) warn "已取消，请重新输入域名" ;;
        esac
    done
    info "域名确认：$DOMAIN"
}

# -------- 输入端口 --------
input_port() {
    echo ""
    printf "请输入监听端口（默认 443，直接回车跳过）: "
    read -r PORT
    PORT=${PORT:-443}
    if ss -tlnp | grep -q ":${PORT} "; then
        warn "端口 $PORT 已被占用"
        printf "强制继续？(y/n): "
        read -r force
        [[ "${force:-n}" != "y" && "${force:-n}" != "Y" ]] && error "请释放端口后重试"
    fi
    info "监听端口：$PORT"
}

# -------- 输入密码 --------
input_password() {
    echo ""
    while true; do
        printf "请输入 Trojan 密码（不回显）: "
        read -rs PASSWORD
        echo ""
        [[ -z "$PASSWORD" ]] && warn "密码不能为空，请重新输入" && continue

        printf "请再次确认密码: "
        read -rs PASSWORD2
        echo ""

        if [[ "$PASSWORD" == "$PASSWORD2" ]]; then
            info "密码设置成功"
            break
        else
            warn "两次输入不一致，请重新输入"
        fi
    done
}

# -------- 申请 Let's Encrypt 证书 --------
install_cert() {
    info "安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
    ACME="$HOME/.acme.sh/acme.sh"
    [[ ! -f "$ACME" ]] && error "acme.sh 安装失败，请检查网络后重试"

    info "切换到 Let's Encrypt（免邮箱）..."
    "$ACME" --set-default-ca --server letsencrypt

    if ss -tlnp | grep -q ':80 '; then
        error "80 端口仍被占用，请检查后重试（lsof -i:80）"
    fi

    CERT_DIR="/etc/trojan-go/certs"
    mkdir -p "$CERT_DIR"

    # ---- DNS 等待 + 重试循环 ----
    while true; do
        info "申请证书：$DOMAIN（standalone 模式）..."
        if "$ACME" --issue -d "$DOMAIN" --standalone --keylength ec-256; then
            info "证书申请成功！"
            break
        else
            warn "----------------------------------------------"
            warn "证书申请失败！可能原因："
            warn "  1. 域名 DNS 尚未生效（最常见）"
            warn "  2. 80 端口未对外开放"
            warn "  3. 域名未解析到本机 IP"
            warn "----------------------------------------------"
            echo ""
            printf "请先完成 DNS 解析，完成后按回车重试，或输入 q 退出安装: "
            read -r retry_input
            [[ "${retry_input}" == "q" || "${retry_input}" == "Q" ]] && error "已退出安装"
            info "正在重试申请证书..."
        fi
    done

    "$ACME" --install-cert -d "$DOMAIN" --ecc \
        --cert-file      "$CERT_DIR/cert.crt" \
        --key-file       "$CERT_DIR/private.key" \
        --fullchain-file "$CERT_DIR/fullchain.crt" \
        --reloadcmd      "systemctl is-active nginx && systemctl reload nginx; systemctl restart trojan-go"

    chmod 600 "$CERT_DIR/private.key"
    info "证书已安装到 $CERT_DIR"
}

# -------- 配置 Nginx 伪装 --------
setup_nginx() {
    info "配置 Nginx 伪装站点..."

    WEB_ROOT="/var/www/trojan-camouflage"
    mkdir -p "$WEB_ROOT"

    cat > "$WEB_ROOT/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and working. Further configuration is required.</p>
<p>For online documentation and support please refer to <a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at <a href="http://nginx.com/">nginx.com</a>.</p>
<p><em>Thank you for using nginx.</em></p>
</body>
</html>
HTMLEOF

    cat > /etc/nginx/conf.d/trojan-camouflage.conf << EOF
server {
    listen 127.0.0.1:80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};
    index index.html;
    server_tokens off;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    location / { try_files \$uri \$uri/ =404; }
    access_log off;
    error_log  /dev/null;
}
EOF

    [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default && info "已禁用 Nginx default 站点"

    nginx -t || error "Nginx 配置测试失败"
    systemctl enable nginx
    systemctl start nginx
    sleep 1

    systemctl is-active --quiet nginx \
        && info "Nginx 伪装站点启动成功（127.0.0.1:80）" \
        || { journalctl -u nginx --no-pager -n 10; error "Nginx 启动失败"; }
}

# -------- 安装 Trojan-Go --------
install_trojan_go() {
    info "获取 Trojan-Go 最新版本..."
    LATEST=$(curl -fsSL https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$LATEST" ]] && error "无法获取最新版本，请检查网络"

    case $(uname -m) in
        x86_64)  ARCH_STR="amd64" ;;
        aarch64) ARCH_STR="arm64" ;;
        *)        error "不支持的架构：$(uname -m)" ;;
    esac

    TMP_DIR=$(mktemp -d)
    wget -q --show-progress \
        -O "$TMP_DIR/trojan-go.zip" \
        "https://github.com/p4gefau1t/trojan-go/releases/download/${LATEST}/trojan-go-linux-${ARCH_STR}.zip" \
        || error "下载失败，请检查网络"

    unzip -q "$TMP_DIR/trojan-go.zip" -d "$TMP_DIR/"
    install -m 755 "$TMP_DIR/trojan-go" /usr/local/bin/trojan-go
    rm -rf "$TMP_DIR"
    info "Trojan-Go ${LATEST} 安装完成"
}

# -------- 写入配置 --------
write_config() {
    mkdir -p /etc/trojan-go
    cat > /etc/trojan-go/config.json << EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": ${PORT},
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": ["${PASSWORD}"],
    "ssl": {
        "cert": "/etc/trojan-go/certs/fullchain.crt",
        "key":  "/etc/trojan-go/certs/private.key",
        "sni":  "${DOMAIN}",
        "fallback_port": 80
    },
    "mux": { "enabled": true, "concurrency": 8, "idle_timeout": 60 },
    "websocket": { "enabled": false, "path": "/ws", "host": "${DOMAIN}" },
    "router": {
        "enabled": true,
        "bypass": ["geoip:cn", "geoip:private"],
        "block":  ["geosite:category-ads"],
        "proxy":  ["any"]
    },
    "log_level": 1
}
EOF
    info "配置文件写入：/etc/trojan-go/config.json"
}

# -------- systemd 服务 --------
setup_service() {
    cat > /etc/systemd/system/trojan-go.service << EOF
[Unit]
Description=Trojan-Go Service
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

    systemctl is-active --quiet trojan-go \
        && info "Trojan-Go 启动成功，已设置开机自启" \
        || { journalctl -u trojan-go --no-pager -n 20; error "Trojan-Go 启动失败"; }
}

# -------- 证书自动续期 --------
setup_auto_renew() {
    CRON_CHECK=$(crontab -l 2>/dev/null | grep acme.sh || true)
    if [[ -z "$CRON_CHECK" ]]; then
        (crontab -l 2>/dev/null; echo "0 3 * * * $HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh > /dev/null 2>&1") | crontab -
    fi
    info "证书自动续期已配置（每天 03:00 检查）"
}

# -------- 防火墙 --------
setup_firewall() {
    info "配置防火墙..."
    if command -v ufw &>/dev/null; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1
        ufw deny  80/tcp        >/dev/null 2>&1
        info "ufw：开放 $PORT，封锁外部 80"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --permanent --remove-service=http   >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1
        info "firewalld：开放 $PORT，移除 http(80)"
    else
        warn "未检测到防火墙工具，请手动开放端口 $PORT"
    fi
}

# -------- 健康检查 --------
verify_install() {
    echo ""
    info "验证安装状态..."
    systemctl is-active --quiet nginx     && echo -e "  ${GREEN}✓${NC} Nginx 运行正常" || echo -e "  ${RED}✗${NC} Nginx 未运行"
    systemctl is-active --quiet trojan-go && echo -e "  ${GREEN}✓${NC} Trojan-Go 运行正常（:$PORT）" || echo -e "  ${RED}✗${NC} Trojan-Go 未运行"
    if [[ -f "/etc/trojan-go/certs/fullchain.crt" ]]; then
        EXPIRE=$(openssl x509 -noout -enddate -in /etc/trojan-go/certs/fullchain.crt 2>/dev/null | cut -d= -f2 || echo "未知")
        echo -e "  ${GREEN}✓${NC} 证书有效，到期：$EXPIRE"
    fi
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null || echo "000")
    [[ "$HTTP_CODE" == "200" ]] \
        && echo -e "  ${GREEN}✓${NC} 伪装页响应正常（HTTP 200）" \
        || echo -e "  ${YELLOW}!${NC} 伪装页 HTTP $HTTP_CODE（检查 Nginx）"
}

# -------- 输出客户端信息 --------
print_client_info() {
    TROJAN_URL="trojan://${PASSWORD}@${DOMAIN}:${PORT}?sni=${DOMAIN}#TrojanGo-${DOMAIN}"
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "  ${GREEN}安装完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo -e "  ${CYAN}地址${NC}：$DOMAIN     ${CYAN}端口${NC}：$PORT"
    echo -e "  ${CYAN}密码${NC}：$PASSWORD"
    echo -e "  ${CYAN}SNI ${NC}：$DOMAIN     ${CYAN}协议${NC}：trojan"
    echo ""
    echo -e "  ${YELLOW}日志${NC}：journalctl -u trojan-go -f"
    echo -e "  ${YELLOW}重启${NC}：systemctl restart nginx trojan-go"
    echo -e "  ${YELLOW}续期${NC}：~/.acme.sh/acme.sh --renew -d $DOMAIN --ecc --force"
    echo ""
    echo -e "  ${CYAN}Trojan URL：${NC}"
    echo -e "  $TROJAN_URL"
    echo -e "${GREEN}============================================${NC}"
}

# -------- 主流程 --------
main() {
    echo -e "${CYAN}  Trojan-Go 一键安装脚本（含 Nginx 伪装）${NC}"
    echo -e "  支持：Ubuntu 22.04 / Debian / CentOS"
    echo ""

    check_os
    install_deps
    input_domain
    input_port
    input_password

    echo ""
    confirm "请确认以下配置："
    echo -e "  系统：${CYAN}$OS_DESC${NC}"
    echo -e "  域名：${CYAN}$DOMAIN${NC}"
    echo -e "  端口：${CYAN}$PORT${NC}"
    echo -e "  密码：${CYAN}$(echo "$PASSWORD" | sed 's/./*/g')${NC}"
    echo ""
    printf "确认开始安装？(直接回车或输入 y 确认，n 取消): "
    read -r start_yn
    [[ "${start_yn:-y}" == "n" || "${start_yn:-y}" == "N" ]] && error "已取消安装"

    install_cert
    setup_nginx
    install_trojan_go
    write_config
    setup_service
    setup_auto_renew
    setup_firewall
    verify_install
    print_client_info
}

main "$@"
