# Agent playbook: NanoKVM layer-2 bridge

You are setting up this repository on the user's Sipeed NanoKVM. Typical situation:
there is only one LAN cable at the remote PC, it goes into the KVM, and the PC still
needs internet through the KVM's USB cable. The goal: `eth0`
becomes a bridge of the physical Ethernet port (renamed `lan0`) and the USB network
(`usb0`), so the PC on the KVM's USB port gets a real LAN address, and the KVM stays
reachable with or without USB. Read README.md for the background.

Work step by step. Verify every step and show the user the evidence. If anything
differs from what this playbook expects, stop and ask instead of improvising.

## Ask the user first

- NanoKVM IP address and SSH access (root). Prefer an SSH key. If you only get a
  password, keep it in a temporary SSH_ASKPASS script outside the repo and delete
  it at the end. Never write it into the repo.
- Is a PC connected to the KVM's USB port right now?
- Do they want USB host mode for a USB Ethernet adapter? Default **no**: host mode
  disables keyboard/mouse emulation.

## Hard rules

1. Nothing permanent before the live trial is confirmed. Install `S29bridge` only
   in step 5.
2. Do not edit `/etc/init.d/S03usbdev`, `S30eth`, `S95nanokvm` or anything under
   `/kvmapp`. `kvm_system` overwrites some of them on start. Everything this project
   needs lives in `/etc/kvm-bridge/`, `/etc/init.d/S29bridge` and flag files in `/boot`.
3. Only load modules built for this exact kernel: either the prebuilt set when
   `/proc/version` matches `prebuilt/*/proc-version.txt` byte for byte, or the output
   of `build/build.sh` for this device. Never force-load (`insmod -f`) and never
   bypass the config-diff check in `build/build-modules.sh`.
4. Ask before every reboot. It interrupts KVM sessions and the PC's network.
5. Never put the USB port into host mode (`/boot/usb.host`) unless the user asked
   for it.
6. Use `scp -O`. The NanoKVM has no SFTP server.

## Step 0: recon (read-only)

```sh
ssh root@KVM 'uname -r; cat /proc/version; cat /kvmapp/version; cat /etc/kvm/hw
  zcat /proc/config.gz | grep -E "^(# )?CONFIG_BRIDGE[ =]"
  ip -br link; ip route; ls /boot; ls /etc/init.d; cat /sys/class/udc/*/state'
```

Expect: kernel `5.10.4-...`, `# CONFIG_BRIDGE is not set`, interfaces `eth0` and
`usb0`, no `S29bridge` yet.

- If `CONFIG_BRIDGE=y` or `=m` already exists, the kernel has bridge support and
  you don't need the modules. Tell the user and stop.
- If `S29bridge` already exists, run `/etc/kvm-bridge/bridge.sh status` and report.
- UDC state `configured` means a PC is enumerated on USB. `not attached` means no
  USB host (no PC, or a hub/dock in the wrong direction).

## Step 1: modules

```sh
ssh root@KVM 'cat /proc/version' > /tmp/pv.txt
diff /tmp/pv.txt prebuilt/5.10.4-tag-_image-2025-04-17/proc-version.txt && echo MATCH
```

- MATCH: verify with `(cd prebuilt/5.10.4-tag-_image-2025-04-17 && shasum -a 256 -c SHA256SUMS)`
  and use those files.
- No match: `./build/build.sh root@KVM` (needs Docker). It writes `out/*.ko`.
  - It reads the device config over SSH, so SSH must work non-interactively or via
    askpass.
  - On macOS with Colima the repo must be under `$HOME`.
  - If it stops with "config differs from the device in unexpected places", report
    the listed lines to the user. Don't loosen the check without understanding why
    they differ.
  - Check that every printed vermagic is `<uname -r> preempt mod_unload riscv`.

## Step 2: copy and smoke-test

```sh
ssh root@KVM 'mkdir -p /etc/kvm-bridge'
scp -O <modules>/*.ko scripts/bridge.sh root@KVM:/etc/kvm-bridge/
ssh root@KVM 'chmod 755 /etc/kvm-bridge/bridge.sh && sh -n /etc/kvm-bridge/bridge.sh && cd /etc/kvm-bridge &&
  insmod llc.ko && insmod stp.ko && insmod bridge.ko &&
  ip link add brtest type bridge && ip link set brtest up && ip link del brtest && echo MODULES OK; dmesg | tail -5'
```

