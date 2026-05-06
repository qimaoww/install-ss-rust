#!/bin/bash

# Shadowsocks-rust 管理脚本 (支持 Shadowsocks-2022 与多端口配置)
# 功能: 安装、添加配置、修改配置、查看配置、查看日志、服务管理

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/shadowsocks-rust"
CONF_FILE="${CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
ACL_FILE="${CONF_DIR}/block_cn.acl"
CN_IP_CACHE="${CONF_DIR}/.cn_ip.cache"
CN_DOMAIN_CACHE="${CONF_DIR}/.cn_domain.cache"
INBOUND_CN_IP_CACHE="${CONF_DIR}/.inbound_cn_ip.cache"
INBOUND_CN_BLOCK_ENABLED_FILE="${CONF_DIR}/.inbound_cn_block.enabled"
INBOUND_CN_BLOCK_BACKEND_FILE="${CONF_DIR}/.inbound_cn_block.backend"
INBOUND_CN_REAPPLY_SERVICE_NAME="shadowsocks-rust-inbound-cn-block.service"
INBOUND_CN_REAPPLY_SERVICE="/etc/systemd/system/shadowsocks-rust-inbound-cn-block.service"
INBOUND_CN_REAPPLY_SCRIPT="${CONF_DIR}/inbound_cn_block_reapply.sh"
INBOUND_CN_NFT_RULES_FILE="${CONF_DIR}/inbound_cn_block.nft"
INBOUND_CN_RANGES_FILE="${CONF_DIR}/inbound_cn_ipv4.ranges"
INBOUND_CN_NFT_TABLE="ss_rust"
INBOUND_CN_NFT_SET="cn_ipv4"
INBOUND_CN_NFT_CHAIN="inbound_cn_block"
INBOUND_CN_IPSET="ss_rust_cn_ipv4"
INBOUND_CN_IPTABLES_CHAIN="SS_RUST_CN_BLOCK"
CN_IP_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geoip/cn.list"
CN_DOMAIN_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/meta/geo/geosite/geolocation-cn.list"
PORT_MIN=10000
PORT_MAX=65535

# --- Colors & Logging ---
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "  ${GREEN}✔${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_err()  { echo -e "  ${RED}✘${NC} $1" >&2; }
section()  {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

press_any_key() {
    echo ""
    echo -ne "  ${DIM}按回车键返回主菜单...${NC}"
    read -r
}

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
        nft)
            echo "nftables"
            ;;
        iptables)
            echo "iptables"
            ;;
        ipset)
            echo "ipset"
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

is_valid_ipv4() {
    local ip="$1"
    local o1="" o2="" o3="" o4="" rest=""
    local octet=""

    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 rest <<< "$ip"
    [[ -z "$rest" && -n "$o1" && -n "$o2" && -n "$o3" && -n "$o4" ]] || return 1

    for octet in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

fetch_public_ip() {
    local ip=""
    local endpoint=""

    for endpoint in https://api64.ipify.org https://ifconfig.me/ip; do
        ip=$(curl -4 -fsS --max-time 5 -A "install-ss-rust/1.0" "$endpoint" 2>/dev/null || true)
        ip=$(trim_ws "$ip")
        if is_valid_ipv4 "$ip"; then
            echo "$ip"
            return
        fi
    done

    echo "获取失败"
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

download_cn_ip_to() {
    local target_file="$1"
    local label="${2:-中国 IP 列表}"
    local tmp_file=""
    tmp_file=$(mktemp /tmp/cn_ip.XXXXXX)

    log_info "正在下载${label}..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp_file" "${CN_IP_URL}"; then
        rm -f "$tmp_file"
        log_err "下载${label}失败，请检查网络连接。"
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        log_err "下载的${label}为空。"
        return 1
    fi
    mkdir -p "${CONF_DIR}"
    mv "$tmp_file" "$target_file"
    chmod 644 "$target_file"
    log_info "${label}已保存，共 $(wc -l < "$target_file") 条。"
    return 0
}

download_cn_ip() {
    download_cn_ip_to "${CN_IP_CACHE}" "中国 IP 列表"
}

download_inbound_cn_ip() {
    download_cn_ip_to "${INBOUND_CN_IP_CACHE}" "入站 CN IP 列表"
}

download_cn_domain() {
    local tmp_file=""
    local tmp_acl=""
    tmp_file=$(mktemp /tmp/cn_domain.XXXXXX)
    tmp_acl=$(mktemp /tmp/cn_domain_acl.XXXXXX)

    log_info "正在下载中国域名列表..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp_file" "${CN_DOMAIN_URL}"; then
        rm -f "$tmp_file" "$tmp_acl"
        log_err "下载中国域名列表失败，请检查网络连接。"
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file" "$tmp_acl"
        log_err "下载的中国域名列表为空。"
        return 1
    fi
    # 转换域名格式: +.domain -> ||domain , 纯域名 -> |domain
    awk '{
        if (/^\+\./) {
            sub(/^\+\./, "")
            print "||" $0
        } else if (/^[a-zA-Z0-9]/) {
            print "|" $0
        }
    }' "$tmp_file" > "$tmp_acl"
    rm -f "$tmp_file"
    mkdir -p "${CONF_DIR}"
    mv "$tmp_acl" "${CN_DOMAIN_CACHE}"
    chmod 644 "${CN_DOMAIN_CACHE}"
    log_info "中国域名列表已保存，共 $(wc -l < "${CN_DOMAIN_CACHE}") 条。"
    return 0
}

get_ss_ports() {
    local ports_text=""

    if [ ! -f "${CONF_FILE}" ]; then
        log_err "配置文件不存在，无法读取端口。"
        return 1
    fi

    if ! ports_text=$(jq -r '.servers[]?.server_port // empty' "${CONF_FILE}" 2>/dev/null | awk '/^[0-9]+$/ {print}' | sort -n -u); then
        log_err "读取 ssserver 端口失败，请检查配置文件格式。"
        return 1
    fi
    if [ -z "${ports_text}" ]; then
        log_err "未找到任何 ssserver 端口。"
        return 1
    fi

    printf '%s\n' "${ports_text}"
}

inbound_cn_block_enabled() {
    [ -f "${INBOUND_CN_BLOCK_ENABLED_FILE}" ]
}

install_firewall_cmds() {
    local cmd=""
    local pkg=""
    local -a missing_cmds=()

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -eq 0 ]; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        if ! apt-get update -qq; then
            log_err "更新 apt 软件源失败，请手动安装: ${missing_cmds[*]}"
            return 1
        fi
        for cmd in "${missing_cmds[@]}"; do
            pkg=$(get_pkg_name "$cmd" "apt")
            log_info "正在安装 ${pkg}..."
            if ! apt-get install -yqq "$pkg"; then
                log_err "安装 ${pkg} 失败。"
                return 1
            fi
        done
    elif command -v yum >/dev/null 2>&1; then
        for cmd in "${missing_cmds[@]}"; do
            pkg=$(get_pkg_name "$cmd" "yum")
            log_info "正在安装 ${pkg}..."
            if ! yum install -yq "$pkg"; then
                log_err "安装 ${pkg} 失败。"
                return 1
            fi
        done
    else
        log_err "未找到支持的包管理器。请手动安装: ${missing_cmds[*]}"
        return 1
    fi

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_err "依赖 ${cmd} 安装后仍不可用。"
            return 1
        fi
    done
}

