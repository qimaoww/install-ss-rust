#!/bin/bash

# Shadowsocks-rust 管理脚本 (支持 Shadowsocks-2022 与多端口配置)
# 功能: 安装、添加配置、修改配置、查看配置、查看日志、服务管理

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/shadowsocks-rust"
CONF_FILE="${CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
PORT_MIN=10000
PORT_MAX=65535

# --- Colors & Logging ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_err()  { echo -e "${RED}[错误]${NC} $1" >&2; }
section()  { echo -e "\n${CYAN}--- $1 ---${NC}"; }

trim_ws() {
    # Trim leading/trailing whitespace (incl. tabs/newlines)
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_service_installed() {
    local load_state=""

    [ -f "${SERVICE_FILE}" ] && return 0

    if command -v systemctl >/dev/null 2>&1; then
        load_state=$(systemctl show -p LoadState --value shadowsocks-rust.service 2>/dev/null || true)
        [[ -n "$load_state" && "$load_state" != "not-found" ]] && return 0
    fi

    return 1
}

is_service_running() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet shadowsocks-rust
}

is_service_enabled() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet shadowsocks-rust
}

normalize_version() {
    local v="${1#v}"
    if [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "$v"
    fi
}

get_installed_version_tag() {
    local raw=""
    local ver=""

    if [ ! -x "${INSTALL_DIR}/ssserver" ]; then
        echo "未安装"
        return
    fi

    raw=$("${INSTALL_DIR}/ssserver" -V 2>/dev/null || true)
    ver=$(echo "$raw" | grep -Eo 'v?[0-9]+(\.[0-9]+)+' | head -n1 || true)

    if [[ -z "$ver" ]]; then
        echo "未知"
        return
    fi

    [[ "$ver" == v* ]] || ver="v${ver}"
    echo "$ver"
}

generate_random_available_port() {
    local candidate=""
    local attempts=0
    local max_attempts=300
    local span=$((PORT_MAX - PORT_MIN + 1))

    while [ "$attempts" -lt "$max_attempts" ]; do
        candidate=$((PORT_MIN + (((RANDOM << 15) | RANDOM) % span)))
        if ! jq -e ".servers[] | select(.server_port == $candidate)" "$CONF_FILE" > /dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
        attempts=$((attempts + 1))
    done

    for ((candidate=PORT_MIN; candidate<=PORT_MAX; candidate++)); do
        if ! jq -e ".servers[] | select(.server_port == $candidate)" "$CONF_FILE" > /dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

get_pkg_name() {
    local cmd="$1"
    local pm="$2"

    case "$cmd" in
        xz)
            if [ "$pm" = "apt" ]; then
                echo "xz-utils"
            else
                echo "xz"
            fi
            ;;
        base64)
            if [ "$pm" = "apt" ]; then
                echo "coreutils"
            else
                echo "coreutils"
            fi
            ;;
        ip)
            if [ "$pm" = "apt" ]; then
                echo "iproute2"
            else
                echo "iproute"
            fi
            ;;
        *) echo "$cmd" ;;
    esac
}

ensure_dependencies() {
    local missing_cmds=()
    local cmd=""
    local pkg=""

    for cmd in curl jq tar xz awk base64 ip; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -eq 0 ]; then
        return
    fi

    log_info "检查到缺失依赖: ${missing_cmds[*]}"

    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        for cmd in "${missing_cmds[@]}"; do
            pkg=$(get_pkg_name "$cmd" "apt")
            log_info "正在安装 ${pkg}..."
            apt-get install -yqq "$pkg"
        done
    elif command -v yum &> /dev/null; then
        for cmd in "${missing_cmds[@]}"; do
            pkg=$(get_pkg_name "$cmd" "yum")
            log_info "正在安装 ${pkg}..."
            yum install -yq "$pkg"
        done
    else
        log_err "未找到支持的包管理器。请手动安装: ${missing_cmds[*]}"
        exit 1
    fi
}

