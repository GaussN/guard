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
EOF
    exit 0
fi


exec 3>/dev/null
debug() {
    echo -e "$*" >&3
}
if [[ -n "${DEBUG}" ]]; then 
    exec 3>&1 
fi


# MAIN 
# PREPAIRING
if [[ `whoami` != 'root' ]]; then 
    echo "You have to be root to execute this script.">&2
    exit 1
fi
utils=("ss" "ip" "wg" "nft")
missing=''
for util in "${utils[@]}"; do 
    if [[ ! `command -v $util >&3` ]]; then
        missing="$util $missing"
    fi
done
if [[ -n missing ]]; then 
    echo -e "The script need some utilities to work: ${missing}">&2
    exit 1
fi

utils_file="ip-utils.sh" 
if [[ ! ( -f "$utils_file" ) ]]; then
    echo "Noutils (">&2
    exit 1
fi
cksm="1f5e7cff40bc3a2f25b79845b00ddb75  ip-utils.sh"
if ! ( echo "$cksm" | md5sum -c - 2>&3 ); then 
    echo "MD5 sum for $utils_file isn't valid.">&2
    exit 1
fi


while [[ -n $1 ]]; do
    if [[ -v params[${1#--}] ]]; then 
        flag="${1#--}"
        shift 
        params[$flag]="$1"
    else 
        echo "$1 - invalid param.">&2
        exit 1 
    fi
done

if [[ -z "${params[host]}" ]]; then
    params["host"]=`curl -s https://ifconfig.me 2>&3`
    if [[ $? -ne 0 ]]; then
        echo "Host doesn't specified and can not be derived.">&2
        exit 1
    fi
fi

# VALIDATE 
# HOST 
ip -brief addr | awk '{ print $3 }' | grep "${param[host]}" 1>/dev/null 2>&3
if [[ $? -ne 0 ]]; then
    echo "${param[host]} doesn't belong to any adapter.">&2
    exit 2
fi

# PORT 
ss -lun | awk '{ print $4 }' | grep ":${param[host]}$" 1>/dev/null 2>&3
if [[ $? -ne 0 ]]; then 
    echo "${param[port]} is busy.">&2
    exit 2 
fi

set +e 
# NETWORK 
source "$utils_file" 
mapfile -d' ' network_tuple < <(ip::parse "${param[network]}" 2>&2)  # explicity )
ip::validate_network "${network_tuple[@]}"


# PEERS 
ip::validate_peers_number "${network_tuple[5]}" "${params[peers]}"

set -e
# INTERFACE 
ip -brief link | awk '{ print $1}' | grep "${params[interface]}" 1>/dev/null 2>&3
if [[ $? -eq 0 ]]; then 
    echo "${params[interface]} already exists.">&2
    exit 2
fi

# SETING UP
exit 0


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