ensure_firewall_dependencies() {
    SELECTED_FIREWALL_BACKEND=""

    if command -v nft >/dev/null 2>&1; then
        SELECTED_FIREWALL_BACKEND="nft"
        return 0
    fi

    if install_firewall_cmds nft; then
        SELECTED_FIREWALL_BACKEND="nft"
        return 0
    fi

    if command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
        SELECTED_FIREWALL_BACKEND="iptables"
        return 0
    fi

    if install_firewall_cmds iptables ipset; then
        SELECTED_FIREWALL_BACKEND="iptables"
        return 0
    fi

    log_err "未找到可用防火墙后端，请安装 nftables，或安装 iptables 与 ipset。"
    return 1
}

inbound_backend_available() {
    local backend="$1"

    case "$backend" in
        nft)
            command -v nft >/dev/null 2>&1
            ;;
        iptables)
            command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

is_valid_ipv4_cidr() {
    local cidr="$1"
    local ip=""
    local prefix="32"

    [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || return 1
    ip="${cidr%%/*}"
    if [[ "$cidr" == */* ]]; then
        prefix="${cidr#*/}"
    fi

    is_valid_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( 10#$prefix >= 1 && 10#$prefix <= 32 )) || return 1
}

get_inbound_cn_ipv4_ranges() {
    local line=""
    local tmp_ranges=""

    if [ ! -s "${INBOUND_CN_IP_CACHE}" ]; then
        log_err "入站 CN IP 列表不存在或为空。"
        return 1
    fi

    tmp_ranges=$(mktemp /tmp/ss-rust-cn-ipv4.XXXXXX)
    while IFS= read -r line; do
        line=$(trim_ws "$line")
        [ -n "$line" ] || continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" == *:* ]] && continue

        if ! is_valid_ipv4_cidr "$line"; then
            rm -f "$tmp_ranges"
            log_err "入站 CN IP 列表包含无效 IPv4/CIDR 条目: ${line}"
            return 1
        fi
        printf '%s\n' "$line" >> "$tmp_ranges"
    done < "${INBOUND_CN_IP_CACHE}"

    if [ ! -s "$tmp_ranges" ]; then
        rm -f "$tmp_ranges"
        log_err "入站 CN IPv4 列表为空。"
        return 1
    fi

    sort -u "$tmp_ranges"
    rm -f "$tmp_ranges"
}

join_lines_by_comma() {
    local item=""
    local joined=""

    while IFS= read -r item; do
        [ -n "$item" ] || continue
        if [ -n "$joined" ]; then
            joined+=", "
        fi
        joined+="$item"
    done

    printf '%s' "$joined"
}

build_inbound_cn_runtime_files() {
    local ports_text=""
    local ranges_text=""
    local ports_expr=""
    local range=""
    local first=1
    local tmp_nft=""
    local tmp_ranges=""
    local -a ports=()
    local -a ranges=()

    if ! ports_text=$(get_ss_ports); then
        return 1
    fi
    if ! ranges_text=$(get_inbound_cn_ipv4_ranges); then
        return 1
    fi

    mapfile -t ports <<< "${ports_text}"
    mapfile -t ranges <<< "${ranges_text}"
    if [ ${#ranges[@]} -eq 0 ]; then
        log_err "入站 CN IPv4 列表为空。"
        return 1
    fi

    ports_expr=$(printf '%s\n' "${ports[@]}" | join_lines_by_comma)
    tmp_nft=$(mktemp /tmp/ss-rust-inbound-cn.XXXXXX.nft)
    tmp_ranges=$(mktemp /tmp/ss-rust-cn-ipv4.XXXXXX)

    {
        printf 'table inet %s {\n' "${INBOUND_CN_NFT_TABLE}"
        printf '    set %s {\n' "${INBOUND_CN_NFT_SET}"
        printf '        type ipv4_addr\n'
        printf '        flags interval\n'
        printf '        auto-merge\n'
        printf '        elements = {\n'
        for range in "${ranges[@]}"; do
            if [ "$first" -eq 1 ]; then
                printf '            %s' "$range"
                first=0
            else
                printf ',\n            %s' "$range"
            fi
            printf '%s\n' "$range" >> "$tmp_ranges"
        done
        printf '\n        }\n'
        printf '    }\n'
        printf '    chain %s {\n' "${INBOUND_CN_NFT_CHAIN}"
        printf '        type filter hook input priority 0; policy accept;\n'
        printf '        ip saddr @%s tcp dport { %s } drop\n' "${INBOUND_CN_NFT_SET}" "$ports_expr"
        printf '        ip saddr @%s udp dport { %s } drop\n' "${INBOUND_CN_NFT_SET}" "$ports_expr"
        printf '    }\n'
        printf '}\n'
    } > "$tmp_nft"

    mkdir -p "${CONF_DIR}"
    mv "$tmp_nft" "${INBOUND_CN_NFT_RULES_FILE}"
    mv "$tmp_ranges" "${INBOUND_CN_RANGES_FILE}"
    chmod 644 "${INBOUND_CN_NFT_RULES_FILE}" "${INBOUND_CN_RANGES_FILE}"
}

install_inbound_cn_reapply_service() {
    mkdir -p "${CONF_DIR}"

    cat > "${INBOUND_CN_REAPPLY_SCRIPT}" <<EOF
#!/bin/bash
set -euo pipefail

CONF_FILE="${CONF_FILE}"
ENABLED_FILE="${INBOUND_CN_BLOCK_ENABLED_FILE}"
BACKEND_FILE="${INBOUND_CN_BLOCK_BACKEND_FILE}"
NFT_RULES_FILE="${INBOUND_CN_NFT_RULES_FILE}"
RANGES_FILE="${INBOUND_CN_RANGES_FILE}"
NFT_TABLE="${INBOUND_CN_NFT_TABLE}"
IPSET_NAME="${INBOUND_CN_IPSET}"
IPTABLES_CHAIN="${INBOUND_CN_IPTABLES_CHAIN}"

[ -f "\${ENABLED_FILE}" ] || exit 0
[ -f "\${CONF_FILE}" ] || exit 0
backend=""
if [ -f "\${BACKEND_FILE}" ]; then
    backend=\$(tr -d '[:space:]' < "\${BACKEND_FILE}")
fi
if [ -z "\${backend}" ]; then
    if command -v nft >/dev/null 2>&1; then
        backend="nft"
    elif command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
        backend="iptables"
    else
        exit 0
    fi
fi

mapfile -t ports < <(jq -r '.servers[]?.server_port // empty' "\${CONF_FILE}" 2>/dev/null | awk '/^[0-9]+$/ {print}' | sort -n -u)
if [ "\${#ports[@]}" -eq 0 ]; then
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "\${NFT_TABLE}" 2>/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -j "\${IPTABLES_CHAIN}" 2>/dev/null; do
            iptables -D INPUT -j "\${IPTABLES_CHAIN}" 2>/dev/null || break
        done
        iptables -F "\${IPTABLES_CHAIN}" 2>/dev/null || true
        iptables -X "\${IPTABLES_CHAIN}" 2>/dev/null || true
    fi
    if command -v ipset >/dev/null 2>&1; then
        ipset destroy "\${IPSET_NAME}" 2>/dev/null || true
    fi
    exit 0
fi

case "\${backend}" in
    nft)
        command -v nft >/dev/null 2>&1 || exit 0
        [ -s "\${NFT_RULES_FILE}" ] || exit 0
        nft -c -f "\${NFT_RULES_FILE}" >/dev/null 2>&1 || exit 0
        nft delete table inet "\${NFT_TABLE}" 2>/dev/null || true
        nft -f "\${NFT_RULES_FILE}"
        ;;
    iptables)
        command -v iptables >/dev/null 2>&1 || exit 0
        command -v ipset >/dev/null 2>&1 || exit 0
        [ -s "\${RANGES_FILE}" ] || exit 0
        tmp_set="\${IPSET_NAME}_tmp_\$\$"
        ipset destroy "\${tmp_set}" 2>/dev/null || true
        ipset create "\${tmp_set}" hash:net family inet -exist
        ipset flush "\${tmp_set}" 2>/dev/null || true
        while IFS= read -r range; do
            [ -n "\${range}" ] || continue
            ipset add "\${tmp_set}" "\${range}" -exist
        done < "\${RANGES_FILE}"
        if ipset list "\${IPSET_NAME}" >/dev/null 2>&1; then
            ipset swap "\${tmp_set}" "\${IPSET_NAME}"
            ipset destroy "\${tmp_set}" 2>/dev/null || true
        else
            ipset rename "\${tmp_set}" "\${IPSET_NAME}"
        fi
        iptables -N "\${IPTABLES_CHAIN}" 2>/dev/null || true
        iptables -F "\${IPTABLES_CHAIN}"
        for port in "\${ports[@]}"; do
            iptables -A "\${IPTABLES_CHAIN}" -p tcp --dport "\${port}" -m set --match-set "\${IPSET_NAME}" src -j DROP
            iptables -A "\${IPTABLES_CHAIN}" -p udp --dport "\${port}" -m set --match-set "\${IPSET_NAME}" src -j DROP
        done
        if ! iptables -C INPUT -j "\${IPTABLES_CHAIN}" 2>/dev/null; then
            iptables -I INPUT -j "\${IPTABLES_CHAIN}"
        fi
        ;;
esac
EOF
    chmod 755 "${INBOUND_CN_REAPPLY_SCRIPT}"

    cat > "${INBOUND_CN_REAPPLY_SERVICE}" <<EOF
[Unit]
Description=Reapply Shadowsocks-rust inbound CN IP block
After=network-online.target
Wants=network-online.target
Before=shadowsocks-rust.service

[Service]
Type=oneshot
ExecStart=${INBOUND_CN_REAPPLY_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable "${INBOUND_CN_REAPPLY_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
}

remove_inbound_cn_reapply_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable "${INBOUND_CN_REAPPLY_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    rm -f "${INBOUND_CN_REAPPLY_SERVICE}" "${INBOUND_CN_REAPPLY_SCRIPT}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

remove_inbound_cn_block_nft() {
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "${INBOUND_CN_NFT_TABLE}" 2>/dev/null || true
    fi
}

remove_inbound_cn_block_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -j "${INBOUND_CN_IPTABLES_CHAIN}" 2>/dev/null; do
            iptables -D INPUT -j "${INBOUND_CN_IPTABLES_CHAIN}" 2>/dev/null || break
        done
        iptables -F "${INBOUND_CN_IPTABLES_CHAIN}" 2>/dev/null || true
        iptables -X "${INBOUND_CN_IPTABLES_CHAIN}" 2>/dev/null || true
    fi

    if command -v ipset >/dev/null 2>&1; then
        ipset destroy "${INBOUND_CN_IPSET}" 2>/dev/null || true
    fi
}

apply_inbound_cn_block_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        log_err "未找到 nft 命令。"
        return 1
    fi

    build_inbound_cn_runtime_files || return 1

    if ! nft -c -f "${INBOUND_CN_NFT_RULES_FILE}" >/dev/null 2>&1; then
        log_err "校验 nftables 入站 CN IP 屏蔽规则失败。"
        return 1
    fi

    nft delete table inet "${INBOUND_CN_NFT_TABLE}" 2>/dev/null || true
    if ! nft -f "${INBOUND_CN_NFT_RULES_FILE}"; then
        log_err "应用 nftables 入站 CN IP 屏蔽规则失败。"
        return 1
    fi

    return 0
}

apply_inbound_cn_block_iptables() {
    local ports_text=""
    local range=""
    local port=""
    local tmp_set="${INBOUND_CN_IPSET}_tmp_$$"
    local -a ports=()
    local -a ranges=()

    if ! command -v iptables >/dev/null 2>&1 || ! command -v ipset >/dev/null 2>&1; then
        log_err "未找到 iptables 或 ipset 命令。"
        return 1
    fi
    if ! ports_text=$(get_ss_ports); then
        return 1
    fi
    build_inbound_cn_runtime_files || return 1

    mapfile -t ports <<< "${ports_text}"
    mapfile -t ranges < "${INBOUND_CN_RANGES_FILE}"
    if [ ${#ranges[@]} -eq 0 ]; then
        log_err "中国 IPv4 列表为空。"
        return 1
    fi

    ipset destroy "$tmp_set" 2>/dev/null || true
    if ! ipset create "$tmp_set" hash:net family inet -exist; then
        log_err "创建临时 ipset 失败。"
        return 1
    fi
    ipset flush "$tmp_set" 2>/dev/null || true
    for range in "${ranges[@]}"; do
        if ! ipset add "$tmp_set" "$range" -exist; then
            ipset destroy "$tmp_set" 2>/dev/null || true
            log_err "写入 ipset 中国 IP 段失败: ${range}"
            return 1
        fi
    done

    if ipset list "${INBOUND_CN_IPSET}" >/dev/null 2>&1; then
        if ! ipset swap "$tmp_set" "${INBOUND_CN_IPSET}"; then
            ipset destroy "$tmp_set" 2>/dev/null || true
            log_err "切换 ipset 失败。"
            return 1
        fi
        ipset destroy "$tmp_set" 2>/dev/null || true
    else
        if ! ipset rename "$tmp_set" "${INBOUND_CN_IPSET}"; then
            ipset destroy "$tmp_set" 2>/dev/null || true
            log_err "创建脚本专用 ipset 失败。"
            return 1
        fi
    fi

    iptables -N "${INBOUND_CN_IPTABLES_CHAIN}" 2>/dev/null || true
    if ! iptables -F "${INBOUND_CN_IPTABLES_CHAIN}"; then
        log_err "清空脚本专用 iptables 链失败。"
        return 1
    fi

    for port in "${ports[@]}"; do
        if ! iptables -A "${INBOUND_CN_IPTABLES_CHAIN}" -p tcp --dport "$port" -m set --match-set "${INBOUND_CN_IPSET}" src -j DROP; then
            log_err "添加 TCP 端口 ${port} 入站屏蔽规则失败。"
            return 1
        fi
        if ! iptables -A "${INBOUND_CN_IPTABLES_CHAIN}" -p udp --dport "$port" -m set --match-set "${INBOUND_CN_IPSET}" src -j DROP; then
            log_err "添加 UDP 端口 ${port} 入站屏蔽规则失败。"
            return 1
        fi
    done

    if ! iptables -C INPUT -j "${INBOUND_CN_IPTABLES_CHAIN}" 2>/dev/null; then
        if ! iptables -I INPUT -j "${INBOUND_CN_IPTABLES_CHAIN}"; then
            log_err "添加 INPUT 跳转规则失败。"
            return 1
        fi
    fi
}

apply_inbound_cn_block_backend() {
    local backend="$1"

    case "$backend" in
        nft)
            if apply_inbound_cn_block_nft; then
                remove_inbound_cn_block_iptables
                return 0
            fi
            ;;
        iptables)
            if apply_inbound_cn_block_iptables; then
                remove_inbound_cn_block_nft
                return 0
            fi
            ;;
    esac

    return 1
}

enable_inbound_cn_block() {
    local backend=""

    if [ ! -s "${INBOUND_CN_IP_CACHE}" ]; then
        download_inbound_cn_ip || return 1
    fi
    if ! ensure_firewall_dependencies; then
        return 1
    fi

    backend="${SELECTED_FIREWALL_BACKEND}"
    if ! apply_inbound_cn_block_backend "$backend"; then
        return 1
    fi

    mkdir -p "${CONF_DIR}"
    echo "enabled" > "${INBOUND_CN_BLOCK_ENABLED_FILE}"
    echo "$backend" > "${INBOUND_CN_BLOCK_BACKEND_FILE}"
    chmod 644 "${INBOUND_CN_BLOCK_ENABLED_FILE}" "${INBOUND_CN_BLOCK_BACKEND_FILE}"
    install_inbound_cn_reapply_service
    log_info "入站 CN IP 屏蔽已启用（后端: ${backend}）。"
}

disable_inbound_cn_block() {
    remove_inbound_cn_reapply_service
    remove_inbound_cn_block_nft
    remove_inbound_cn_block_iptables
    rm -f "${INBOUND_CN_BLOCK_ENABLED_FILE}" "${INBOUND_CN_BLOCK_BACKEND_FILE}" "${INBOUND_CN_NFT_RULES_FILE}" "${INBOUND_CN_RANGES_FILE}"
    log_info "入站 CN IP 屏蔽已禁用。"
}

reapply_inbound_cn_block() {
    local backend=""

    inbound_cn_block_enabled || return 0

    if [ -f "${CONF_FILE}" ] && [ "$(jq '.servers | length' "${CONF_FILE}" 2>/dev/null || echo 0)" -eq 0 ]; then
        remove_inbound_cn_block_nft
        remove_inbound_cn_block_iptables
        log_warn "入站 CN IP 屏蔽仍保持启用，但当前没有配置端口，已清理脚本管理的防火墙规则。"
        return 0
    fi

    if [ ! -s "${INBOUND_CN_IP_CACHE}" ]; then
        download_inbound_cn_ip || return 1
    fi

    if [ -f "${INBOUND_CN_BLOCK_BACKEND_FILE}" ]; then
        backend=$(trim_ws "$(cat "${INBOUND_CN_BLOCK_BACKEND_FILE}" 2>/dev/null || true)")
    fi

    if ! inbound_backend_available "$backend"; then
        if ! ensure_firewall_dependencies; then
            return 1
        fi
        backend="${SELECTED_FIREWALL_BACKEND}"
    fi

    if ! apply_inbound_cn_block_backend "$backend"; then
        return 1
    fi

    echo "$backend" > "${INBOUND_CN_BLOCK_BACKEND_FILE}"
    install_inbound_cn_reapply_service
    log_info "入站 CN IP 屏蔽规则已重新应用（后端: ${backend}）。"
}

configure_inbound_cn_block() {
    local choice=""
    local status=""
    local action_tag=""
    local backend=""

    while true; do
        backend=""
        if [ -f "${INBOUND_CN_BLOCK_BACKEND_FILE}" ]; then
            backend=$(trim_ws "$(cat "${INBOUND_CN_BLOCK_BACKEND_FILE}" 2>/dev/null || true)")
        fi

        if inbound_cn_block_enabled; then
            status="${GREEN}● 已启用${NC}${backend:+ ${DIM}(${backend})${NC}}"
            action_tag="禁用"
        else
            status="${DIM}○ 未启用${NC}"
            action_tag="启用"
        fi

        echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${BOLD}入站 CN IP 屏蔽${NC} ${DIM}(nftables / iptables+ipset)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  当前状态 :  ${status}"
        echo -e "  ${DIM}仅手动开启；独立于出站 ACL，不会在安装时自动启用。${NC}"
        echo -e "${DIM}  ──────────────────────────────────${NC}"
        echo -e "  ${BOLD}1${NC})  ${action_tag}入站 CN IP 屏蔽"
        echo -e "  ${BOLD}2${NC})  更新 CN IP 列表并重应用"
        echo -e "  ${BOLD}0${NC})  返回主菜单"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "  请选择: " choice

        case "$choice" in
            1)
                if inbound_cn_block_enabled; then
                    disable_inbound_cn_block
                else
                    enable_inbound_cn_block || log_warn "启用入站 CN IP 屏蔽失败。"
                fi
                ;;
            2)
                if inbound_cn_block_enabled; then
                    if download_inbound_cn_ip && reapply_inbound_cn_block; then
                        log_info "入站 CN IP 屏蔽列表已更新。"
                    else
                        log_warn "更新或重应用入站 CN IP 屏蔽失败。"
                    fi
                else
                    log_warn "入站 CN IP 屏蔽未启用，无需更新。"
                fi
                ;;
            0|"")
                return
                ;;
            *)
                log_warn "无效选项。"
                ;;
        esac
    done
}