fetch_public_ip() {
    local ip=""

    ip=$(curl -4 -fsS --max-time 5 -A "install-ss-rust/1.0" https://api64.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -fsS --max-time 5 -A "install-ss-rust/1.0" https://ifconfig.me 2>/dev/null || true)
    fi

    if [[ -z "$ip" ]]; then
        echo "获取失败"
    else
        echo "$ip"
    fi
}

normalize_listen_addr() {
    local addr="$1"

    if [[ "$addr" =~ ^\[(.*)\]$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$addr"
    fi
}

select_outbound_bind_addr() {
    local -a addr_entries=()
    local line=""
    local iface=""
    local ip_cidr=""
    local ip_addr=""
    local choice=""
    local i=0

    SELECTED_OUTBOUND_ADDR=""

    if ! command -v ip &> /dev/null; then
        log_warn "未找到 ip 命令，无法读取网卡地址。"
        return 1
    fi

    while IFS= read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        ip_cidr=$(echo "$line" | awk '{print $4}')
        ip_addr=${ip_cidr%/*}
        addr_entries+=("${iface}|${ip_addr}")
    done < <(ip -o addr show up scope global | awk '$3=="inet" || $3=="inet6"')

    if [ ${#addr_entries[@]} -eq 0 ]; then
        log_warn "未读取到可用的网卡地址。"
        return 1
    fi

    section "可用网卡地址"
    for i in "${!addr_entries[@]}"; do
        iface=${addr_entries[$i]%|*}
        ip_addr=${addr_entries[$i]#*|}
        echo " $((i + 1)). ${iface} -> ${ip_addr}"
    done

    while true; do
        read -p "选择序号: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#addr_entries[@]}" ]; then
            SELECTED_OUTBOUND_ADDR=${addr_entries[$((choice - 1))]#*|}
            return 0
        fi
        log_warn "无效编号，请重新输入。"
    done
}

configure_network_options() {
    local ipv6_choice=""

    if [ ! -f "${CONF_FILE}" ]; then
        log_err "配置文件不存在，请先安装。"
        return 1
    fi

    section "全局网络配置"
    while true; do
        read -p "IPv6 优先？(y/N，回车保持当前): " ipv6_choice
        case "${ipv6_choice,,}" in
            ""|"y"|"n") break ;;
            *) log_warn "仅支持输入 y、n 或直接回车。" ;;
        esac
    done

    jq --arg ipv6 "$ipv6_choice" '
        if ($ipv6 | gsub("\\s+"; "") | length) == 0 then
            .
        else
            .ipv6_first = (($ipv6 | ascii_downcase) == "y")
        end
    ' "${CONF_FILE}" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "${CONF_FILE}"
    log_info "IPv6 优先配置已更新。"

    chmod 644 "${CONF_FILE}"
    return 0
}

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   log_err "此脚本必须以 root 权限运行。"
   exit 1
fi

# --- 核心功能函数 ---

validate_ss2022_key() {
    local method="$1"
    local key="$2"
    local expected_len=0
    local normalized_key=""
    local pad_len=0
    local decoded_len=""

    case "$method" in
        "2022-blake3-aes-128-gcm") expected_len=16 ;;
        "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305") expected_len=32 ;;
        *) return 1 ;;
    esac

    normalized_key=$(printf '%s' "$key" | tr '_-' '/+')
    pad_len=$(( (4 - ${#normalized_key} % 4) % 4 ))
    case "$pad_len" in
        1) normalized_key+="=" ;;
        2) normalized_key+="==" ;;
        3) normalized_key+="===" ;;
    esac

    if ! decoded_len=$(printf '%s' "$normalized_key" | base64 -d 2>/dev/null | wc -c); then
        return 1
    fi
    decoded_len=$(echo "$decoded_len" | awk '{print $1}')

    [[ "$decoded_len" -eq "$expected_len" ]]
}

install_ss() {
    local has_bin=0
    local has_conf=0
    local has_service=0
    local has_servers=0
    local reinstall_confirm=""

    [ -x "${INSTALL_DIR}/ssserver" ] && has_bin=1
    [ -f "${CONF_FILE}" ] && has_conf=1
    is_service_installed && has_service=1

    if [ "$has_conf" -eq 1 ]; then
        if jq -e '.servers | length > 0' "${CONF_FILE}" > /dev/null 2>&1; then
            has_servers=1
        fi
    fi

    if [ "$has_bin" -eq 1 ] && [ "$has_conf" -eq 1 ] && [ "$has_servers" -eq 0 ]; then
        log_warn "检测到配置文件存在但未配置任何端口。"
        log_info "正在进入修复流程：补全端口配置..."
        add_config "修复安装"

        if ! is_service_installed; then
            log_info "检测到服务未安装，正在补建服务..."
            create_service
            systemctl daemon-reload
            systemctl enable --now shadowsocks-rust
        else
            log_info "重启服务并应用配置..."
            systemctl restart shadowsocks-rust
        fi

        log_info "修复完成：端口与服务配置已就绪。"
        return
    fi

    if [ "$has_bin" -eq 1 ] && [ "$has_conf" -eq 1 ] && [ "$has_service" -eq 0 ]; then
        log_warn "检测到中断后的残留状态：服务未安装。"
        log_info "正在自动补建并启动服务..."
        create_service
        systemctl daemon-reload
        systemctl enable --now shadowsocks-rust
        log_info "修复完成：服务已安装并启动。"
        return
    fi

    if [ "$has_bin" -eq 1 ] || [ "$has_conf" -eq 1 ] || [ "$has_service" -eq 1 ]; then
        if [ "$has_bin" -eq 1 ] && [ "$has_conf" -eq 1 ] && [ "$has_service" -eq 1 ]; then
            log_warn "检测到已安装 Shadowsocks-rust（版本: $(get_installed_version_tag)）。"
            log_info "如需升级请使用菜单 8) 更新程序。"
            read -p "是否继续执行覆盖安装？(y/N): " reinstall_confirm
            if ! [[ "$reinstall_confirm" =~ ^[Yy]$ ]]; then
                log_info "已取消安装。"
                return
            fi
        else
            log_warn "检测到部分安装残留（bin=${has_bin}, conf=${has_conf}, service=${has_service}）。"
            read -p "是否继续安装以修复/补全？(y/N): " reinstall_confirm
            if ! [[ "$reinstall_confirm" =~ ^[Yy]$ ]]; then
                log_info "已取消安装。"
                return
            fi
        fi
    fi

    log_info "开始安装 Shadowsocks-rust (Shadowsocks-2022)..."

    log_info "检查依赖项..."
    ensure_dependencies

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  SS_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-musl" ;;
        *) log_err "不支持的系统架构: $ARCH"; exit 1 ;;
    esac

    log_info "获取最新版本信息..."
    LATEST_TAG=$(curl -fsSL -A "install-ss-rust/1.0" https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        log_warn "GitHub API 获取 latest 失败（可能被限流）。尝试从 releases 页面解析..."
        LATEST_TAG=$(curl -fsSL -A "install-ss-rust/1.0" https://github.com/shadowsocks/shadowsocks-rust/releases/latest \
            | grep -Eo '/shadowsocks/shadowsocks-rust/releases/tag/v[0-9]+(\.[0-9]+)+' \
            | head -n1 \
            | awk -F/ '{print $NF}' \
            || true)
    fi
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        log_err "获取最新发布版本失败（API 与页面解析均失败）。"
        exit 1
    fi

    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_TAG}/shadowsocks-${LATEST_TAG}.${SS_ARCH}.tar.xz"

    local extract_dir=""
    local download_file=""
    local bin=""
    extract_dir=$(mktemp -d /tmp/ss-rust.XXXXXX)
    download_file=$(mktemp /tmp/ss-rust.XXXXXX.tar.xz)

    log_info "正在为您下载 ${LATEST_TAG} 版本 (${ARCH})..."
    curl -fL --retry 3 --connect-timeout 10 -o "$download_file" "${DOWNLOAD_URL}"

    log_info "解压二进制文件至 ${INSTALL_DIR}..."
    tar -xJf "$download_file" -C "$extract_dir"
    for bin in ssserver sslocal ssservice ssurl ssmanager; do
        if [ -f "${extract_dir}/${bin}" ]; then
            install -m 755 "${extract_dir}/${bin}" "${INSTALL_DIR}/${bin}"
        fi
    done

    if [ ! -x "${INSTALL_DIR}/ssserver" ] || [ ! -x "${INSTALL_DIR}/ssservice" ]; then
        rm -f "$download_file"
        rm -rf "$extract_dir"
        log_err "安装失败：缺少必要二进制文件 (ssserver/ssservice)。"
        exit 1
    fi

    rm -f "$download_file"
    rm -rf "$extract_dir"

    log_info "初始化配置文件..."
    mkdir -p "${CONF_DIR}"
    cat > "${CONF_FILE}" <<EOF
{
    "servers": [],
    "timeout": 300,
    "fast_open": false,
    "ipv6_first": false,
    "mode": "tcp_and_udp"
}
EOF
    chmod 644 "${CONF_FILE}"

    configure_network_options

    add_config "首次安装"
    create_service
    
    log_info "启动并设置 shadowsocks-rust 服务开机自启..."
    systemctl daemon-reload
    systemctl enable --now shadowsocks-rust

    log_info "安装完成！"
    section "安装结果"
    view_config
    log_info "已返回主菜单，可继续选择操作。"
}

update_ss() {
    if [ ! -x "${INSTALL_DIR}/ssserver" ]; then
        log_warn "未检测到已安装的 ssserver，请先执行安装。"
        return
    fi

    log_info "开始更新 Shadowsocks-rust..."
    log_info "检查依赖项..."
    ensure_dependencies

    local ARCH=""
    local SS_ARCH=""
    local LATEST_TAG=""
    local DOWNLOAD_URL=""
    local extract_dir=""
    local download_file=""
    local bin=""
    local current_ver=""
    local current_norm=""
    local latest_norm=""

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  SS_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-musl" ;;
        *) log_err "不支持的系统架构: $ARCH"; return ;;
    esac

    current_ver=$(get_installed_version_tag)
    log_info "当前版本: ${current_ver}"

    log_info "获取最新版本信息..."
    LATEST_TAG=$(curl -fsSL -A "install-ss-rust/1.0" https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        log_warn "GitHub API 获取 latest 失败（可能被限流）。尝试从 releases 页面解析..."
        LATEST_TAG=$(curl -fsSL -A "install-ss-rust/1.0" https://github.com/shadowsocks/shadowsocks-rust/releases/latest \
            | grep -Eo '/shadowsocks/shadowsocks-rust/releases/tag/v[0-9]+(\.[0-9]+)+' \
            | head -n1 \
            | awk -F/ '{print $NF}' \
            || true)
    fi
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        log_err "获取最新发布版本失败（API 与页面解析均失败）。"
        return
    fi

    current_norm=$(normalize_version "$current_ver")
    latest_norm=$(normalize_version "$LATEST_TAG")

    if [[ -n "$current_norm" && -n "$latest_norm" ]]; then
        if [[ "$current_norm" == "$latest_norm" ]]; then
            log_info "已是最新版本：${LATEST_TAG}"
            return
        fi

        if [[ "$(printf '%s\n%s\n' "$current_norm" "$latest_norm" | sort -V | tail -n1)" != "$latest_norm" ]]; then
            log_info "当前版本 (${current_ver}) 不低于最新发布 (${LATEST_TAG})，无需更新。"
            return
        fi
    fi

    log_info "检测到新版本：${LATEST_TAG}，开始更新。"

    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_TAG}/shadowsocks-${LATEST_TAG}.${SS_ARCH}.tar.xz"
    extract_dir=$(mktemp -d /tmp/ss-rust.XXXXXX)
    download_file=$(mktemp /tmp/ss-rust.XXXXXX.tar.xz)

    log_info "下载最新版本 ${LATEST_TAG} (${ARCH})..."
    curl -fL --retry 3 --connect-timeout 10 -o "$download_file" "${DOWNLOAD_URL}"

    log_info "更新二进制文件..."
    tar -xJf "$download_file" -C "$extract_dir"
    for bin in ssserver sslocal ssservice ssurl ssmanager; do
        if [ -f "${extract_dir}/${bin}" ]; then
            install -m 755 "${extract_dir}/${bin}" "${INSTALL_DIR}/${bin}"
        fi
    done

    rm -f "$download_file"
    rm -rf "$extract_dir"

    if [ ! -x "${INSTALL_DIR}/ssserver" ] || [ ! -x "${INSTALL_DIR}/ssservice" ]; then
        log_err "更新失败：缺少必要二进制文件 (ssserver/ssservice)。"
        return
    fi

    if is_service_installed; then
        if is_service_running; then
            log_info "检测到服务运行中，正在重启应用更新..."
            systemctl restart shadowsocks-rust
        else
            log_info "服务当前未运行，已完成二进制更新。"
        fi
    fi

    log_info "更新完成: ${LATEST_TAG}"
}

add_config() {
    local context="${1:-""}"
    local SS_DNS=""
    if [ ! -f "${CONF_FILE}" ]; then
        log_err "配置文件不存在，请先安装。"
        return
    fi

    section "$context 新增端口"
    while true; do
        read -r -p "端口（${PORT_MIN}-${PORT_MAX}，回车随机）: " SS_PORT

        if [[ -z "$SS_PORT" ]]; then
            SS_PORT=$(generate_random_available_port || true)
            if [[ -z "$SS_PORT" ]]; then
                log_err "未找到可用端口，请删除旧端口后重试。"
                return
            fi
            log_info "已随机选择端口: $SS_PORT"
            break
        fi

        if [[ "$SS_PORT" =~ ^[0-9]+$ ]] && [ "$SS_PORT" -ge "$PORT_MIN" ] && [ "$SS_PORT" -le "$PORT_MAX" ]; then
            if jq -e ".servers[] | select(.server_port == $SS_PORT)" "$CONF_FILE" > /dev/null 2>&1; then
                log_warn "端口已存在，请换一个。"
            else
                break
            fi
        else
            log_warn "端口无效，请输入 ${PORT_MIN}-${PORT_MAX}。"
        fi
    done

    echo "加密方式："
    printf " %2s) %s\n" "1" "2022-blake3-aes-128-gcm（默认）"
    printf " %2s) %s\n" "2" "2022-blake3-aes-256-gcm"
    printf " %2s) %s\n" "3" "2022-blake3-chacha20-poly1305"
    read -r -p "选择 [1，默认 2022-blake3-aes-128-gcm]: " METHOD_CHOICE

    case $METHOD_CHOICE in
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac

    read -r -p "监听地址（默认 [::]）: " SS_SERVER
    SS_SERVER=$(trim_ws "${SS_SERVER:-}" )
    SS_SERVER=${SS_SERVER:-"[::]"}
    SS_SERVER=$(normalize_listen_addr "$SS_SERVER")
    if [[ -z "$SS_SERVER" ]]; then
        SS_SERVER="::"
    fi

    while true; do
        read -r -p "密钥（留空自动生成）: " SS_PASSWORD
        SS_PASSWORD=$(trim_ws "${SS_PASSWORD:-}")

        if [[ -z "${SS_PASSWORD}" ]]; then
            log_info "未输入密钥，正在为 $SS_METHOD 随机生成安全密钥..."
            SS_PASSWORD=$("${INSTALL_DIR}/ssservice" genkey -m "$SS_METHOD")
            break
        fi

        if validate_ss2022_key "$SS_METHOD" "$SS_PASSWORD"; then
            log_info "手动密钥格式校验通过。"
            break
        else
            log_warn "密钥格式无效：请使用对应算法长度的 Base64 密钥。"
        fi
    done

    read -r -p "端口DNS（留空不设置）: " SS_DNS

    log_info "写入端口配置..."
    
    jq --arg port "$SS_PORT" \
       --arg pass "$SS_PASSWORD" \
       --arg server "$SS_SERVER" \
       --arg method "$SS_METHOD" \
       --arg dns "$SS_DNS" \
       '.servers += [(
            {"server": $server, "server_port": ($port|tonumber), "password": $pass, "method": $method}
            | ($dns | gsub("^\\s+|\\s+$"; "")) as $dns_trim
            | if ($dns_trim | length) == 0 then . else . + {"dns": $dns_trim} end
        )]' \
       "${CONF_FILE}" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "${CONF_FILE}"
    
    chmod 644 "${CONF_FILE}"

    if [ "$context" != "首次安装" ]; then
        if is_service_installed; then
            log_info "重启服务并应用配置..."
            systemctl restart shadowsocks-rust
            log_info "端口已生效。"
        else
            log_warn "服务尚未安装，端口配置已写入。"
        fi
        view_config
    fi
}

create_service() {
    log_info "正在创建 systemd 系统服务..."

    # Create a dedicated system user for better security and to avoid systemd warnings
    RUN_USER="ss-rust"
    if ! id "$RUN_USER" &>/dev/null; then
        # In some non-interactive shells PATH may not include /usr/sbin
        if [ -x /usr/sbin/adduser ]; then
            # Debian/Ubuntu preferred
            /usr/sbin/adduser --system --no-create-home --disabled-login --shell /usr/sbin/nologin "$RUN_USER" >/dev/null
        elif [ -x /usr/sbin/useradd ]; then
            /usr/sbin/useradd -r -s /usr/sbin/nologin -M "$RUN_USER"
        elif command -v adduser >/dev/null 2>&1; then
            adduser --system --no-create-home --disabled-login --shell /usr/sbin/nologin "$RUN_USER" >/dev/null
        elif command -v useradd >/dev/null 2>&1; then
            useradd -r -s /usr/sbin/nologin -M "$RUN_USER"
        else
            log_err "未找到 adduser/useradd，无法创建系统用户。请确认已安装 adduser/passwd，且 PATH 包含 /usr/sbin。"
            return 1
        fi
    fi

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Shadowsocks-rust Server Service
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
LimitNOFILE=1048576

CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=${CONF_DIR}

ExecStart=${INSTALL_DIR}/ssserver -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
}

view_config() {
    if [ ! -f "${CONF_FILE}" ]; then
        log_err "配置文件不存在，请先安装。"
        return
    fi
    
    IP=$(fetch_public_ip)
    
    IPV6_FIRST=$(jq -r '.ipv6_first // false' "${CONF_FILE}")

    local service_status=""
    service_status=$(is_service_running && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}")

    echo -e "\n${CYAN}============== 当前配置 ==============${NC}"
    echo -e "[全局]"
    echo -e "  服务状态 : ${service_status}"
    echo -e "  服务器IP : ${IP}"
    echo -e "  IPv6优先 : ${IPV6_FIRST}"
    echo -e "----------------------------------------"

    # 读取所有服务器配置
    SERVER_COUNT=$(jq '.servers | length' "${CONF_FILE}")
    
    if [ "$SERVER_COUNT" -eq 0 ]; then
        log_warn "未找到任何端口配置。"
    else
        for (( i=0; i<$SERVER_COUNT; i++ )); do
            SS_SERVER=$(jq -r ".servers[$i].server" "${CONF_FILE}")
            SS_PORT=$(jq -r ".servers[$i].server_port" "${CONF_FILE}")
            SS_METHOD=$(jq -r ".servers[$i].method" "${CONF_FILE}")
            SS_PASSWORD=$(jq -r ".servers[$i].password" "${CONF_FILE}")
            SS_DNS=$(jq -r ".servers[$i].dns // \"未设置\"" "${CONF_FILE}")
            SS_OUTBOUND_BIND_ADDR=$(jq -r ".servers[$i].outbound_bind_addr // \"\"" "${CONF_FILE}")
            
            ENCODED_USERINFO=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0 | tr -d '=')
            SS_LINK="ss://${ENCODED_USERINFO}@${IP}:${SS_PORT}#ss-rust-${SS_PORT}"
            
            echo -e "[端口 $((i + 1))] ${SS_PORT}"
            echo -e "  监听地址 : ${SS_SERVER}"
            echo -e "  出站绑定 : ${SS_OUTBOUND_BIND_ADDR:-未设置}"
            echo -e "  DNS      : ${SS_DNS}"
            echo -e "  加密方式 : ${SS_METHOD}"
            echo -e "  连接密钥 : ${SS_PASSWORD}"
            echo -e "  一键链接 : ${GREEN}${SS_LINK}${NC}"
            echo -e "----------------------------------------"
        done
    fi
    echo -e "${CYAN}========================================${NC}"
}

remove_config() {
    local selected_no=""
    local del_index=""
    local del_entry=""
    local -a server_entries=()
    local i=0

    if [ ! -f "${CONF_FILE}" ]; then
        log_err "配置文件不存在，请先安装。"
        return
    fi

    if [ "$(jq '.servers | length' "${CONF_FILE}")" -eq 0 ]; then
        log_warn "当前没有可删除的端口配置。"
        return
    fi
    
    section "删除端口"
    mapfile -t server_entries < <(jq -r '.servers | to_entries[] | "\(.key)|\(.value.server_port)|\(.value.server)|\(.value.method)"' "${CONF_FILE}")

    echo "可删除端口："
    for i in "${!server_entries[@]}"; do
        del_entry="${server_entries[$i]}"
        printf " %2s) 端口:%-5s 监听:%-15s 方法:%s\n" \
            "$((i + 1))" \
            "$(echo "$del_entry" | awk -F'|' '{print $2}')" \
            "$(echo "$del_entry" | awk -F'|' '{print $3}')" \
            "$(echo "$del_entry" | awk -F'|' '{print $4}')"
    done

    while true; do
        read -p "选择序号（0返回）: " selected_no
        if [[ "$selected_no" == "0" ]]; then
            return
        fi
        if [[ "$selected_no" =~ ^[0-9]+$ ]] && [ "$selected_no" -ge 1 ] && [ "$selected_no" -le "${#server_entries[@]}" ]; then
            break
        fi
        log_warn "无效序号，请重新输入。"
    done

    del_entry="${server_entries[$((selected_no - 1))]}"
    del_index=$(echo "$del_entry" | awk -F'|' '{print $1}')
    DEL_PORT=$(echo "$del_entry" | awk -F'|' '{print $2}')

    jq --argjson idx "$del_index" 'del(.servers[$idx])' "${CONF_FILE}" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "${CONF_FILE}"
    log_info "已删除端口 $DEL_PORT。"
    log_info "重启服务并应用配置..."
    systemctl restart shadowsocks-rust
}

edit_config() {
    local edit_port=""
    local edit_index=""
    local selected_no=""
    local current_port=""
    local current_server=""
    local current_method=""
    local new_port=""
    local new_server=""
    local new_method=""
    local new_password=""
    local method_changed=0
    local method_choice=""
    local password_input=""
    local current_outbound_bind_addr=""
    local new_outbound_bind_addr=""
    local current_dns=""
    local new_dns=""
    local bind_choice=""
    local manual_outbound_bind_addr=""
    local -a server_entries=()
    local entry=""
    local i=0

    if [ ! -f "${CONF_FILE}" ]; then
        log_err "配置文件不存在，请先安装。"
        return
    fi

    if [ "$(jq '.servers | length' "${CONF_FILE}")" -eq 0 ]; then
        log_warn "当前没有可修改的端口配置。"
        return
    fi

    section "修改端口"
    mapfile -t server_entries < <(jq -r '.servers | to_entries[] | "\(.key)|\(.value.server_port)|\(.value.server)|\(.value.method)"' "${CONF_FILE}")

    echo "可修改端口："
    for i in "${!server_entries[@]}"; do
        entry="${server_entries[$i]}"
        printf " %2s) 端口:%-5s 监听:%-15s 方法:%s\n" \
            "$((i + 1))" \
            "$(echo "$entry" | awk -F'|' '{print $2}')" \
            "$(echo "$entry" | awk -F'|' '{print $3}')" \
            "$(echo "$entry" | awk -F'|' '{print $4}')"
    done

    while true; do
        read -p "选择序号: " selected_no
        if [[ "$selected_no" =~ ^[0-9]+$ ]] && [ "$selected_no" -ge 1 ] && [ "$selected_no" -le "${#server_entries[@]}" ]; then
            break
        fi
        log_warn "无效序号，请重新输入。"
    done

    entry="${server_entries[$((selected_no - 1))]}"
    edit_index=$(echo "$entry" | awk -F'|' '{print $1}')
    edit_port=$(echo "$entry" | awk -F'|' '{print $2}')

    current_port=$(jq -r ".servers[$edit_index].server_port" "${CONF_FILE}")
    current_server=$(jq -r ".servers[$edit_index].server" "${CONF_FILE}")
    current_method=$(jq -r ".servers[$edit_index].method" "${CONF_FILE}")
    new_password=$(jq -r ".servers[$edit_index].password" "${CONF_FILE}")
    current_dns=$(jq -r ".servers[$edit_index].dns // \"\"" "${CONF_FILE}")
    current_outbound_bind_addr=$(jq -r ".servers[$edit_index].outbound_bind_addr // \"\"" "${CONF_FILE}")

    echo "当前配置："
    echo "  端口     : ${current_port}"
    echo "  监听地址 : ${current_server}"
    echo "  加密方式 : ${current_method}"
    echo "  端口DNS  : ${current_dns:-未设置}"
    echo "  出站绑定 : ${current_outbound_bind_addr:-未设置}"
    read -p "新端口（${PORT_MIN}-${PORT_MAX}，回车保持，random/r随机）: " new_port
    if [[ -z "$new_port" ]]; then
        new_port="$current_port"
    elif [[ "${new_port,,}" == "random" || "${new_port,,}" == "r" ]]; then
        new_port=$(generate_random_available_port || true)
        if [[ -z "$new_port" ]]; then
            log_err "未找到可用端口，请删除旧端口后重试。"
            return
        fi
        log_info "已随机选择新端口: $new_port"
    else
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt "$PORT_MIN" ] || [ "$new_port" -gt "$PORT_MAX" ]; then
            log_err "端口无效，请输入 ${PORT_MIN}-${PORT_MAX}。"
            return
        fi

        if jq -e --arg port "$new_port" --argjson idx "$edit_index" '.servers | to_entries[] | select(.key != $idx and .value.server_port == ($port|tonumber))' "${CONF_FILE}" > /dev/null 2>&1; then
            log_warn "端口 $new_port 已被其它配置占用。"
            return
        fi
    fi

    read -p "新监听地址（回车保持，输入 [::] 用默认）: " new_server
    if [[ -z "$new_server" ]]; then
        new_server="$current_server"
    else
        new_server=$(normalize_listen_addr "$new_server")
        if [[ -z "$new_server" ]]; then
            new_server="::"
        fi
    fi

    echo "新加密方式（回车保持）:"
    printf " %2s) %s\n" "1" "2022-blake3-aes-128-gcm"
    printf " %2s) %s\n" "2" "2022-blake3-aes-256-gcm"
    printf " %2s) %s\n" "3" "2022-blake3-chacha20-poly1305"
    echo "当前: ${current_method}"
    read -p "选择 [默认保持]: " method_choice

    case "$method_choice" in
        "") new_method="$current_method" ;;
        1) new_method="2022-blake3-aes-128-gcm" ;;
        2) new_method="2022-blake3-aes-256-gcm" ;;
        3) new_method="2022-blake3-chacha20-poly1305" ;;
        *)
            log_warn "无效选择，已保持当前加密方式。"
            new_method="$current_method"
            ;;
    esac

    if [[ "$new_method" != "$current_method" ]]; then
        method_changed=1
        log_info "已修改加密方式，密钥留空将自动生成。"
    fi

    read -p "新密钥（回车自动处理，random 随机）: " password_input
    if [[ -n "$password_input" ]]; then
        if [[ "${password_input,,}" == "random" ]]; then
            new_password=$("${INSTALL_DIR}/ssservice" genkey -m "$new_method")
            log_info "已随机生成新密钥。"
        else
            if validate_ss2022_key "$new_method" "$password_input"; then
                new_password="$password_input"
                log_info "手动密钥格式校验通过。"
            else
                log_err "密钥格式无效：请使用对应算法长度的 Base64 密钥。"
                return
            fi
        fi
    elif [[ "$method_changed" -eq 1 ]]; then
        new_password=$("${INSTALL_DIR}/ssservice" genkey -m "$new_method")
        log_info "检测到加密方式已变更，已自动生成匹配的新密钥。"
    fi

    read -p "端口DNS（回车保持，输入 none 清空）: " new_dns
    if [[ -z "$new_dns" ]]; then
        new_dns="$current_dns"
    elif [[ "${new_dns,,}" == "none" ]]; then
        new_dns=""
    fi

    echo "出站绑定IP设置（当前: ${current_outbound_bind_addr:-未设置}）:"
    printf " %2s) %s\n" "1" "保持当前"
    printf " %2s) %s\n" "2" "从系统网卡地址选择"
    printf " %2s) %s\n" "3" "清空（不使用）"
    read -p "选择 [1]: " bind_choice

    case "$bind_choice" in
        2)
            if select_outbound_bind_addr; then
                new_outbound_bind_addr="$SELECTED_OUTBOUND_ADDR"
                log_info "已设置 outbound_bind_addr = ${new_outbound_bind_addr}"
            else
                read -p "手动输入出站绑定IP（回车保持）: " manual_outbound_bind_addr
                if [[ -n "$manual_outbound_bind_addr" ]]; then
                    new_outbound_bind_addr="$manual_outbound_bind_addr"
                else
                    new_outbound_bind_addr="$current_outbound_bind_addr"
                fi
            fi
            ;;
        3)
            new_outbound_bind_addr=""
            ;;
        *)
            new_outbound_bind_addr="$current_outbound_bind_addr"
            ;;
    esac

    jq --argjson idx "$edit_index" \
       --arg port "$new_port" \
       --arg server "$new_server" \
       --arg method "$new_method" \
       --arg pass "$new_password" \
             --arg dns "$new_dns" \
       --arg outaddr "$new_outbound_bind_addr" \
       '.servers[$idx].server_port = ($port|tonumber)
        | .servers[$idx].server = $server
        | .servers[$idx].method = $method
        | .servers[$idx].password = $pass
                | ($dns | gsub("^\\s+|\\s+$"; "")) as $dns_trim
                | if ($dns_trim | length) == 0 then
                        del(.servers[$idx].dns)
                    else
                        .servers[$idx].dns = $dns_trim
                    end
        | if ($outaddr | length) == 0 then
            del(.servers[$idx].outbound_bind_addr)
          else
            .servers[$idx].outbound_bind_addr = $outaddr
          end' \
       "${CONF_FILE}" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "${CONF_FILE}"

    chmod 644 "${CONF_FILE}"
    log_info "端口配置已更新。"

    if systemctl list-unit-files | grep -q shadowsocks-rust.service; then
        log_info "重启服务并应用配置..."
        systemctl restart shadowsocks-rust
    fi

    view_config
}

view_logs() {
    if ! is_service_installed; then
        log_err "服务未安装。"
        return
    fi
    section "实时日志（Ctrl+C 退出）"
    journalctl -u shadowsocks-rust -f
}

manage_service() {
    if ! is_service_installed; then
        log_err "服务未安装。"
        return
    fi

    local run_state=""
    local boot_state=""
    local run_state_c=""
    local boot_state_c=""

    while true; do
        section "服务管理"
        run_state=$(is_service_running && echo "运行中" || echo "未运行")
        boot_state=$(is_service_enabled && echo "已启用" || echo "未启用")

        if [[ "$run_state" == "运行中" ]]; then
            run_state_c="${GREEN}${run_state}${NC}"
        else
            run_state_c="${RED}${run_state}${NC}"
        fi

        if [[ "$boot_state" == "已启用" ]]; then
            boot_state_c="${GREEN}${boot_state}${NC}"
        else
            boot_state_c="${YELLOW}${boot_state}${NC}"
        fi

        echo -e "当前状态: 服务=${run_state_c} | 自启=${boot_state_c}"
        printf " %2s) %s\n" "1" "启动服务"
        printf " %2s) %s\n" "2" "停止服务"
        printf " %2s) %s\n" "3" "重启服务"
        printf " %2s) %s\n" "4" "启用开机自启"
        printf " %2s) %s\n" "5" "关闭开机自启"
        printf " %2s) %s\n" "0" "返回主菜单"
        read -p "请选择: " svc_choice
        case $svc_choice in
            1) systemctl start shadowsocks-rust; log_info "服务已启动。" ;;
            2) systemctl stop shadowsocks-rust; log_info "服务已停止。" ;;
            3) systemctl restart shadowsocks-rust; log_info "服务已重启。" ;;
            4) systemctl enable shadowsocks-rust; log_info "已启用开机自启。" ;;
            5) systemctl disable shadowsocks-rust; log_info "已关闭开机自启。" ;;
            0) return ;;
            *) log_warn "无效选项。" ;;
        esac
    done
}

uninstall_ss() {
    read -p "确认卸载（含全部配置）? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在停止并禁用服务..."
        systemctl stop shadowsocks-rust 2>/dev/null || true
        systemctl disable shadowsocks-rust 2>/dev/null || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        
        log_info "正在删除二进制文件..."
        rm -f "${INSTALL_DIR}/ssserver" "${INSTALL_DIR}/sslocal" "${INSTALL_DIR}/ssservice" "${INSTALL_DIR}/ssurl" "${INSTALL_DIR}/ssmanager"
        
        log_info "正在删除配置文件..."
        rm -rf "${CONF_DIR}"

        if id ss-rust &>/dev/null; then
            log_info "正在删除系统用户 ss-rust..."
            userdel ss-rust 2>/dev/null || true
        fi
        
        log_info "卸载完成。"
    else
        log_info "已取消卸载。"
    fi
}

get_runtime_status() {
    local installed="未安装"
    local service_state="未知"
    local boot_state="未知"
    local version="未安装"

    if [ -x "${INSTALL_DIR}/ssserver" ] && [ -f "${CONF_FILE}" ]; then
        installed="已安装"
    fi

    version=$(get_installed_version_tag)

    if command -v systemctl &>/dev/null; then
        if is_service_installed; then
            if is_service_running; then
                service_state="运行中"
            else
                service_state="未运行"
            fi

            if is_service_enabled; then
                boot_state="已启用"
            else
                boot_state="未启用"
            fi
        else
            service_state="未安装"
            boot_state="未安装"
        fi
    fi

    echo "${installed}|${service_state}|${boot_state}|${version}"
}

show_menu() {
    local status_line=""
    local installed=""
    local service_state=""
    local boot_state=""
    local version=""
    local installed_c=""
    local service_c=""
    local boot_c=""
    local version_c=""

    status_line=$(get_runtime_status)
    installed=$(echo "$status_line" | awk -F'|' '{print $1}')
    service_state=$(echo "$status_line" | awk -F'|' '{print $2}')
    boot_state=$(echo "$status_line" | awk -F'|' '{print $3}')
    version=$(echo "$status_line" | awk -F'|' '{print $4}')

    case "$installed" in
        "已安装") installed_c="${GREEN}${installed}${NC}" ;;
        "未安装") installed_c="${YELLOW}${installed}${NC}" ;;
        *) installed_c="${CYAN}${installed}${NC}" ;;
    esac

    case "$service_state" in
        "运行中") service_c="${GREEN}${service_state}${NC}" ;;
        "未运行") service_c="${RED}${service_state}${NC}" ;;
        "未安装") service_c="${YELLOW}${service_state}${NC}" ;;
        *) service_c="${CYAN}${service_state}${NC}" ;;
    esac

    case "$boot_state" in
        "已启用") boot_c="${GREEN}${boot_state}${NC}" ;;
        "未启用") boot_c="${YELLOW}${boot_state}${NC}" ;;
        "未安装") boot_c="${YELLOW}${boot_state}${NC}" ;;
        *) boot_c="${CYAN}${boot_state}${NC}" ;;
    esac

    case "$version" in
        "未安装"|"未知") version_c="${YELLOW}${version}${NC}" ;;
        *) version_c="${GREEN}${version}${NC}" ;;
    esac

    echo -e "\n${GREEN}====================================${NC}"
    echo -e "${GREEN}   Shadowsocks-rust 管理菜单       ${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo -e " 状态: 安装=${installed_c} | 服务=${service_c} | 自启=${boot_c} | 版本=${version_c}"
    echo "------------------------------------"
    echo " [安装初始化]"
    printf " %2s) %s\n" "1" "安装并初始化"
    echo ""
    echo " [端口配置]"
    printf " %2s) %s\n" "2" "查看配置"
    printf " %2s) %s\n" "3" "新增端口"
    printf " %2s) %s\n" "4" "修改端口"
    printf " %2s) %s\n" "5" "删除端口"
    echo ""
    echo " [系统管理]"
    printf " %2s) %s\n" "6" "查看日志"
    printf " %2s) %s\n" "7" "服务管理"
    printf " %2s) %s\n" "8" "更新程序"
    printf " %2s) %s\n" "9" "完全卸载"
    echo ""
    echo " [高级配置]"
    printf " %2s) %s\n" "10" "全局配置（IPv6优先）"
    printf " %2s) %s\n" "0" "退出"
    echo -e "${GREEN}====================================${NC}"
    read -p "输入序号: " choice
    echo ""
    
    case $choice in
        1) install_ss ;;
        2)
            view_config
            read -p "按回车返回主菜单..." _
            ;;
        3) add_config ;;
        4) edit_config ;;
        5) remove_config ;;
        6) view_logs ;;
        7) manage_service ;;
        8) update_ss ;;
        9) uninstall_ss ;;
        10)
            if configure_network_options; then
                if is_service_installed; then
                    systemctl restart shadowsocks-rust
                    log_info "配置已应用并重启服务。"
                else
                    log_warn "服务尚未安装，配置已写入文件，安装后会生效。"
                fi
            fi
            ;;
        0) exit 0 ;;
        *) log_warn "无效的选项，请重新输入。" ;;
    esac
}

# --- Main Loop ---
while true; do
    show_menu
done
