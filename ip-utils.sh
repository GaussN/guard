#!/bin/bash

ip::parse() {
    # args: "255.255.255.255[/32]"
    if [[ -z "$1" ]]; then
        return 1
    fi
    if [[ ! "$1" =~ ([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(/[0-9]+)? ]]; then 
        echo "$1 is not an ip address.">&2
        return 2
    fi
    o1="${BASH_REMATCH[1]}"
    o2="${BASH_REMATCH[2]}"
    o3="${BASH_REMATCH[3]}"
    o4="${BASH_REMATCH[4]}"
    mask="${BASH_REMATCH[5]:-32}"
    echo -n "$o1" "$o2" "$o3" "$o4" "${mask#/}"
    return 0
}


ip::validate_network() {
    # desc: check if address is a correct network address 
    # args: o1 o2 o3 o4 mask  # <o1.o2.o3.o4/mask>
    if [[ $# -ne 5 ]]; then 
        echo "Invalid number of arguments.">&2
        return 1
    fi
    o1=$1
    o2=$2
    o3=$3
    o4=$4
    mask=$5
    if [[ $o1 -eq 0 ]]; then
        echo "First octet can not be equal 0.">&2
        return 1
    fi
    if [[ $mask -lt 1 || $mask -gt 30 ]]; then
        echo "Mask is invlaid.">&2
        return 2
    fi
    for octet in $o1 $o2 $o3 $o4; do
        if [[ ! ($octet -ge 0 && $octet -lt 255) ]]; then
            echo "$octet - invalid octet.">&2
            return 1
        fi
    done
    number_view=$(( o4 + (o3 << 8) + (o2 << 16) + (o1 << 24) ))
    address_mask=0
    for ((i=0; i<(32-mask); i++)); do 
        address_mask=$((1 + (address_mask<<1)))
    done
    # printf "%32s\n" $(echo "obase=2;$number_view" | bc)
    # printf "%32s\n" $(echo "obase=2;$address_mask" | bc)
    if [[ $(( number_view & address_mask )) -ne 0 ]]; then
        echo "Address doesn't fit to given mask.">&2
        return 2
    fi
    return 0
}

ip::validate_peers_number() {
    # desc: check if mask alllow to have enought addresses
    #       +1 address for server
    #       +1 for .255
    #       +1 for .0
    # args: mask peers_number
    mask=$1
    peers=$2
    if [[ $((2**(32-mask) - 3)) -lt $peers ]]; then
        echo "Peers don't fit to given mask.">&2
        return 1
    fi
    return 0
}

