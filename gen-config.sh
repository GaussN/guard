#!/bin/bash
INFO="USAGE\n"
INFO+="\t$0 [params]\n"
INFO+="PARAMS\n"
INFO+="\t--help - see this message\n"
INFO+="\t--host[=]<ip_addr> - servers endpoint\n"
INFO+="\t--port[=]<port> - port which vpn will be use to listen connections\n"
INFO+="\t--network[=]<subnet_network> - vpn network\n"
INFO+="\t--peers[=]<peers_number> - number of client peers\n"
INFO+="\n"

if [[ "$@" =~ \s?--help\s? ]]; then
    echo -e "${INFO}"
    exit 0
fi

DEFAULT_HOST=$(curl -s https://ifconfig.me)
DEFAULT_PORT=51820
DEFAULT_NETWORK="10.0.0.0/8"
DEFAULT_PEERS=1
DEFAULT_DNS="8.8.8.8, 8.8.4.4"

SERVER_CONFIG_DIR="/etc/wireguard"
SERVER_CONFIG_FILE="server.conf"
SERVER_PRV_FILE="key"
SERVER_PUB_FILE="key.pub"
CLIENTS_CONFIG_DIR="${SERVER_CONFIG_DIR}/clients"
CLIENT_CONFIG_FILE="vpn.conf"
CLIENT_PRV_KEY="key"
CLIENT_PUB_KEY="key.pub"

declare -A params
params["host"]="${DEFAULT_HOST}"
params["port"]="${DEFAULT_PORT}"
params["network"]="${DEFAULT_NETWORK}"
params["peers"]="${DEFAULT_PEERS}"
params["dns"]="${DEFAULT_DNS}"


debug() {
    : 
}
if [[ -n "$(printenv DEBUG)" ]]; then 
    debug() {
        echo -e "$*" >&2
    }
fi


# CMD
split_param() {
    local param="$1"
    if [[ "$param" =~ (.+)=(.+) ]]; then 
        echo "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else 
        exit 2
    fi
}


set_param() {
    local flag="${1#--}"
    local value="$2"
    debug "${flag} = ${value}"
    case "${flag}" in
        host | \
        port | \
        network | \
        peers)
            params[$flag]="${value}"
        ;;
        *)
            echo "Unknown argument - ${flag}=${value}" >&2
            exit 1
        ;;
    esac
}


parse_args() {
    # args: "$@" - cmd args
    while [[ -n "$1" ]]; do
        if [[ "$1" =~ "=" ]]; then 
            flag_value=$(split_param "$1")
            if [[ "$?" -eq 2 ]]; then 
                echo "Issue while parse params with =" >&2
                exit 2
            fi
            flag="${flag_value[0]}"
            value="${flag_value[1]}"
            shift
        else
            flag="$1"
            shift 
            value="$1"
            shift
        fi
        set_param "$flag" "$value"
    done
}


validate_params() {
    # validate host
    # if address doesn't belong to any adapter 
    if [[ ! $(ip -brief addr | grep "${params[host]}/") ]]; then
        echo "Invalid host address" >&2
        exit 4
    fi
    #######################################################################
    # validate vpn port
    if [[ ! ("${params[port]}" =~ [1-9][0-9]?+ ) ]]; then 
        echo "Port ain't a number" >&2
        exit 5
    fi
    # check only udp
    if [[ $(ss -lun | grep ":${params[port]}\s") ]]; then 
        echo "Port in use. Try another one" >&2
        exit 6
    fi
    #######################################################################
    # validate network and peers
    if [[ ! ("${params[network]}" =~ ([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]{1,2}) ) ]]; then 
        echo "Invalid network mask" >&2
        exit 7
    else 
        # check if peers number is fits in the given subnet
        local subnet_mask="${BASH_REMATCH[5]}"
        # client peers + host peer 
        if [[ $(( 2 ** (32 - subnet_mask) - 2 )) -lt $(( params[peers] + 1 )) ]]; then 
            echo "Peers number doesn't fits in given subnet" >&2
            exit 8
        fi
        # check if subnet contains bits outside the mask
        local o_3="${BASH_REMATCH[1]}"
        local o_2="${BASH_REMATCH[2]}"
        local o_1="${BASH_REMATCH[3]}"
        local o_0="${BASH_REMATCH[4]}"
        if [[ $o_3 -le 0 || $o_3 -ge 255 ]]; then 
            echo "Invalid network octet 1" >&2 
            exit 9
        fi 
        if [[ $o_2 -lt 0 || $o_2 -ge 255 ]]; then 
            echo "Invalid network octet 2" >&2 
            exit 9
        fi 
        if [[ $o_1 -lt 0 || $o_1 -ge 255 ]]; then 
            echo "Invalid network octet 3" >&2 
            exit 9
        fi 
        if [[ $o_0 -lt 0 || $o_0 -ge 255 ]]; then 
            echo "Invalid network octet 4" >&2 
            exit 9
        fi 
        local subnet_network=$(( o_0 + (o_1 << (8*1)) + (o_2 << (8*2)) + (o_3 << (8*3)) ))
        local mi=$(( 32 - ${subnet_mask} ))  # mask iterator
        local wildcard_bits=0
        while [[ $mi -gt 0 ]]; do
            wildcard_bits=$(( (wildcard_bits << 1) + 1))
            mi=$(( mi - 1 ))
        done
        if [[ $(( subnet_network & wildcard_bits )) -ne 0 ]]; then 
            echo "Network contains bits outside the mask" >&2
            exit 9 
        fi
    fi
}