rebuild_cn_acl() {
    local has_ip=0
    local has_domain=0

    [ -f "${CN_IP_CACHE}" ] && has_ip=1
    [ -f "${CN_DOMAIN_CACHE}" ] && has_domain=1

    if [ "$has_ip" -eq 0 ] && [ "$has_domain" -eq 0 ]; then
        rm -f "${ACL_FILE}"
        return 0
    fi

    mkdir -p "${CONF_DIR}"
    cat > "${ACL_FILE}" <<'ACLHEADER'
# Shadowsocks-rust ACL: 禁止出站到中国 IP/域名
# 由 install_ss_rust.sh 自动生成
# 数据来源: https://github.com/MetaCubeX/meta-rules-dat

[outbound_block_list]
ACLHEADER

    if [ "$has_ip" -eq 1 ]; then
        echo "" >> "${ACL_FILE}"
        echo "# --- 中国大陆 IP 段 ---" >> "${ACL_FILE}"
        cat "${CN_IP_CACHE}" >> "${ACL_FILE}"
    fi

    if [ "$has_domain" -eq 1 ]; then
        echo "" >> "${ACL_FILE}"
        echo "# --- 中国大陆域名 ---" >> "${ACL_FILE}"
        cat "${CN_DOMAIN_CACHE}" >> "${ACL_FILE}"
    fi

    chmod 644 "${ACL_FILE}"
    log_info "ACL 文件已生成，共 $(wc -l < "${ACL_FILE}") 行。"
    return 0
}

