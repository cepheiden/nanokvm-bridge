# nanokvm-bridge

**Only one LAN cable at the remote PC? Plug it into the NanoKVM, and the PC still
gets internet through the KVM's USB cable. No extra switch needed.**

A real layer-2 bridge for the [Sipeed NanoKVM](https://github.com/sipeed/NanoKVM):
the Ethernet port and the USB network go into one Linux bridge. The PC on the KVM's
USB cable then sits directly in your LAN and gets its IP from your router, while
keyboard, mouse and HDMI keep working over the same setup.

```
                 NanoKVM
LAN ──── lan0 (RJ45) ───┐
                        ├── eth0  (bridge, carries the KVM's own IP as before)
PC  ──── USB ── usb0 ───┘
         (keyboard + mouse + RNDIS network over one cable)
```

## Why

The situation: there is exactly **one** LAN cable at the remote PC. The NanoKVM
needs that cable, but the PC still needs internet. Normally you would have to put
a switch on site.

With this bridge the single cable goes into the NanoKVM, and the PC gets its network
through the USB cable it already shares with the KVM. It shows up as a normal LAN
client with its own IP from your router.

The stock firmware can't do this:

- The built-in "virtual network" gives the PC only an isolated `10.x.x.x/24` address
  with no gateway. The PC can reach the KVM and nothing else.
- The kernel has no bridge support: `CONFIG_BRIDGE` is not set and no bridge module
  is included.

This repo builds the missing `llc`, `stp` and `bridge` modules for the stock kernel
and adds a boot script that sets everything up.

## What you get

- The PC on USB gets its own LAN address from your DHCP server, with a stable MAC.
- The NanoKVM keeps its IP and stays reachable, with or without anything on USB.
- It comes back after every reboot. A watcher re-adds `usb0` if it ever drops out.
- Kill switch: delete one file from the SD card and reboot.
- If the kernel changes (firmware update), the script notices and leaves the
  network stock instead of loading mismatched modules.
- Optional: USB host mode for a USB Ethernet adapter (see below). Then the KVM
  has **no** keyboard/mouse on USB.

## The easy way: let your coding agent do it

Paste this into Claude Code, Codex or any agent with a shell:

```text
I have a Sipeed NanoKVM at <IP> (SSH user root, <SSH key or password>).
There is only one LAN cable at the PC, and it goes into the KVM. I want the PC
on the KVM's USB port to get a real LAN address from my router through the KVM
(layer-2 bridge of Ethernet + USB network), and the KVM must stay reachable
when nothing is on USB.
Clone https://github.com/cepheiden/nanokvm-bridge and follow AGENTS.md exactly:
recon first, use prebuilt modules only if /proc/version matches, otherwise build
them with Docker, test with the auto-rollback trial, and ask me before every
reboot. Afterwards tell me what you changed and how to undo it.
```

[AGENTS.md](AGENTS.md) is the playbook the agent follows, including safety rules
and a troubleshooting table.

## Manual install

Requirements: SSH root access to the NanoKVM, and Docker if you need to build
the modules yourself.

**1. Pick modules.** Compare your kernel with the prebuilt set:

```sh
ssh root@KVM 'cat /proc/version'
cat prebuilt/*/proc-version.txt
```

If the lines are identical, use `prebuilt/5.10.4-tag-_image-2025-04-17/*.ko` (check
`SHA256SUMS`). Otherwise build for your kernel. The script reads your device's config
over SSH and refuses to build if anything besides the bridge would differ:

```sh
./build/build.sh root@KVM        # -> out/*.ko
```

**2. Copy and smoke-test.** Nothing is permanent yet:

```sh
MODS=out        # or prebuilt/5.10.4-tag-_image-2025-04-17
ssh root@KVM 'mkdir -p /etc/kvm-bridge'
scp -O $MODS/*.ko scripts/bridge.sh root@KVM:/etc/kvm-bridge/
ssh root@KVM 'chmod 755 /etc/kvm-bridge/bridge.sh && cd /etc/kvm-bridge &&
  insmod llc.ko && insmod stp.ko && insmod bridge.ko &&
  ip link add brtest type bridge && ip link del brtest && echo MODULES OK'
```

**3. Live trial with automatic rollback.** This rolls back by itself after 120 s
unless you confirm:

```sh
ssh root@KVM 'touch /boot/bridge.enable &&
  start-stop-daemon -S -b -m -p /run/kvm-bridge.trial.pid -x /etc/kvm-bridge/bridge.sh -- trial'
# wait ~20 s, then reconnect. The bridge copies eth0's MAC, so the IP normally stays the same.
ssh root@KVM '/etc/kvm-bridge/bridge.sh status && touch /tmp/kvm-bridge.ok'
```

**4. Make it permanent and reboot.** On this firmware a reboot takes up to a minute
before SSH even drops:

```sh
scp -O scripts/S29bridge root@KVM:/etc/init.d/
ssh root@KVM 'chmod 755 /etc/init.d/S29bridge && sync && reboot'
```

**5. Verify** after the reboot:

```sh
ssh root@KVM '/etc/kvm-bridge/bridge.sh status; bridge link; cat /var/log/kvm-bridge.log'
```

With a PC on USB, `bridge fdb show br eth0 | grep "dev usb0"` shows the PC's USB
network MAC, and the PC appears in your router with a normal LAN address.

## Turning it off

| | |
|---|---|
| Kill switch | Delete `bridge.enable` from the SD card's boot partition (FAT, readable on any computer) and reboot |
| Live, until next boot | `/etc/kvm-bridge/bridge.sh revert` |
| Uninstall | `rm /boot/bridge.enable /etc/init.d/S29bridge; rm -r /etc/kvm-bridge; reboot` |

## Optional: USB Ethernet adapter (host mode)

The NanoKVM has a single USB data port. It is either a **device** (keyboard, mouse,
virtual disk and `usb0` for the PC) or a **host** (you plug a USB Ethernet adapter
into it). It cannot be both.

If you want an adapter instead, `touch /boot/usb.host` and reboot. The script then
switches the port to host mode, loads `usbnet` + `cdc_ether` and adds the adapter to
the bridge. Only CDC-ECM adapters are wired up (tested: WCH CH334 hub + CoreChips
SR9900 "USB 10/100 LAN"). Realtek (`r8152`), ASIX and others need their driver
built and added to `USBNET_MODS` / `USBNET_DRIVERS` in `bridge.sh`.

## How it works

The bridge is named **`eth0`** and the physical port is renamed to **`lan0`**. That
sounds odd but it is the whole trick, because a lot of stock code is hard-wired to
`eth0`:

- `kvm_system` checks connectivity with `ping -I eth0 <gateway>` and reads the
  default route `via eth0` (OLED status, Wi-Fi fallback).
- `S30eth` runs DHCP on `eth0`, or applies the static IP from `/boot/eth.nodhcp` that
  the web UI writes.
- `S95nanokvm` adds iptables rules with `-i eth0` / `-o eth0`.
- `kvm_system` re-copies `S03usbdev` and `S30eth` from `/kvmapp` on start, so editing
  them does not stick.

Boot order: `S03usbdev` (USB gadget, creates `usb0`) → `S10uuid` (sets the MACs) →
**`S29bridge`** (rename, create bridge, add ports) → `S30eth` (DHCP lands on the
bridge) → `S30rndis` (its `10.x` DHCP server gets stopped by the watcher) →
`S95nanokvm` (iptables, now applied to the bridge).

## Tested

- NanoKVM Cube (`/etc/kvm/hw` = beta), app 2.5.4, image 2025-04-17
  (kernel `5.10.4-tag- #46`).
- PC on USB (stock RNDIS): got a DHCP lease from the LAN router and was reachable
  from other LAN hosts. USB HID enumerated and HDMI ran at 1080p. Reboots: the
  bridge came up every time.
- Host mode with CH334 + SR9900: the PC behind the adapter got a DHCP lease.
- **Not** tested: the loop guard against a real loop, unplugging and re-plugging a
  USB Ethernet adapter, other NanoKVM models (PCIe, Pro), other firmware images,
  throughput (the LAN port is 100 Mbit anyway).

## Caveats

- **Speed:** the PC's network runs over USB 2.0 (480 Mbit/s raw, real throughput of
  the USB network is lower). On the tested device the KVM's Ethernet port also
  links at only 100 Mbit. Don't expect gigabit, this is meant for normal internet
  access, updates and remote work.
