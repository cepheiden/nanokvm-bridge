# Cross-build environment for NanoKVM (Sipeed LicheeRV Nano / SG2002, RISC-V) kernel modules.
# Debian bullseye ships gcc 10.2, the closest match to Sipeed's Xuantie gcc 10.2.0.
FROM debian:bullseye

# bullseye-security has moved to archive.debian.org
RUN sed -i 's#http://deb.debian.org/debian-security#http://archive.debian.org/debian-security#' /etc/apt/sources.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git ca-certificates build-essential bc bison flex libssl-dev libelf-dev \
      cpio kmod python3 gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
      libc6-dev-riscv64-cross \
 && rm -rf /var/lib/apt/lists/*

COPY build-modules.sh /usr/local/bin/build-modules.sh
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/build-modules.sh"]