configure_block_cn() {
    local choice=""
    local ip_status=""
    local domain_status=""
    local ip_tag=""
    local domain_tag=""

    while true; do
        if [ -f "${CN_IP_CACHE}" ]; then
            ip_status="${GREEN}● 已启用${NC}"
            ip_tag="禁用"
        else
            ip_status="${DIM}○ 未启用${NC}"
            ip_tag="启用"
        fi
        if [ -f "${CN_DOMAIN_CACHE}" ]; then
            domain_status="${GREEN}● 已启用${NC}"
            domain_tag="禁用"
        else
            domain_status="${DIM}○ 未启用${NC}"
            domain_tag="启用"
        fi

        echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${BOLD}屏蔽中国出站${NC} ${DIM}(GeoIP / GeoSite)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  屏蔽 CN IP   :  ${ip_status}"
        echo -e "  屏蔽 CN 域名 :  ${domain_status}"
        echo -e "${DIM}  ──────────────────────────────────${NC}"
        echo -e "  ${BOLD}1${NC})  ${ip_tag}屏蔽 CN IP"
        echo -e "  ${BOLD}2${NC})  ${domain_tag}屏蔽 CN 域名"
        echo -e "  ${BOLD}3${NC})  更新列表（重新下载已启用项）"
        echo -e "  ${BOLD}0${NC})  返回主菜单"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "  请选择: " choice

        case "$choice" in
            1)
                if [ -f "${CN_IP_CACHE}" ]; then
                    rm -f "${CN_IP_CACHE}"
                    rebuild_cn_acl
                    rebuild_service_file
                    log_info "已禁用屏蔽 CN IP。"
                else
                    if download_cn_ip; then
                        rebuild_cn_acl
                        rebuild_service_file
                        log_info "已启用屏蔽 CN IP。"
                    fi
                fi
                ;;
            2)
                if [ -f "${CN_DOMAIN_CACHE}" ]; then
                    rm -f "${CN_DOMAIN_CACHE}"
                    rebuild_cn_acl
                    rebuild_service_file
                    log_info "已禁用屏蔽 CN 域名。"
                else
                    if download_cn_domain; then
                        rebuild_cn_acl
                        rebuild_service_file
                        log_info "已启用屏蔽 CN 域名。"
                    fi
                fi
                ;;
            3)
                local updated=0
                if [ -f "${CN_IP_CACHE}" ]; then
                    download_cn_ip && updated=1
                fi
                if [ -f "${CN_DOMAIN_CACHE}" ]; then
                    download_cn_domain && updated=1
                fi
                if [ "$updated" -eq 1 ]; then
                    rebuild_cn_acl
                    rebuild_service_file
                    log_info "列表已更新。"
                else
                    log_warn "当前没有启用任何下载项，无需更新。"
                fi
                ;;
            0|"")
                return
                ;;
            *)
                log_warn "无效选项。"
                ;;
        esac
    done
}

