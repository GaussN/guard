#!/bin/bash

declare -A params
params["host"]=''
params["port"]=51820
params["network"]='172.20.0.0/16'
params["peers"]=1
params["dns"]='8.8.8.8, 8.8.4.4'
params["interface"]='vpn0'


if [[ "$@" =~ \s?--help\s? || !( "$@" =~ \s?--run\s? ) ]]; then
    cat <<EOF 
USAGE
    $0 [params]
PARAMS
    --help - see this message
    --run - run script

    --host <ip_addr> servers endpoint
                     default: \`curl -s https://ifconfig.me\`
    --port <port> port which vpn will be use to listen connections
                     default: ${params["port"]}
    --network <subnet_network> vpn network
                     default: ${params["network"]}
    --peers <peers_number> number of client peers
                     default: ${params["peers"]}
    --interface <interface_name> wireguard interface name
                     default: ${params["interface"]}
TEST VARAIBLES 
    - DEBUG             
        Script will print debug messages if set.
    - DISABLE_ROOT_CHECK
        Script won't check if user is root.
    - DISABLE_IP_CHECK 
        The scipt won't check if ip belongs to any adapter.
    - VALIDATE_ONLY 
        Script stop execution after validating params.
EOF
    exit 0
fi


exec 3>/dev/null
debug() {
    echo -e $* >&3
}
if [[ -v DEBUG ]]; then 
    exec 3>&1 
fi
debug "DEBUG MODE"


# MAIN 
# PREPAIRING
if [[ `whoami` != 'root' && !( -v DISABLE_ROOT_CHECK ) ]]; then 
    echo "You have to be root to execute this script.">&2
    exit 1
fi
#
utils=("ss" "ip" "wg" "nft")
declare -a missing
for util in "${utils[@]}"; do 
    debug -n "Ckecking $util "
    if ! command -v $util &>/dev/null; then
        missing=($missing "$util")
		debug -n " - missing"
    fi
	debug
done
if [[ "${#missing}" -ne 0 ]]; then 
    echo -e "The script need some utilities to work: ${missing}">&2
    exit 1
fi
#
utils_file="ip-utils.sh" 
if [[ ! ( -f "$utils_file" ) ]]; then
    echo "Noutils (">&2
    exit 1
fi

cksm="279857a5a71952b2ff5f126d184d0d4d  ip-utils.sh"
if ! $(md5sum -c <(echo "$cksm") 1>/dev/null 2>&3); then 
    echo "MD5 sum for $utils_file isn't valid.">&2
    exit 1
fi
#
while [[ -n $1 ]]; do
    if [[ -v params[${1#--}] ]]; then 
        flag="${1#--}"
        shift 
        params[$flag]="$1"
		debug "$flag overrided to \"$1\""
    else 
        case "$1" in
        --run) ;;
        *) 
            echo "\"$1\" - invalid param.">&2
            exit 1 
        ;;
        esac
    fi
    shift 
done
#
if [[ -z "${params[host]}" ]]; then
	debug "Try to derive host address"
    params["host"]=`curl -s https://ifconfig.me 2>&3`
    if [[ $? -ne 0 ]]; then
        echo "Host doesn't specified and can not be derived.">&2
        exit 1
    fi
fi
# VALIDATE
if [[ -v DEBUG ]]; then 
    debug "PARAMS: "
    for key in "${!params[@]}"; do
        debug "[${key}]=${params[$key]}"
    done
fi
# HOST 
ip -brief addr | awk '{ print $3 }' | grep "${params[host]}" 1>/dev/null 2>&3
if [[ $? -ne 0 && !( -v DISABLE_IP_CHECK ) ]]; then
    echo "${param[host]} doesn't belong to any adapter.">&2
    exit 2
fi

# PORT 
ss -lunH | awk '{ print $4 }' | grep ":${params[port]}$" 1>&3 2>&3
if [[ $? -eq 0 ]]; then 
    echo "${params[port]} is busy.">&2
    exit 2 
fi

set -e 
# NETWORK 
source "$utils_file" 
mapfile -d' ' -t network_tuple < <(ip::parse "${params[network]}" 2>&2)  # convert output "o1 o2 o3 o4 m" to array
ip::validate_network ${network_tuple[@]}

# PEERS 
# BUG: 
ip::validate_peers_number "${network_tuple[5]}" "${params[peers]}"

