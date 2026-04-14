#!/bin/bash
set -euo pipefail

TUNNEL_REMOTE_BASE="172.16.0"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
declare -A ROUTES=()

usage() {
    echo "Usage:"
    echo "  Setup remote host:"
    echo "    $0 setup [-b <tunnel_base>]"
    echo ""
    echo "  Bring tunnel up:"
    echo "    $0 up -r <remote_host> -f <target_file> -k <ssh_key> -t <tun_number> [-b <tunnel_base>]"
    echo ""
    echo "  Tear tunnel down:"
    echo "    $0 down -f <target_file> -t <tun_number> [-b <tunnel_base>]"
    echo ""
    echo "  Clean up remote host:"
    echo "    $0 cleanup -r <remote_host> -k <ssh_key> -t <tun_number>"
    echo ""
    echo "  Show help:"
    echo "    $0 -h"
    echo ""
    echo "Options:"
    echo "  -r    Remote host public IP (required for up/cleanup)"
    echo "  -f    Target file containing IPs/ranges, one per line (required for up/down)"
    echo "  -k    Full path to SSH private key (required for up/cleanup)"
    echo "        Must be an absolute path since this script runs with sudo"
    echo "  -t    Tunnel device number 0-62 (required for up/down/cleanup)"
    echo "        Each tester must use a unique number"
    echo "  -b    Tunnel IP base, must be RFC1918 (optional, default: 172.16.0)"
    echo "  -h    Show this help message"
    echo ""
    echo "NOTE: The tunnel base (-b) must not conflict with any IP ranges being"
    echo "scanned. For example, if scanning 172.16.x.x networks, use a different"
    echo "base such as 10.255.0 to avoid routing conflicts."
    echo ""
    echo "NOTE: This script must be run as root or with sudo. Use absolute paths"
    echo "for the SSH key since relative paths will not resolve correctly under sudo."
    echo ""
    echo "Examples:"
    echo "  Remote host setup (run once):"
    echo "    $0 setup"
    echo "    $0 setup -b 10.255.0"
    echo ""
    echo "  Tester 1 brings up tunnel and scans:"
    echo "    sudo $0 up -r 203.0.113.50 -f targets.txt -k /home/user/.ssh/client_key -t 0"
    echo "    sudo $0 down -f targets.txt -t 0"
    echo "    sudo $0 cleanup -r 203.0.113.50 -k /home/user/.ssh/client_key -t 0"
    echo ""
    echo "  Tester 2 brings up tunnel with custom base:"
    echo "    sudo $0 up -r 203.0.113.50 -f targets.txt -k /home/user/.ssh/client_key -t 1 -b 10.255.0"
    echo "    sudo $0 down -f targets.txt -t 1 -b 10.255.0"
    echo "    sudo $0 cleanup -r 203.0.113.50 -k /home/user/.ssh/client_key -t 1"
    exit 0
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This script must be run as root or with sudo."
        exit 1
    fi
}

validate_tun_num() {
    local n=$1
    if [[ ! "$n" =~ ^[0-9]+$ ]] || [ "$n" -gt 62 ]; then
        echo "ERROR: -t must be an integer between 0 and 62"
        exit 1
    fi
}

