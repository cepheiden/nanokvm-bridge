#!/bin/bash
# Runs inside the build container.
#   /in/kernel.config   the NanoKVM's own config (zcat /proc/config.gz)
#   /in/kernel.release  the NanoKVM's `uname -r` (e.g. 5.10.4-tag-)
#   /out                receives llc.ko stp.ko bridge.ko usbnet.ko cdc_ether.ko
set -euo pipefail

SDK_REPO=${SDK_REPO:-https://github.com/sipeed/LicheeRV-Nano-Build.git}
# commit the published modules were built from; override with SDK_REF=<sha|branch>
SDK_REF=${SDK_REF:-814cc664600f37b54fc3afef3da010ce8e675180}

KREL=$(tr -d '\n' < /in/kernel.release)
case "$KREL" in
	5.10.4*) LOCALVERSION=${KREL#5.10.4} ;;
	*) echo "unexpected kernel release '$KREL' (expected 5.10.4...)"; exit 1 ;;
esac

if [ ! -d /work/sdk/linux_5.10 ]; then
	echo ">> fetching Sipeed kernel source ($SDK_REF)"
	git init -q /work/sdk
	cd /work/sdk
	git remote add origin "$SDK_REPO"
	git sparse-checkout set linux_5.10
	git fetch -q --depth 1 --filter=blob:none origin "$SDK_REF"
	git checkout -q FETCH_HEAD
fi
cd /work/sdk/linux_5.10
git checkout -q -- arch/riscv/Makefile

export ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu-

echo ">> configuring (device config + bridge as module)"
cp /in/kernel.config .config
./scripts/config \
	--module CONFIG_BRIDGE \
	--disable CONFIG_BRIDGE_NETFILTER \
	--disable CONFIG_BRIDGE_NF_EBTABLES \
	--disable CONFIG_NF_TABLES_BRIDGE \
	--disable CONFIG_BRIDGE_VLAN_FILTERING \
	--disable CONFIG_BRIDGE_MRP \
	--enable CONFIG_BRIDGE_IGMP_SNOOPING \
	--disable CONFIG_NET_DSA \
	--disable CONFIG_NET_SWITCHDEV
make -s olddefconfig

# Without MODVERSIONS nothing checks struct layouts at load time, so the config
# must stay identical to the running kernel apart from the new modules and
# compiler-version bookkeeping.
echo ">> checking config diff against the device"
unexpected=$(diff <(grep -E '^(CONFIG_|# CONFIG_)' /in/kernel.config | sort) \
                  <(grep -E '^(CONFIG_|# CONFIG_)' .config | sort) \
	| grep -E '^[<>]' \
	| grep -vE 'CONFIG_(BRIDGE|LLC|STP|NF_TABLES_BRIDGE|CC_VERSION_TEXT|GCC_VERSION|LD_VERSION|LLD_VERSION|GCC_PLUGIN)' \
	|| true)
if [ -n "$unexpected" ]; then
	echo "config differs from the device in unexpected places, refusing to build:"
	echo "$unexpected"
	exit 1
fi
grep -q '^CONFIG_USB_NET_CDCETHER=m' .config || echo "note: CDC Ethernet is not =m in this config, skipping usbnet/cdc_ether"

echo ">> dropping Xuantie-only compiler flags (stock gcc does not know them)"
sed -i \
	-e 's/^\tKBUILD_CFLAGS += -mno-ldd/\t# &/' \
	-e 's/^riscv-march-aflags-\$(CONFIG_VECTOR_1_0)/# &/' \
	-e 's/^riscv-march-aflags-\$(CONFIG_VECTOR_0_7)/# &/' \
	-e 's/^riscv-march-aflags-\$(CONFIG_RISCV_ISA_THEAD)/# &/' \
	arch/riscv/Makefile

echo ">> modules_prepare (LOCALVERSION=$LOCALVERSION)"
make -s -j"$(nproc)" LOCALVERSION="$LOCALVERSION" modules_prepare
built=$(cat include/config/kernel.release)
[ "$built" = "$KREL" ] || { echo "kernel release mismatch: built $built, device $KREL"; exit 1; }

dirs="net/llc net/802 net/bridge"
grep -q '^CONFIG_USB_NET_CDCETHER=m' .config && dirs="$dirs drivers/net/usb"
for d in $dirs; do
	echo ">> building $d"
	make -s -j"$(nproc)" LOCALVERSION="$LOCALVERSION" KBUILD_MODPOST_WARN=1 M="$d" modules 2>&1 \
		| grep -vE 'Module.symvers|Modules may not have|Unresolved symbol check|^WARNING: modpost: Symbol info' || true
done

mods="net/llc/llc.ko net/802/stp.ko net/bridge/bridge.ko"
[ -f drivers/net/usb/cdc_ether.ko ] && mods="$mods drivers/net/usb/usbnet.ko drivers/net/usb/cdc_ether.ko"
for m in $mods; do
	cp "$m" /out/
	printf '%-14s vermagic: %s\n' "$(basename "$m")" "$(modinfo -F vermagic "$m")"
done
cd /out && sha256sum ./*.ko > SHA256SUMS
echo ">> done"
