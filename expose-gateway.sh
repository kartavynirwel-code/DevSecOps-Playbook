#!/usr/bin/env bash
# expose-gateway.sh: expose the Envoy gateway on node port 80
set -euo pipefail

GW=${1:-172.18.0.3}   # gateway IP, argument se bhi de sakte ho
PORT=80

sysctl -w net.ipv4.ip_forward=1

iptables -t nat -C PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $GW:$PORT 2>/dev/null \
  || iptables -t nat -I PREROUTING 1 -p tcp --dport $PORT -j DNAT --to-destination $GW:$PORT

iptables -t nat -C POSTROUTING -d $GW -p tcp --dport $PORT -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -d $GW -p tcp --dport $PORT -j MASQUERADE

iptables -C DOCKER-USER -d $GW -p tcp --dport $PORT -j ACCEPT 2>/dev/null \
  || iptables -I DOCKER-USER 1 -d $GW -p tcp --dport $PORT -j ACCEPT

iptables -C DOCKER-USER -s $GW -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -I DOCKER-USER 1 -s $GW -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "Done. Test from outside: curl -I http://<public-ip>/"
