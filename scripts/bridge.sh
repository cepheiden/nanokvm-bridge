#!/bin/sh
# NanoKVM layer-2 bridge: physical Ethernet port + USB network (usb0 gadget
# and/or a USB Ethernet adapter) in one Linux bridge.
#
# The bridge is named "eth0" and the physical port is renamed to "lan0".
# That way S30eth (DHCP or the static IP from /boot/eth.nodhcp), kvm_system
# (gateway ping check, OLED), the iptables rules from S95nanokvm and
# NanoKVM-Server keep working unchanged - they just talk to the bridge.
#
# Switches on the FAT boot partition of the SD card (/boot):
#   bridge.enable  bridge on. Delete it and reboot = stock behaviour.
#   usb.host       put the USB port into host mode for a USB Ethernet adapter
#                  (then there is NO keyboard/mouse emulation for a PC on USB).
#
# If the kernel does not match the modules or anything fails,
# eth0 stays a normal network interface.
#
# Usage: bridge.sh start|stop|restart|status|watch|switch|revert|trial

DIR=/etc/kvm-bridge
BR=eth0
PHY=lan0
GADGET=usb0
KREL=5.10.4-tag-
FLAG=/boot/bridge.enable
HOSTFLAG=/boot/usb.host
BRIDGE_MODS="llc stp bridge"
USBNET_MODS="usbnet cdc_ether"
# drivers whose network interfaces are added to the bridge automatically
USBNET_DRIVERS="cdc_ether"
LOG=/var/log/kvm-bridge.log
WPID=/run/kvm-bridge.watch.pid

log() {
	echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
	echo "kvm-bridge: $*"
}

is_bridge() { [ -d "/sys/class/net/$1/bridge" ]; }

load_mods() {
	for m in "$@"; do
		grep -q "^$m " /proc/modules && continue
		insmod "$DIR/$m.ko" || { log "insmod $m failed"; return 1; }
	done
}

kernel_ok() {
	[ "$(uname -r)" = "$KREL" ] && return 0
	log "kernel $(uname -r) does not match the modules ($KREL), bridge stays off"
	return 1
}

# put the USB port into host mode so a USB Ethernet adapter is detected
usb_host() {
	[ -e "$HOSTFLAG" ] || return 0
	if [ "$(cat /proc/cviusb/otg_role 2>/dev/null)" != host ]; then
		/etc/init.d/S03usbdev stop >/dev/null 2>&1
		log "USB port switched to host mode"
	fi
	load_mods $USBNET_MODS
}