validate_remote_host() {
    local h=$1
    if [[ ! "$h" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: -r must be a valid hostname or IP address"
        exit 1
    fi
}

validate_base() {
    local b=$1
    if [[ ! "$b" =~ ^(10\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}|192\.168\.[0-9]{1,3})$ ]]; then
        echo "ERROR: -b must be a private RFC1918 address base (e.g. 172.16.0, 10.255.0)"
        exit 1
    fi
}

require_file() {
    local label=$1 path=$2
    if [ ! -f "$path" ]; then
        echo "ERROR: $label not found: $path"
        exit 1
    fi
}

check_key_perms() {
    local key=$1
    local perms
    perms=$(stat -c '%a' "$key")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        echo "ERROR: SSH key has permissions $perms — must be 600 or 400"
        exit 1
    fi
}

parse_targets() {
    local target_file=$1
    ROUTES=()

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" == "0.0.0.0/0" || "$line" == "::/0" ]]; then
            echo "ERROR: Default route $line in target file would override all routing on this host"
            exit 1
        fi
        if [[ "$line" == *"/"* ]]; then
            if [[ ! "$line" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
                echo "ERROR: Invalid CIDR entry in target file: $line"
                exit 1
            fi
            ROUTES["$line"]=1
        else
            if [[ ! "$line" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
                echo "ERROR: Invalid IP entry in target file: $line"
                exit 1
            fi
            local OCTETS="${line%.*}"
            ROUTES["${OCTETS}.0/24"]=1
        fi
    done < "$target_file"
}

tunnel_ips() {
    # Sets LOCAL_IP and REMOTE_IP from TUN_NUM and TUNNEL_REMOTE_BASE.
    # Caller must declare these as local before calling.
    local offset=$((TUN_NUM * 4))
    LOCAL_IP="${TUNNEL_REMOTE_BASE}.$((offset + 1))/30"
    REMOTE_IP="${TUNNEL_REMOTE_BASE}.$((offset + 2))"
}

wait_for_device() {
    local device=$1
    local host=${2:-}
    local key=${3:-}
    local timeout=15
    local elapsed=0

    echo "Waiting for $device to appear${host:+ on remote host}..."
    while [ $elapsed -lt $timeout ]; do
        if [ -n "$host" ]; then
            # shellcheck disable=SC2086
            ssh $SSH_OPTS -i "$key" -o ConnectTimeout=5 root@"$host" \
                "ip link show $device" &>/dev/null && return 0
        else
            ip link show "$device" &>/dev/null && return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "ERROR: $device did not appear after ${timeout} seconds"
    return 1
}

cmd_setup() {
    local OPTIND=1
    while getopts "b:h" opt; do
        case $opt in
            b) TUNNEL_REMOTE_BASE="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    validate_base "$TUNNEL_REMOTE_BASE"

    if ! grep -q "^PermitTunnel yes" /etc/ssh/sshd_config; then
        local BACKUP="/etc/ssh/sshd_config.bak.$(date +%s)"
        cp /etc/ssh/sshd_config "$BACKUP"
        echo "PermitTunnel yes" >> /etc/ssh/sshd_config
        if ! sshd -t 2>/dev/null; then
            cp "$BACKUP" /etc/ssh/sshd_config
            echo "ERROR: sshd config validation failed, reverted. Backup: $BACKUP"
            exit 1
        fi
        systemctl restart sshd
        echo "SSH tunnel support enabled."
    else
        echo "SSH tunnel support already enabled."
    fi

    if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    if ! lsmod | grep -q "^tun "; then
        modprobe tun 2>/dev/null || true
        echo "TUN module loaded."
    fi
    if ! grep -q "^tun" /etc/modules-load.d/tun.conf 2>/dev/null; then
        echo "tun" >> /etc/modules-load.d/tun.conf
        echo "TUN module set to load on boot."
    fi

    local INTERNAL_IF
    INTERNAL_IF=$(ip route | awk '/^default/{print $5; exit}')
    if [[ -z "$INTERNAL_IF" || ! "$INTERNAL_IF" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: Could not determine internal interface from default route"
        exit 1
    fi

    iptables -C FORWARD -i tun+ -o "$INTERNAL_IF" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i tun+ -o "$INTERNAL_IF" -j ACCEPT
    iptables -C FORWARD -i "$INTERNAL_IF" -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$INTERNAL_IF" -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -C POSTROUTING -s "${TUNNEL_REMOTE_BASE}.0/24" -o "$INTERNAL_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "${TUNNEL_REMOTE_BASE}.0/24" -o "$INTERNAL_IF" -j MASQUERADE

    if command -v netfilter-persistent > /dev/null 2>&1; then
        netfilter-persistent save
        echo "iptables rules saved with netfilter-persistent."
    elif command -v iptables-save > /dev/null 2>&1; then
        (umask 077; iptables-save > /etc/iptables.rules)
        if [ ! -f /etc/network/if-pre-up.d/iptables ]; then
            cat > /etc/network/if-pre-up.d/iptables << 'EOF'
#!/bin/bash
iptables-restore < /etc/iptables.rules
EOF
            chmod +x /etc/network/if-pre-up.d/iptables
            echo "iptables rules saved and restore hook created."
        else
            echo "iptables rules saved."
        fi
    else
        echo "WARNING: Could not find netfilter-persistent or iptables-save."
        echo "iptables rules will not persist across reboots."
        echo "Install iptables-persistent: apt install iptables-persistent"
    fi

    echo ""
    echo "============================================"
    echo "  Remote host setup complete"
    echo "============================================"
    echo "  Internal interface: $INTERNAL_IF"
    echo "  Tunnel base:        $TUNNEL_REMOTE_BASE"
    echo "  NAT source range:   ${TUNNEL_REMOTE_BASE}.0/24"
    echo ""
    echo "  NOTE: The tunnel base must not overlap with any"
    echo "  networks being scanned. If it does, re-run setup"
    echo "  with a different base: $0 setup -b <new_base>"
    echo ""
    echo "  On the Nessus host, use the following commands:"
    echo "    sudo ./sshtun.sh up -r <public_ip_of_this_host> -f <target_file> -k /path/to/ssh_key -t <tun_number> [-b $TUNNEL_REMOTE_BASE]"
    echo "    sudo ./sshtun.sh down -f <target_file> -t <tun_number> [-b $TUNNEL_REMOTE_BASE]"
    echo "    sudo ./sshtun.sh cleanup -r <public_ip_of_this_host> -k /path/to/ssh_key -t <tun_number>"
    echo "============================================"
}

cmd_up() {
    local OPTIND=1
    local REMOTE_HOST="" TARGET_FILE="" SSH_KEY="" TUN_NUM=""

    while getopts "r:f:k:t:b:h" opt; do
        case $opt in
            r) REMOTE_HOST="$OPTARG" ;;
            f) TARGET_FILE="$OPTARG" ;;
            k) SSH_KEY="$OPTARG" ;;
            t) TUN_NUM="$OPTARG" ;;
            b) TUNNEL_REMOTE_BASE="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    if [ -z "$REMOTE_HOST" ] || [ -z "$TARGET_FILE" ] || [ -z "$SSH_KEY" ] || [ -z "$TUN_NUM" ]; then
        usage
    fi

    validate_tun_num "$TUN_NUM"
    validate_remote_host "$REMOTE_HOST"
    validate_base "$TUNNEL_REMOTE_BASE"
    require_file "Target file" "$TARGET_FILE"
    require_file "SSH key" "$SSH_KEY"
    check_key_perms "$SSH_KEY"

    local LOCAL_IP REMOTE_IP
    tunnel_ips
    local PID_FILE="/var/run/sshtun-${TUN_NUM}.pid"
    local SSH_PID

    parse_targets "$TARGET_FILE"

    echo "Establishing tunnel to $REMOTE_HOST on tun$TUN_NUM..."
    echo "  Local: $LOCAL_IP  Remote: ${REMOTE_IP}/30"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS -i "$SSH_KEY" -w "$TUN_NUM:$TUN_NUM" -o Tunnel=point-to-point \
        root@"$REMOTE_HOST" -N &
    SSH_PID=$!
    echo "$SSH_PID" > "$PID_FILE"
    disown "$SSH_PID"

    if ! wait_for_device "tun$TUN_NUM"; then
        echo "Failed to establish tunnel. Check SSH connectivity and remote host setup."
        exit 1
    fi

    ip addr add "$LOCAL_IP" dev "tun$TUN_NUM"
    ip link set "tun$TUN_NUM" up

    if ! wait_for_device "tun$TUN_NUM" "$REMOTE_HOST" "$SSH_KEY"; then
        echo "Remote tun device not available. Check remote host configuration."
        exit 1
    fi

    # shellcheck disable=SC2086
    ssh $SSH_OPTS -i "$SSH_KEY" root@"$REMOTE_HOST" \
        "ip addr add ${REMOTE_IP}/30 dev tun$TUN_NUM 2>/dev/null; ip link set tun$TUN_NUM up"

    echo "Verifying remote tunnel endpoint..."
    if ! ping -c 1 -W 3 "$REMOTE_IP" &>/dev/null; then
        echo "WARNING: Cannot reach remote tunnel endpoint $REMOTE_IP"
        echo "Check remote host configuration."
    else
        echo "Remote tunnel endpoint reachable."
    fi

    echo "Adding routes:"
    for net in "${!ROUTES[@]}"; do
        ip route add "$net" via "$REMOTE_IP" dev "tun$TUN_NUM" 2>/dev/null || true
        echo "  $net"
    done

    echo ""
    echo "Verifying routes:"
    local RESULT
    for net in "${!ROUTES[@]}"; do
        RESULT=$(ip route get "${net%%/*}" 2>/dev/null | head -1) || true
        if echo "$RESULT" | grep -qE "\btun${TUN_NUM}\b"; then
            echo "  $net -> OK"
        else
            echo "  $net -> WARNING: not routing through tun$TUN_NUM"
            echo "    Actual: $RESULT"
        fi
    done

    echo ""
    echo "Tunnel is up on tun$TUN_NUM. Use $TARGET_FILE as your Nessus target list."
}

cmd_down() {
    local OPTIND=1
    local TARGET_FILE="" TUN_NUM=""

    while getopts "f:t:b:h" opt; do
        case $opt in
            f) TARGET_FILE="$OPTARG" ;;
            t) TUN_NUM="$OPTARG" ;;
            b) TUNNEL_REMOTE_BASE="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    if [ -z "$TARGET_FILE" ] || [ -z "$TUN_NUM" ]; then
        usage
    fi

    validate_tun_num "$TUN_NUM"
    validate_base "$TUNNEL_REMOTE_BASE"
    require_file "Target file" "$TARGET_FILE"

    local LOCAL_IP REMOTE_IP
    tunnel_ips
    local PID_FILE="/var/run/sshtun-${TUN_NUM}.pid"

    parse_targets "$TARGET_FILE"

    for net in "${!ROUTES[@]}"; do
        ip route del "$net" via "$REMOTE_IP" 2>/dev/null || true
    done

    ip link delete "tun$TUN_NUM" 2>/dev/null || true

    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    else
        pkill -f "ssh.*-w ${TUN_NUM}:${TUN_NUM}" 2>/dev/null || true
    fi

    echo "Tunnel tun$TUN_NUM torn down."
}

cmd_cleanup() {
    local OPTIND=1
    local REMOTE_HOST="" SSH_KEY="" TUN_NUM=""

    while getopts "r:k:t:h" opt; do
        case $opt in
            r) REMOTE_HOST="$OPTARG" ;;
            k) SSH_KEY="$OPTARG" ;;
            t) TUN_NUM="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    if [ -z "$REMOTE_HOST" ] || [ -z "$SSH_KEY" ] || [ -z "$TUN_NUM" ]; then
        usage
    fi

    validate_tun_num "$TUN_NUM"
    validate_remote_host "$REMOTE_HOST"
    require_file "SSH key" "$SSH_KEY"
    check_key_perms "$SSH_KEY"

    echo "Cleaning up remote host $REMOTE_HOST tun$TUN_NUM..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -i "$SSH_KEY" root@"$REMOTE_HOST" "\
        ip link delete tun$TUN_NUM 2>/dev/null && \
            echo '  tun$TUN_NUM removed.' || \
            echo '  tun$TUN_NUM not found, nothing to clean up.'"

    echo "Remote cleanup complete."
}

# Main
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

COMMAND=$1
shift

check_root

case $COMMAND in
    setup)   cmd_setup "$@" ;;
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    *)       usage ;;
esac
