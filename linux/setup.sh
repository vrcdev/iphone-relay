#!/bin/sh
# Bring up the iPhone-relay tunnel on the Linux box.
#
# Prerequisites:
#   - iPhone 17: Personal Hotspot ON, Relay app open (screen on), USB plugged in
#   - Linux: hev-socks5-tunnel installed, this script run as root
#
# Usage: sudo ./setup.sh [usb-iface]
#   usb-iface defaults to the interface holding a 172.20.10.x address
set -e

PHONE=172.20.10.1
TUN=tun0

USBIF="${1:-$(ip -4 -o addr show | awk '/172\.20\.10\./ {print $2; exit}')}"
if [ -z "$USBIF" ]; then
    echo "no interface with a 172.20.10.x address — is the phone tethered?" >&2
    exit 1
fi
echo "usb tether interface: $USBIF"

# Make sure we have a DHCP lease / address on the tether link
if ! ip -4 addr show dev "$USBIF" | grep -q '172\.20\.10\.'; then
    dhclient "$USBIF" 2>/dev/null || udhcpc -i "$USBIF" 2>/dev/null || true
fi

# Sanity: the relay must be reachable before we cut the default route over
if ! ping -c1 -W2 "$PHONE" >/dev/null; then
    echo "cannot reach $PHONE — start the Relay app on the phone" >&2
    exit 1
fi

# Start the tunnel (daemonize via --pid-file or just background it)
if ! pgrep -f hev-socks5-tunnel >/dev/null; then
    hev-socks5-tunnel "$(dirname "$0")/relay-tun.yml" &
    sleep 1
fi

ip link set "$TUN" up

# Default route into the tunnel. Traffic to the phone itself still matches
# the more-specific 172.20.10.0/24 route on $USBIF — no loop.
ip route replace default dev "$TUN"

# DNS through the tunnel (UDP associate carries it to the phone)
printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf

# Forward Windows/other downstream devices through us too
sysctl -w net.ipv4.ip_forward=1
echo "done — test with: curl --interface $TUN ifconfig.me  (should show cellular IP)"
