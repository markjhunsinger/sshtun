#!/bin/bash
# sshtun.sh

TUNNEL_REMOTE_BASE="172.16.0"

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
    echo "  Show help:"
    echo "    $0 -h"
    echo ""
    echo "Options:"
    echo "  -r    Remote host public IP (required for up)"
    echo "  -f    Target file containing IPs/ranges, one per line (required for up/down)"
    echo "  -k    SSH private key path (required for up)"
    echo "  -t    Tunnel device number, e.g. 0, 1, 2 (required for up/down)"
    echo "        Each tester must use a unique number"
    echo "  -b    Tunnel IP base (optional, default: 172.16.0)"
    echo "  -h    Show this help message"
    echo ""
    echo "NOTE: The tunnel base (-b) must not conflict with any IP ranges being"
    echo "scanned. For example, if scanning 172.16.x.x networks, use a different"
    echo "base such as 10.255.0 to avoid routing conflicts."
    echo ""
    echo "Examples:"
    echo "  Remote host setup (run once):"
    echo "    $0 setup"
    echo "    $0 setup -b 10.255.0"
    echo ""
    echo "  Tester 1 brings up tunnel and scans:"
    echo "    $0 up -r 203.0.113.50 -f targets.txt -k ~/.ssh/client_key -t 0"
    echo "    $0 down -f targets.txt -t 0"
    echo ""
    echo "  Tester 2 brings up tunnel with custom base:"
    echo "    $0 up -r 203.0.113.50 -f targets.txt -k ~/.ssh/client_key -t 1 -b 10.255.0"
    echo "    $0 down -f targets.txt -t 1 -b 10.255.0"
    exit 0
}

parse_targets() {
    local target_file=$1
    declare -gA ROUTES

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" == *"/"* ]]; then
            ROUTES["$line"]=1
        else
            OCTETS=$(echo "$line" | cut -d'.' -f1-3)
            ROUTES["${OCTETS}.0/24"]=1
        fi
    done < "$target_file"
}

cmd_setup() {
    while getopts "b:h" opt; do
        case $opt in
            b) TUNNEL_REMOTE_BASE="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    # Enable tunnel support in SSH
    if ! grep -q "^PermitTunnel yes" /etc/ssh/sshd_config; then
        echo "PermitTunnel yes" >> /etc/ssh/sshd_config
        systemctl restart sshd
        echo "SSH tunnel support enabled."
    else
        echo "SSH tunnel support already enabled."
    fi

    # Enable IP forwarding (persistent)
    if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1

    # Get internal-facing interface
    INTERNAL_IF=$(ip route | grep default | awk '{print $5}')

    # Allow forwarding and NAT for the whole tunnel range
    iptables -A FORWARD -i tun+ -o $INTERNAL_IF -j ACCEPT
    iptables -A FORWARD -i $INTERNAL_IF -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -A POSTROUTING -s ${TUNNEL_REMOTE_BASE}.0/24 -o $INTERNAL_IF -j MASQUERADE

    # Persist iptables rules
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
        echo "iptables rules saved with netfilter-persistent."
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables.rules
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
    echo "    ./sshtun.sh up -r <public_ip_of_this_host> -f <target_file> -k <ssh_key> -t <tun_number> [-b $TUNNEL_REMOTE_BASE]"
    echo "    ./sshtun.sh down -f <target_file> -t <tun_number> [-b $TUNNEL_REMOTE_BASE]"
    echo "============================================"
}

cmd_up() {
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

    if [ ! -f "$TARGET_FILE" ]; then
        echo "Target file not found: $TARGET_FILE"
        exit 1
    fi

    if [ ! -f "$SSH_KEY" ]; then
        echo "SSH key not found: $SSH_KEY"
        exit 1
    fi

    OFFSET=$((TUN_NUM * 4))
    LOCAL_IP="${TUNNEL_REMOTE_BASE}.$((OFFSET + 1))/30"
    REMOTE_IP="${TUNNEL_REMOTE_BASE}.$((OFFSET + 2))"
    REMOTE_IP_CIDR="${REMOTE_IP}/30"

    parse_targets "$TARGET_FILE"

    # Bring up the tunnel
    echo "Establishing tunnel to $REMOTE_HOST on tun$TUN_NUM..."
    echo "  Local: $LOCAL_IP  Remote: $REMOTE_IP_CIDR"
    ssh -i "$SSH_KEY" -w "$TUN_NUM:$TUN_NUM" -o Tunnel=point-to-point root@$REMOTE_HOST -N -f
    sleep 2

    # Configure local side
    ip addr add "$LOCAL_IP" dev "tun$TUN_NUM"
    ip link set "tun$TUN_NUM" up

    # Configure remote side
    ssh -i "$SSH_KEY" root@$REMOTE_HOST \
        "ip addr add $REMOTE_IP_CIDR dev tun$TUN_NUM && ip link set tun$TUN_NUM up"

    # Add routes
    echo "Adding routes:"
    for net in "${!ROUTES[@]}"; do
        ip route add "$net" via "$REMOTE_IP" 2>/dev/null
        echo "  $net"
    done

    echo ""
    echo "Tunnel is up on tun$TUN_NUM. Use $TARGET_FILE as your Nessus target list."
}

cmd_down() {
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

    if [ ! -f "$TARGET_FILE" ]; then
        echo "Target file not found: $TARGET_FILE"
        exit 1
    fi

    OFFSET=$((TUN_NUM * 4))
    REMOTE_IP="${TUNNEL_REMOTE_BASE}.$((OFFSET + 2))"

    parse_targets "$TARGET_FILE"

    for net in "${!ROUTES[@]}"; do
        ip route del "$net" via "$REMOTE_IP" 2>/dev/null
    done

    ip link set "tun$TUN_NUM" down
    ip addr flush dev "tun$TUN_NUM"
    pkill -f "ssh -w $TUN_NUM:$TUN_NUM"

    echo "Tunnel tun$TUN_NUM torn down."
}

# Main
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

COMMAND=$1
shift

case $COMMAND in
    setup) cmd_setup "$@" ;;
    up)    cmd_up "$@" ;;
    down)  cmd_down "$@" ;;
    *)     usage ;;
esac