rebuild_service_file() {
    if is_service_installed; then
        create_service
        systemctl daemon-reload
        if is_service_running; then
            systemctl restart shadowsocks-rust
            log_info "服务已重启应用新配置。"
        fi
    fi
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
            log_info "如需升级请使用菜单 12) 更新程序。"
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

    section "是否屏蔽中国出站？"
    echo -e "  ${DIM}回车默认不启用，可稍后在菜单 7 中开启${NC}"
    local block_ip_init=""
    local block_domain_init=""
    read -p "  启用屏蔽 CN IP？[y/N]: " block_ip_init
    if [[ "${block_ip_init,,}" == "y" ]]; then
        download_cn_ip || log_warn "下载 CN IP 列表失败，可稍后在菜单中重试。"
    fi
    read -p "  启用屏蔽 CN 域名？[y/N]: " block_domain_init
    if [[ "${block_domain_init,,}" == "y" ]]; then
        download_cn_domain || log_warn "下载 CN 域名列表失败，可稍后在菜单中重试。"
    fi
    rebuild_cn_acl

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
    log_info "更新完成！"
}

configure_log_level() {
    section "切换日志等级"
    
    local current_level="info (默认)"
    if [ -f "${CONF_DIR}/.env" ]; then
        local env_level
        env_level=$(grep "^RUST_LOG=" "${CONF_DIR}/.env" | cut -d'=' -f2)
        [ -n "$env_level" ] && current_level="$env_level"
    fi

    echo -e "  当前日志等级: ${BOLD}${GREEN}${current_level}${NC}\n"
    
    echo -e "  ${BOLD}1.${NC} error (仅错误)"
    echo -e "  ${BOLD}2.${NC} warn  (警告和错误)"
    echo -e "  ${BOLD}3.${NC} info  (常规信息，默认)"
    echo -e "  ${BOLD}4.${NC} debug (调试信息)"
    echo -e "  ${BOLD}5.${NC} trace (最详细的底层报文)"
    echo -e "  ${BOLD}0.${NC} 返回主菜单"
    echo -e "${DIM}──────────────────────────────────${NC}"

    echo -ne "  ${GREEN}➤${NC} 请选择日志等级 [0-5]: "
    read -r log_choice

    local new_level=""
    case "$log_choice" in
        1) new_level="error" ;;
        2) new_level="warn" ;;
        3) new_level="info" ;;
        4) new_level="debug" ;;
        5) new_level="trace" ;;
        0|"") return ;;
        *) log_err "无效的选择"; return ;;
    esac

    echo "RUST_LOG=${new_level}" > "${CONF_DIR}/.env"
    
    if is_service_installed; then
        log_info "正在应用新的日志等级 (${new_level}) 并重启服务..."
        systemctl daemon-reload
        systemctl restart shadowsocks-rust
        log_info "日志等级已切换！"
    else
        log_info "日志等级 (${new_level}) 已保存，将在安装服务后生效。"
    fi
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
        echo -ne "  ${GREEN}➤${NC} 端口（${PORT_MIN}-${PORT_MAX}，回车随机）: "; read -r SS_PORT

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

    echo -e "\n  ${DIM}── 加密方式设置 ──${NC}"
    echo -e "  ${BOLD}1${NC}) 2022-blake3-aes-128-gcm ${DIM}(默认)${NC}"
    echo -e "  ${BOLD}2${NC}) 2022-blake3-aes-256-gcm"
    echo -e "  ${BOLD}3${NC}) 2022-blake3-chacha20-poly1305"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    echo -ne "  ${GREEN}➤${NC} 选择 [1]: "; read -r METHOD_CHOICE

    case $METHOD_CHOICE in
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac

    echo -ne "  ${GREEN}➤${NC} 监听地址（默认 [::]）: "; read -r SS_SERVER
    SS_SERVER=$(trim_ws "${SS_SERVER:-}" )
    SS_SERVER=${SS_SERVER:-"[::]"}
    SS_SERVER=$(normalize_listen_addr "$SS_SERVER")
    if [[ -z "$SS_SERVER" ]]; then
        SS_SERVER="::"
    fi

    while true; do
        echo -ne "  ${GREEN}➤${NC} 密钥（留空自动生成）: "; read -r SS_PASSWORD
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

    echo -ne "  ${GREEN}➤${NC} 端口DNS（留空不设置）: "; read -r SS_DNS

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
    reapply_inbound_cn_block || log_warn "入站 CN IP 屏蔽规则重应用失败，请在菜单中手动更新。"

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
    mkdir -p "${CONF_DIR}"

    # Create a dedicated system user for better security and to avoid systemd warnings
    RUN_USER="ss-rust"
    if ! id "$RUN_USER" &>/dev/null; then
        # In some non-interactive shells PATH may not include /usr/sbin
        if [ -x /usr/sbin/adduser ]; then
            # Debian/Ubuntu preferred
            /usr/sbin/adduser --system --group --no-create-home --disabled-login --shell /usr/sbin/nologin "$RUN_USER" >/dev/null
        elif [ -x /usr/sbin/useradd ]; then
            /usr/sbin/useradd -r -s /usr/sbin/nologin -M "$RUN_USER"
        elif command -v adduser >/dev/null 2>&1; then
            adduser --system --group --no-create-home --disabled-login --shell /usr/sbin/nologin "$RUN_USER" >/dev/null
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

