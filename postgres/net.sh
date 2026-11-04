#!/bin/bash
# Network simulation with tc netem, only on this container's replication-network interface
# (172.30.20.0/24). The app's traffic (app_net) is not touched.
#   net.sh delay 10ms                -> netem delay on this interface's egress
#   net.sh delay 1000ms limit 100000    (bigger queue, for a long delay without drops)
#   net.sh clear                     -> removes the rule
#   net.sh show                      -> tc qdisc show
set -euo pipefail

PREFIX="${REPLICATION_NET_PREFIX:-172.30.20.}"
IFACE=$(ip -o -4 addr show | awk -v p="$PREFIX" 'index($4, p) == 1 { print $2; exit }')
[ -n "$IFACE" ] || { echo "no interface on the replication network ($PREFIX)" >&2; exit 1; }

case "${1:-show}" in
  delay) shift; tc qdisc replace dev "$IFACE" root netem delay "$@" ;;
  clear) tc qdisc del dev "$IFACE" root 2>/dev/null || true ;;
  show) ;;
  *) echo "usage: net.sh delay <time> | clear | show" >&2; exit 2 ;;
esac

echo "$(hostname) $IFACE: $(tc qdisc show dev "$IFACE" | head -1)"