# interfaces that belong into the bridge (besides lan0)
port_candidates() {
	[ -d "/sys/class/net/$GADGET" ] && echo "$GADGET"
	for n in /sys/class/net/*; do
		drv=$(basename "$(readlink "$n/device/driver" 2>/dev/null)" 2>/dev/null)
		for d in $USBNET_DRIVERS; do
			[ "$drv" = "$d" ] && basename "$n"
		done
	done
}

# loop guard: gateway MAC seen behind a USB port = that cable is plugged into the same LAN
loop_guard() {
	gw=$(ip route | awk '/^default/ {print $3; exit}')
	[ -n "$gw" ] || return 0
	gwmac=$(ip neigh show "$gw" | awk '{print $5; exit}')
	[ -n "$gwmac" ] || return 0
	bridge fdb show br "$BR" | grep -i "^$gwmac dev " | awk '{print $3}' | while read -r dev; do
		[ "$dev" = "$PHY" ] && continue
		ip link set "$dev" nomaster
		touch "/run/kvm-bridge.blocked.$dev"
		log "LOOP: gateway seen behind $dev, removed $dev from the bridge (until it is re-plugged)"
	done
}

attach() {
	dev=$1
	[ -e "/run/kvm-bridge.blocked.$dev" ] && return 0
	if [ "$dev" = "$GADGET" ]; then
		# udhcpd from S30rndis writes no pid file, so find it by its command line
		for p in $(pidof udhcpd); do
			if grep -q "udhcpd.$GADGET.conf" "/proc/$p/cmdline" 2>/dev/null; then
				kill "$p" 2>/dev/null && log "stopped udhcpd on $GADGET"
			fi
		done
	fi
	if ip -4 addr show dev "$dev" | grep -q inet; then
		ip -4 addr flush dev "$dev"
	fi
	echo 1 > "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null
	if [ ! -e "/sys/class/net/$dev/master" ]; then
		ip link set "$dev" master "$BR" && log "$dev added to the bridge"
	fi
	ip link set "$dev" up
}

fix_ports() {
	is_bridge "$BR" || return 0
	# lift the loop block for adapters that were unplugged
	for b in /run/kvm-bridge.blocked.*; do
		[ -e "$b" ] || continue
		[ -d "/sys/class/net/${b##*.}" ] || rm -f "$b"
	done
	for dev in $(port_candidates); do
		attach "$dev"
	done
	loop_guard
}

start_watch() {
	[ -f "$WPID" ] && kill "$(cat $WPID)" 2>/dev/null
	start-stop-daemon -S -b -m -p "$WPID" -x "$DIR/bridge.sh" -- watch
}

start() {
	if [ ! -e "$FLAG" ]; then
		echo "kvm-bridge: $FLAG missing, eth0 stays a normal interface"
		return 0
	fi
	if is_bridge "$BR"; then
		echo "kvm-bridge: bridge already running"
		usb_host
		start_watch
		return 0
	fi
	[ -d /sys/class/net/eth0 ] || { log "eth0 missing"; return 1; }
	kernel_ok || return 0
	load_mods $BRIDGE_MODS || return 0

	mac=$(cat /sys/class/net/eth0/address)

	# stop a running DHCP client on the physical port (only on a live switch)
	if [ -f /run/udhcpc.eth0.pid ]; then
		kill "$(cat /run/udhcpc.eth0.pid)" 2>/dev/null
		rm -f /run/udhcpc.eth0.pid
	fi
	ip addr flush dev eth0
	ip link set eth0 down
	if ! ip link set eth0 name "$PHY"; then
		log "renaming eth0 -> $PHY failed"
		ip link set eth0 up
		return 1
	fi
	if ! ip link add "$BR" type bridge forward_delay 0 stp_state 0 mcast_snooping 0; then
		log "creating the bridge failed, back to a normal eth0"
		ip link set "$PHY" name eth0
		ip link set eth0 up
		return 1
	fi
	ip link set "$BR" address "$mac"
	echo 1 > "/proc/sys/net/ipv6/conf/$PHY/disable_ipv6" 2>/dev/null
	ip link set "$PHY" master "$BR"
	ip link set "$PHY" up
	ip link set "$BR" up
	log "bridge $BR up with $PHY, MAC $mac"
	usb_host
	fix_ports
	start_watch
}

stop() {
	[ -f "$WPID" ] && { kill "$(cat $WPID)" 2>/dev/null; rm -f "$WPID"; }
	if ! is_bridge "$BR"; then
		echo "kvm-bridge: no bridge active"
		return 0
	fi
	if [ -f /run/udhcpc.eth0.pid ]; then
		kill "$(cat /run/udhcpc.eth0.pid)" 2>/dev/null
		rm -f /run/udhcpc.eth0.pid
	fi
	ip link set "$BR" down
	ip link del "$BR"
	ip link set "$PHY" down
	ip link set "$PHY" name eth0
	echo 0 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6 2>/dev/null
	ip link set eth0 up
	rm -f /run/kvm-bridge.blocked.*
	log "bridge removed, eth0 is a normal interface again"
}

# live: bridge on + get DHCP/static IP via S30eth
switch() {
	start
	/etc/init.d/S30eth start
}

# live: bridge off + stock state (eth0 DHCP, usb0 10.x via S30rndis)
revert() {
	stop
	/etc/init.d/S30eth start
	[ -e /boot/usb.rndis0 ] && /etc/init.d/S30rndis start
}

# trial with automatic rollback: reverts after 120 s unless /tmp/kvm-bridge.ok exists
trial() {
	rm -f /tmp/kvm-bridge.ok
	log "trial: bridge on, rollback in 120 s unless /tmp/kvm-bridge.ok appears"
	switch
	i=0
	while [ $i -lt 120 ]; do
		[ -e /tmp/kvm-bridge.ok ] && { log "trial confirmed"; return 0; }
		sleep 1
		i=$((i + 1))
	done
	log "trial not confirmed, rolling back"
	revert
}

watch() {
	while is_bridge "$BR"; do
		if [ -e "$HOSTFLAG" ] && [ "$(cat /proc/cviusb/otg_role 2>/dev/null)" != host ]; then
			usb_host
		fi
		fix_ports
		sleep 5
	done
}

status() {
	if is_bridge "$BR"; then
		echo "bridge $BR active, ports: $(ls /sys/class/net/$BR/brif | tr '\n' ' ')"
	else
		echo "bridge off"
	fi
	echo "USB port: $(cat /proc/cviusb/otg_role 2>/dev/null)"
	ip -4 addr show dev eth0 | grep inet
}

case "$1" in
	start) start ;;
	stop) stop ;;
	restart) stop; start ;;
	switch) switch ;;
	revert) revert ;;
	trial) trial ;;
	watch) watch ;;
	status) status ;;
	*) echo "Usage: $0 {start|stop|restart|status|switch|revert|trial}"; exit 1 ;;
esac
