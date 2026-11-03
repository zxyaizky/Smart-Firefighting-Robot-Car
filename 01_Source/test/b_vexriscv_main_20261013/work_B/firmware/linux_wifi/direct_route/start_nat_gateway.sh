#!/bin/sh
set -eu
ip link set lo up
ip link set eth0 up
udhcpc -i eth0 -q
printf 'http://10.0.2.2:18990/apk/v3.22/main\nhttp://10.0.2.2:18990/apk/v3.22/community\n' >/etc/apk/repositories
apk add --no-progress --no-cache python3 ppp iptables
modprobe ppp_async
modprobe iptable_nat
echo 1 >/proc/sys/net/ipv4/ip_forward
# QEMU hostfwd reaches eth0:2222. Kernel NAT forwards to PPP with no TCP relay.
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 2222 -j DNAT --to-destination 192.168.11.2:2222
iptables -t nat -A POSTROUTING -o ppp0 -p tcp -d 192.168.11.2 --dport 2222 -j SNAT --to-source 192.168.11.1
mkdir -p /build
modprobe ext4
blkid /dev/vda | grep -q 'LABEL="ANLU_BUILD"'
mountpoint -q /build || mount -t ext4 /dev/vda /build
wget -q -O /tmp/entropy_native.py http://10.0.2.2:18990/entropy_native.py
python3 /tmp/entropy_native.py >/build/wifi/out/entropy_native.log 2>&1 &
echo $! >/run/wifi-test-entropy.pid
pppd pty 'nc 10.0.2.2 18992' 115200 local noauth nocrtscts 192.168.11.1:192.168.11.2 \
    nodetach persist maxfail 0 holdoff 3 noccp novj nobsdcomp nodeflate mtu 576 mru 576 \
    debug logfile /build/wifi/out/ppp_server.log >/build/wifi/out/ppp_server_console.log 2>&1 &
echo $! >/run/wifi-test-server.pid
echo NATIVE_PPP_GATEWAY_STARTED