If `insmod` reports `Unknown symbol` or `Invalid module format`, stop and report.
If the device stops responding, it probably crashed. It comes back after a power
cycle with nothing persistent changed. Report that and stop.

## Step 3: live trial with automatic rollback

```sh
ssh root@KVM 'touch /boot/bridge.enable &&
  start-stop-daemon -S -b -m -p /run/kvm-bridge.trial.pid -x /etc/kvm-bridge/bridge.sh -- trial'
```

Wait about 20 seconds and reconnect. The bridge copies eth0's MAC, so the DHCP lease
is normally the same IP. Then check:

```sh
ssh root@KVM '/etc/kvm-bridge/bridge.sh status; bridge link; ip route
  ping -I eth0 -c 1 -w 2 $(ip route | awk "/^default/{print \$3}") >/dev/null && echo GW_OK
  wget -q -O /dev/null -S http://127.0.0.1/ 2>&1 | head -1; cat /var/log/kvm-bridge.log'
```

Expect ports `lan0 usb0`, the same IPv4 on `eth0`, `GW_OK` and `HTTP/1.1 200 OK`.
Then confirm **within 120 s of the start**:

```sh
ssh root@KVM 'touch /tmp/kvm-bridge.ok'
```

If you cannot reconnect, wait 2-3 minutes: the trial reverts to the stock network by
itself. Then investigate (`cat /var/log/kvm-bridge.log`) and report.

## Step 4: optional host mode (only if the user asked for it)

`touch /boot/usb.host`, then `/etc/kvm-bridge/bridge.sh start` (it is idempotent and
switches the port to host mode). Look for a new `ethN` with driver `cdc_ether` in
`bridge link`. Before relying on it, make sure the adapter's cable is **not** plugged
into the same LAN: `udhcpc -i ethN -n -q -t 3 -T 2 -s /bin/true` must NOT get a lease
before the adapter joins the bridge. Only `cdc_ether` adapters are supported out of
the box.

## Step 5: make it permanent (ask the user before the reboot)

```sh
scp -O scripts/S29bridge root@KVM:/etc/init.d/
ssh root@KVM 'chmod 755 /etc/init.d/S29bridge && sync && reboot'
```

The reboot looks like it did nothing for up to ~60 s (`S95nanokvm stop` is slow),
then SSH drops and comes back about 15 s later. Repeat the step 3 checks plus
`cat /var/log/kvm-bridge.log`. The log timestamps may show 1970 until NTP syncs.

## Step 6: with a PC on USB

```sh
ssh root@KVM 'cat /sys/class/udc/*/state; bridge fdb show br eth0 | grep "dev usb0" | grep -v permanent'
```

Expect `configured` and one learned MAC, the PC's USB network adapter. Ask the user
to check that the PC got a LAN address, or look it up in the router.

## Step 7: report

Tell the user what changed (files, flags), the kill switch (delete `bridge.enable`
from the SD card's boot partition, reboot), the live revert
(`/etc/kvm-bridge/bridge.sh revert`) and that a firmware update with a new kernel
turns the bridge off until the modules are rebuilt.

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| `reboot` returns but nothing happens for ~60 s | Normal, the shutdown scripts are slow |
| UDC `not attached` although a PC is "connected" | No USB host on the port. Often a hub or dock in between, or the cable is in the hub's upstream port. Connect directly to a PC USB port |
| `lt6911 ... I2C_WRITE error` / `Sensor ID Mismatch` at boot | Seen on working devices, unrelated |
| KVM rebooted when the USB cable was moved | It is powered from the PC's USB. Give it its own power supply |
| `udhcpd` still running on `usb0` | The watcher kills it within 5 s. S30rndis writes no pid file |
| Different IP after bridging | The DHCP server keys on something other than MAC/client-id. Use a reservation or a static IP via the web UI (`/boot/eth.nodhcp`) |
| `scp` fails with an sftp error | Use `scp -O` |
| Docker build: apt 404 on bullseye-security | The Dockerfile already points it at archive.debian.org. Rebuild without cache |
