#!/bin/bash
    
# CONFIG:
SERVER_ENDPOINT="1.1.1.1" # $(curl ifconfig.me)
SERVER_ADDR="172.16.0.1"
SERVER_GATEWAY="eth0"

declare -A NETWORKS=(
    ["172.16.0.<>"]="$(seq 2 10)"
    ["172.16.1.<>"]="$(seq 32 48)"
)


# gen server base config 
server_key=$(wg genkey)
server_pub=$(echo "$server_key" | wg pubkey)

cat <<EOF > server.conf
[Interface]
PrivateKey = ${server_key}
Address = ${SERVER_ADDR}/32
ListenPort = 51820
PostUp = nft create table ip wireguard
PostUp = nft "add chain ip wireguard postrouting { type nat hook postrouting priority srcnat; policy accept; }"
PostUp = nft add rule ip wireguard postrouting oifname "${SERVER_GATEWAY} masquerading"
PostDown = nft delete table ip wireguard
EOF


# gen client configs 
WD="$(pwd)"
mkdir clients
cd clients

for subnet in "${!NETWORKS[@]}"; do
    mkdir "$subnet"
    for peer_n in ${NETWORKS[$subnet]}; do
        peer_ip=$(echo "$subnet" | sed "s/<>/${peer_n}/")

        client_key="$(wg genkey)"
        client_pub="$(echo "$client_key" | wg pubkey)"

        # user config
        cat <<EOF > "${subnet}/wg${peer_ip}.conf"
[Interface]
PrivateKey = ${client_key}
Address = ${peer_ip}/24
DNS = 8.8.8.8, 8.8.4.4
[Peer]
PublicKey = ${server_pub}
AllowedIPs = 0.0.0.0/0
Endpoint = ${SERVER_ENDPOINT}:51820
PersistentKeepalive = 25
EOF

cat <<EOF >> "${WD}/server.conf"
[Peer]
AllowedIPs = ${peer_ip}/32
PublicKey = ${client_pub}
EOF
    done
done