EnvironmentFile=-${CONF_DIR}/.env
ExecStart=${INSTALL_DIR}/ssserver -c ${CONF_FILE}$([ -f "${ACL_FILE}" ] && echo " --acl ${ACL_FILE}")
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

    local block_cn_ip_status=""
    local block_cn_domain_status=""
    if [ -f "${CN_IP_CACHE}" ]; then
        block_cn_ip_status="${GREEN}已启用${NC}"
    else
        block_cn_ip_status="${YELLOW}未启用${NC}"
    fi
    if [ -f "${CN_DOMAIN_CACHE}" ]; then
        block_cn_domain_status="${GREEN}已启用${NC}"
    else
        block_cn_domain_status="${YELLOW}未启用${NC}"
    fi

    local inbound_cn_status=""
    local inbound_cn_backend=""
    if [ -f "${INBOUND_CN_BLOCK_BACKEND_FILE}" ]; then
        inbound_cn_backend=$(trim_ws "$(cat "${INBOUND_CN_BLOCK_BACKEND_FILE}" 2>/dev/null || true)")
    fi
    if inbound_cn_block_enabled; then
        inbound_cn_status="${GREEN}已启用${NC}${inbound_cn_backend:+ ${DIM}(${inbound_cn_backend})${NC}}"
    else
        inbound_cn_status="${YELLOW}未启用${NC}"
    fi

    local current_log_level="info (默认)"
    if [ -f "${CONF_DIR}/.env" ]; then
        local env_level
        env_level=$(grep "^RUST_LOG=" "${CONF_DIR}/.env" | cut -d'=' -f2)
        [ -n "$env_level" ] && current_log_level="$env_level"
    fi

    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}当前配置信息${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${DIM}── 全局设置 ──${NC}"
    echo -e "  服务状态    ${service_status}"
    echo -e "  服务器IP    ${BOLD}${IP}${NC}"
    echo -e "  IPv6优先    ${IPV6_FIRST}"
    echo -e "  屏蔽CN IP   ${block_cn_ip_status}"
    echo -e "  屏蔽CN 域名  ${block_cn_domain_status}"
    echo -e "  入站CN IP   ${inbound_cn_status}"
    echo -e "  日志等级    ${BOLD}${current_log_level}${NC}"
    echo -e "${DIM}────────────────────────────────────${NC}"
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
            
            SS_LINK="ss://${SS_METHOD}:${SS_PASSWORD}@${IP}:${SS_PORT}#ss-rust-${SS_PORT}"
            
            echo -e "  ${DIM}── 端口 $((i + 1)) ──${NC}"
            echo -e "  端口号      ${MAGENTA}${BOLD}${SS_PORT}${NC}"
            echo -e "  监听地址    ${SS_SERVER}"
            echo -e "  出站绑定    ${SS_OUTBOUND_BIND_ADDR:-未设置}"
            echo -e "  DNS         ${SS_DNS}"
            echo -e "  加密方式    ${SS_METHOD}"
            echo -e "  连接密钥    ${SS_PASSWORD}"
            echo -e "  一键链接    ${GREEN}${SS_LINK}${NC}"
        done
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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

    echo -e "  ${DIM}──────────────────────────────────${NC}"
    echo -e "  ${BOLD}可删除端口：${NC}"
    for i in "${!server_entries[@]}"; do
        del_entry="${server_entries[$i]}"
        printf "  ${BOLD}%2s${NC}) 端口: %-5s 监听: %-15s 方法: %s\n" \
            "$((i + 1))" \
            "$(echo "$del_entry" | awk -F'|' '{print $2}')" \
            "$(echo "$del_entry" | awk -F'|' '{print $3}')" \
            "$(echo "$del_entry" | awk -F'|' '{print $4}')"
    done
    echo -e "  ${DIM}──────────────────────────────────${NC}"

    while true; do
        echo -ne "  ${GREEN}➤${NC} 选择序号（0返回）: "; read -r selected_no
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
    reapply_inbound_cn_block || log_warn "入站 CN IP 屏蔽规则重应用失败，请在菜单中手动更新。"
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

    echo -e "  ${DIM}──────────────────────────────────${NC}"
    echo -e "  ${BOLD}可修改端口：${NC}"
    for i in "${!server_entries[@]}"; do
        entry="${server_entries[$i]}"
        printf "  ${BOLD}%2s${NC}) 端口: %-5s 监听: %-15s 方法: %s\n" \
            "$((i + 1))" \
            "$(echo "$entry" | awk -F'|' '{print $2}')" \
            "$(echo "$entry" | awk -F'|' '{print $3}')" \
            "$(echo "$entry" | awk -F'|' '{print $4}')"
    done
    echo -e "  ${DIM}──────────────────────────────────${NC}"

    while true; do
        echo -ne "  ${GREEN}➤${NC} 选择序号: "; read -r selected_no
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

    echo -e "\n  ${DIM}── 当前配置 ──${NC}"
    printf "  %-12s : ${MAGENTA}%s${NC}\n" "端口" "${current_port}"
    printf "  %-12s : %s\n" "监听地址" "${current_server}"
    printf "  %-12s : %s\n" "加密方式" "${current_method}"
    printf "  %-12s : %s\n" "端口DNS" "${current_dns:-未设置}"
    printf "  %-12s : %s\n" "出站绑定" "${current_outbound_bind_addr:-未设置}"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    
    echo -ne "  ${GREEN}➤${NC} 新端口（${PORT_MIN}-${PORT_MAX}，回车保持，random/r随机）: "; read -r new_port
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

    echo -ne "  ${GREEN}➤${NC} 新监听地址（回车保持，输入 [::] 用默认）: "; read -r new_server
    if [[ -z "$new_server" ]]; then
        new_server="$current_server"
    else
        new_server=$(normalize_listen_addr "$new_server")
        if [[ -z "$new_server" ]]; then
            new_server="::"
        fi
    fi

    echo -e "\n  ${DIM}── 加密方式设置 ──${NC}"
    echo -e "  ${BOLD}1${NC}) 2022-blake3-aes-128-gcm"
    echo -e "  ${BOLD}2${NC}) 2022-blake3-aes-256-gcm"
    echo -e "  ${BOLD}3${NC}) 2022-blake3-chacha20-poly1305"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    echo -ne "  ${GREEN}➤${NC} 选择（当前: ${current_method}，回车保持）: "; read -r method_choice

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

    echo -ne "  ${GREEN}➤${NC} 新密钥（回车自动处理，random 随机）: "; read -r password_input
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

    echo -ne "  ${GREEN}➤${NC} 端口DNS（回车保持，none 清空）: "; read -r new_dns
    if [[ -z "$new_dns" ]]; then
        new_dns="$current_dns"
    elif [[ "${new_dns,,}" == "none" ]]; then
        new_dns=""
    fi

    echo -e "\n  ${DIM}── 出站绑定IP设置 ──${NC}"
    echo -e "  ${BOLD}1${NC}) 保持当前 ${DIM}(${current_outbound_bind_addr:-未设置})${NC}"
    echo -e "  ${BOLD}2${NC}) 从系统网卡地址选择"
    echo -e "  ${BOLD}3${NC}) 清空（不使用）"
    echo -e "  ${DIM}──────────────────────────────────${NC}"
    echo -ne "  ${GREEN}➤${NC} 选择 [1]: "; read -r bind_choice

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
    reapply_inbound_cn_block || log_warn "入站 CN IP 屏蔽规则重应用失败，请在菜单中手动更新。"

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
    section "服务日志"
    
    # 使用 less +F 实时跟随日志，底部显示操作提示
    journalctl -u shadowsocks-rust -n 100 -f 2>&1 | less -R +F -P "Press q to quit, Ctrl+C to pause, Shift+F to resume"
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
        log_info "正在清理入站 CN IP 屏蔽规则..."
        disable_inbound_cn_block || true

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

    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Shadowsocks-rust 管理菜单${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  系统安装: ${installed_c}   |   服务运行: ${service_c}"
    echo -e "  开机自启: ${boot_c}   |   当前版本: ${version_c}"
    echo -e "${DIM}  ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}1${NC})  安装并初始化"
    echo -e "${DIM}  ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}2${NC})  查看配置"
    echo -e "  ${BOLD}3${NC})  新增端口"
    echo -e "  ${BOLD}4${NC})  修改端口"
    echo -e "  ${BOLD}5${NC})  删除端口"
    echo -e "${DIM}  ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}6${NC})  全局配置（IPv6优先）"
    echo -e "  ${BOLD}7${NC})  出站 ACL 控制"
    echo -e "  ${BOLD}8${NC})  入站 CN IP 屏蔽"
    echo -e "${DIM}  ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}9${NC})  查看实时日志"
    echo -e "  ${BOLD}10${NC}) 切换日志等级（debug/info/warn等）"
    echo -e "${DIM}  ──────────────────────────────────${NC}"
    echo -e "  ${BOLD}11${NC}) 服务管理"
    echo -e "  ${BOLD}12${NC}) 更新程序"
    echo -e "  ${BOLD}13${NC}) 完全卸载"
    echo -e "  ${BOLD}0${NC})  退出"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  请选择: " choice
    echo ""
    
    case $choice in
        1) install_ss; press_any_key ;;
        2) view_config; press_any_key ;;
        3) add_config; press_any_key ;;
        4) edit_config; press_any_key ;;
        5) remove_config; press_any_key ;;
        6)
            if configure_network_options; then
                if is_service_installed; then
                    systemctl restart shadowsocks-rust
                    log_info "配置已应用并重启服务。"
                else
                    log_warn "服务尚未安装，配置已写入文件，安装后会生效。"
                fi
            fi
            press_any_key
            ;;
        7) configure_block_cn; press_any_key ;;
        8) configure_inbound_cn_block; press_any_key ;;
        9) view_logs; press_any_key ;;
        10) configure_log_level; press_any_key ;;
        11) manage_service; press_any_key ;;
        12) update_ss; press_any_key ;;
        13) uninstall_ss; press_any_key ;;
        0) exit 0 ;;
        *) log_warn "无效的选项，请重新输入。"; press_any_key ;;
    esac
}

# --- Main Loop ---
while true; do
    show_menu
done
