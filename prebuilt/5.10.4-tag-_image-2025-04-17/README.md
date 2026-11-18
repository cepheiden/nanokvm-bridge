# Prebuilt modules: NanoKVM image 2025-04-17

Only use these if `cat /proc/version` on your NanoKVM matches `proc-version.txt` **exactly**
(same build number `#46` and same date). Otherwise build your own with `build/build.sh`.
The kernel has no `MODVERSIONS`, so nothing stops a module built for a different kernel
from loading and crashing it.

| | |
|---|---|
| Kernel | `5.10.4-tag- #46 PREEMPT Thu Apr 17 14:17:49 CST 2025` |
| Image | `2025-04-17-14-21-98d17d` (`/etc/os-release` VERSION `-g98d17d2c0-dirty`) |
| NanoKVM app | 2.5.4 |
| Hardware | NanoKVM Cube, `/etc/kvm/hw` = `beta` |
| Built from | `sipeed/LicheeRV-Nano-Build` @ `814cc664600f37b54fc3afef3da010ce8e675180`, `linux_5.10`, with `build/build-modules.sh` |
| Config | `kernel.config` (the device's `/proc/config.gz`) + `CONFIG_BRIDGE=m` |

Check the files before copying them: `shasum -a 256 -c SHA256SUMS`.