set +e
# INTERFACE 
ip -brief link | awk '{ print $1}' | grep "${params[interface]}" 1>/dev/null 2>&3
if [[ $? -eq 0 ]]; then 
    echo "${params[interface]} already exists.">&2
    exit 2
fi

if [[ -v VALIDATE_ONLY ]]; then 
    echo "Validation has finished"
    exit 0
fi
echo "Start configuration"
# SETING UP
set -e

function _try() {
	WDIR="/etc/wireguard"
	CDIR="${WDIR}/guard"
	if [[ -d "${CDIR}" ]]; then
	    mv "${CDIR}" "${CDIR}.$(date '+%s')-back"
	fi
	mkdir -p "${CDIR}/clients"
	cd "${CDIR}"

	wg genkey | tee key | wg pubkey > key.pub 
	debug "Server keys have generated"

	# network_tuple [1].[2].[3].[4]/[5]
	address_num=$(( (network_tuple[0]<<24)+(network_tuple[1]<<16)+(network_tuple[2]<<8)+(network_tuple[3]) ))
	address_num=$(( address_num + 1 ))
	debug "Server address in numeric view: ${address_num}"

	# TODO : modprobe masquerading 
	cat <<EOF > nft_postup.rules
table ip wireguard {
	chain postrouting {
	type nat hook postrouting priority srcnat; policy accept;
	iifname $int oifname != $int masquerade 
	}
}
EOF
	debug "nft post up script has generated"

	cat <<EOF > nft_postdown.rules
destroy table ip wireguard
EOF
	debug "nft post down script has generated"

	cat <<EOF > "${CDIR}/config"
[Interface]
PrivateKey = $(cat "${CDIR}/key")
Address = $(ip::to_str_view address_num)/32
ListenPort = ${params[port]}
PostUp = sysctl -w net.ipv4.if_forward=1
PostUp = nft -f "${CDIR}/nft_postup.rules" -D int="%i"
PostDown = sysctl -w net.ipv4.if_forward=0
PostDown = nft -f "${CDIR}/nft_postdown.rules"
EOF
	debug "Server wg config has generated"

	ln -sf "${CDIR}/config" "${WDIR}/${params[interface]}.conf" 
	debug "Link "${WDIR}/${params[interface]}.conf" to server config has generated"

	ip link add "${params[interface]}" type wireguard
	ip addr add dev "${params[interface]}" "$(ip::to_str_view address_num)"
	ip link set "${params[interface]}" up

	for ((i=0; i < params[peers]; i++)); do
	    debug "generate peer ${i}"
	    address_num=$(( address_num + 1 ))

	    key=$(wg genkey)
	    addr=$(ip::to_str_view address_num)

	    cat <<EOF > "${CDIR}/clients/${addr}.conf"
[Interface]
PrivateKey = ${key}
Address = ${addr}/32
DNS = ${params[dns]}
[Peer]
PublicKey = $(cat "${CDIR}/key.pub")
Endpoint = ${params[host]}:${params[port]}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

	    wg set peer "$(echo $key | wg pubkey)" allower-ips "${addr}/32"
	done

	wg addconf "${params[interface]}" "${WDIR}/${params[interface]}.conf" 
	wg syncconf "${params[interface]}" "${CDIR}/config"
}

if ! _try; then
	:  # catch block 
	ip link del "${params[interface]}"
fi



# SERVER:
# [Interface]
# PrivateKey = <>
# Address = <>
# ListenPort = <>
#
# PostUp = sysctl -w net.ipv4.ip_forward=1
# PostUp = nft create table ip wireguard
# PostUp = nft "add chain ip wireguard postrouting { type nat hook postrouting priority srcnat; policy accept; }"
# PostUp = nft add rule ip wireguard postrouting iifname %i oifname != %i masquerade
# PostDown = sysctl -w net.ipv4.ip_forward=0
# PostDown = nft delete table ip wireguard
#
# [Peer]
# AllowedIPs = 0.0.0.0/32
# PublicKey = <>
#

# CLIENT:
# [Interface]
# PrivateKey = <>
# Address = <>
# DNS = <>
# [Peer]
# PublicKey = <>
# AllowedIPs = 0.0.0.0/0
# Endpoint = <>
# PersistentKeepalive = 25
#