# UTILS
parse_ip() {
    local address="$1"
    if [[ ! "$address" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]{1,2})$ ]]; then
        return 1
    fi
    octet_0="${BASH_REMATCH[4]}"
    octet_1="${BASH_REMATCH[3]}"
    octet_2="${BASH_REMATCH[2]}"
    octet_3="${BASH_REMATCH[1]}"
    mask="${BASH_REMATCH[5]}"
    echo $octet_0 $octet_1 $octet_2 $octet_3 $mask
}

gen_peers() {
    local network="$1"
    local peers_number="$2"
    local peers=()
    local parsed_network=($(parse_ip "${network}"))
    local mask="${parsed_network[4]}"
    network=$(( parsed_network[0] + (parsed_network[1] << 8) + (parsed_network[2] << (8*2)) + (parsed_network[3] << (8*3)) ))
    local -i peer_i=0
    while [[ $peer_i -lt $peers_number ]]; do
        local peer_addr=$(( network + peer_i + 1 ))
        local o_0=$(( peer_addr & 255 ))
        local o_1=$(( (peer_addr >> 8) & 255 ))
        local o_2=$(( (peer_addr >> (8*2)) & 255 ))
        local o_3=$(( (peer_addr >> (8*3)) & 255 ))
        peers+=("${o_3}.${o_2}.${o_1}.${o_0}/${mask}")
        peer_i+=1
    done
    echo "${peers[@]}"
}


# VPN
create_server_config() {
    local address="$1"
    local config="${SERVER_CONFIG_DIR}/${SERVER_CONFIG_FILE}"
    if [[ -f "${config}" ]]; then
        mv "${config}" "${config}.$(date -u '+%s')" 
    fi

    local server_prv=$(wg genkey)
    local server_pub=$(echo "$server_prv" | wg pubkey)
    # check oifname != %i
    cat <<EOF > "${config}"
[Interface]
PrivateKey = ${server_prv}
Address = ${address/\/[0-9]*/\/32}
ListenPort = ${params[port]}

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft create table ip wireguard
PostUp = nft "add chain ip wireguard postrouting { type nat hook postrouting priority srcnat; policy accept; }"
PostUp = nft add rule ip wireguard postrouting iifname %i oifname != %i masquerade

PostDown = sysctl -w net.ipv4.ip_forward=0
PostDown = nft delete table ip wireguard

EOF

    echo "${server_pub}"
}


create_client_config() {
    local address="$1"    
    local server_pub="$2"
    local config_dir="${CLIENTS_CONFIG_DIR}/${address/\/[0-9]*/}"
    mkdir -p "${config_dir}"

    local client_prv=$(wg genkey)
    echo "${client_prv}" > "${config_dir}/${CLIENT_PRV_KEY}"
    local client_pub=$(echo "$client_prv" | wg pubkey)
    echo "${client_pub}" > "${config_dir}/${CLIENT_PUB_KEY}"

    cat <<EOF > "${config_dir}/${CLIENT_CONFIG_FILE}"
[Interface]
PrivateKey = ${client_prv}
Address = ${address}
DNS = 8.8.8.8, 8.8.4.4
[Peer]
PublicKey = ${server_pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${params[host]}:${params[port]}
PersistentKeepalive = 25
EOF

    cat <<EOF >> "${SERVER_CONFIG_DIR}/${SERVER_CONFIG_FILE}"
[Peer]
AllowedIPs = ${address/\/[0-9]*/\/32}
PublicKey = ${client_pub}
EOF
}


main() {
    # args: "$@" - cmd args
    parse_args "$@"
    validate_params
    # client peers + host peer
    local peers=($(gen_peers "${params[network]}" $((params[peers] + 1))))
    echo "peers: ${peers[@]}"


    local server_pub=$(create_server_config "${peers[0]}")
    local -i peer_i=1
    while [[ "$peer_i" -lt "${#peers[@]}" ]]; do
        create_client_config "${peers[$peer_i]}" "$server_pub"
        peer_i+=1
    done

    exit 0
}


main "$@"