- **CPU load:** every packet is bridged by the NanoKVM's single CPU core, which also
  encodes the video stream. CPU load rises with network traffic, and during large
  downloads the KVM picture can get less smooth.
- The modules are built out-of-tree with stock gcc 10.2 instead of Sipeed's
  Xuantie toolchain. The kernel has no `MODVERSIONS`, so a module whose config does
  not match can crash the kernel. That is why the build script checks the config
  diff and you test before making it permanent.
- STP is off (`forward_delay 0`). The loop guard only removes a USB port from the
  bridge if your gateway's MAC shows up behind it. Don't plug a USB adapter into the
  same LAN.
- The PC loses network whenever the NanoKVM reboots. If the KVM is powered from the
  PC's USB, it also reboots whenever the PC power-cycles.
- After a firmware update with a new kernel, the bridge stays off until you rebuild
  the modules. NanoKVM app updates don't touch it.
- At boot the log shows `lt6911 ... I2C_WRITE error` / `Sensor ID Mismatch`. It also
  shows up while HDMI works fine and is unrelated.

## Build gotchas (already handled in `build/`)

- Sipeed's `arch/riscv/Makefile` passes Xuantie-only flags (`-mno-ldd`,
  `-Wa,-march=...v0p7xthead`) that stock gcc rejects. They are dropped for the
  module build, and the config (and with it the struct layouts) stays identical.
- `LOCALVERSION=-tag-` makes the vermagic match: `5.10.4-tag- preempt mod_unload riscv`.
- Debian bullseye's security repo moved to `archive.debian.org`.
- Colima on macOS only mounts `$HOME`, so keep the repo there.
- The SDK commit is pinned (`SDK_REF` in `build/build-modules.sh`).

## License

Scripts: MIT. Kernel modules: GPL-2.0, built from Sipeed's kernel source. See
[LICENSE](LICENSE).

Built with the help of Claude Code. No warranty: you are loading self-built kernel
modules into your KVM.
