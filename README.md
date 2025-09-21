## Parameters
- `--help` - help message
- `--host[=]<ip_addr>` - servers endpoint
- `--port[=]<port>` - port which vpn will be use to listen connections
- `--network[=]<subnet_network>` - vpn network
- `--peers[=]<peers_number>` - number of client peers

All params are optional 
## Default values
- host=`culr https://ifconfig.me` - public ip address of host 
- port=`51820` - deafult wireguard port
- network=`10.0.0.0/8`
- peers=`1`

## Exit statuses

- `0` - success
- `1` - unknown param
- `2` - failed to parse param
- `3` - host address doesn't belong to any adapter
- `4` - port ain't a number
- `5` - port is in user
- `6` - network doesn't match pattern
- `7` - peers number is too large to the given network
- `8` - some networks octet ain't in range 0..255(first one 1..255)
- `9` - host bits are set in the network field(invalid network mask)

