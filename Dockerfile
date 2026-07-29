# Stage 1: Build static binaries from source
# Pinned to digest for reproducibility and supply chain protection
FROM ubuntu:noble@sha256:cd1dba651b3080c3686ecf4e3c4220f026b521fb76978881737d24f200828b2b AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential wget ca-certificates bzip2 busybox-static \
    zlib1g-dev libssl-dev

# -------------------------------------------------------------------
# Build Dropbear from source (static)
# -------------------------------------------------------------------
ARG DROPBEAR_VERSION=2025.89
ARG DROPBEAR_SHA256=0d1f7ca711cfc336dc8a85e672cab9cfd8223a02fe2da0a4a7aeb58c9e113634

RUN wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2 && \
    echo "${DROPBEAR_SHA256}  dropbear-${DROPBEAR_VERSION}.tar.bz2" | sha256sum -c - && \
    tar xjf dropbear-${DROPBEAR_VERSION}.tar.bz2

RUN cd dropbear-${DROPBEAR_VERSION} && \
    # Override defaults so the final scratch image does not need distro paths. \
    printf '%s\n' \
        '#undef SFTPSERVER_PATH' \
        '#define SFTPSERVER_PATH "/usr/local/bin/sftp-server"' \
        '#undef DEFAULT_ROOT_PATH' \
        '#define DEFAULT_ROOT_PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
        '#undef ED25519_PRIV_FILENAME' \
        '#define ED25519_PRIV_FILENAME "/run/dropbear/dropbear_ed25519_host_key"' \
        '#undef DROPBEAR_SVR_PASSWORD_AUTH' \
        '#define DROPBEAR_SVR_PASSWORD_AUTH 0' \
        > localoptions.h && \
    ./configure --disable-harden && \
    make PROGRAMS="dropbear dropbearkey dropbearconvert scp" STATIC=1 -j$(nproc) && \
    strip dropbear dropbearkey dropbearconvert scp && \
    mkdir -p /opt/bin && cp dropbear dropbearkey dropbearconvert scp /opt/bin/

# -------------------------------------------------------------------
# Install static Docker CLI for customer container debugging
# -------------------------------------------------------------------
ARG DOCKER_STATIC_VERSION=29.5.3
ARG DOCKER_STATIC_SHA256=34eea64e9c3435f5af1b760827a56a561cd67fc2d6e9cd1813b8bb1e3ff7930b

RUN wget -q https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_STATIC_VERSION}.tgz && \
    echo "${DOCKER_STATIC_SHA256}  docker-${DOCKER_STATIC_VERSION}.tgz" | sha256sum -c - && \
    tar xzf docker-${DOCKER_STATIC_VERSION}.tgz && \
    strip docker/docker && \
    cp docker/docker /opt/bin/docker

# -------------------------------------------------------------------
# Build OpenSSH sftp-server (static)
# -------------------------------------------------------------------
ARG OPENSSH_VERSION=9.9p1
ARG OPENSSH_SHA256=b343fbcdbff87f15b1986e6e15d6d4fc9a7d36066be6b7fb507087ba8f966c02

RUN wget -q https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz && \
    echo "${OPENSSH_SHA256}  openssh-${OPENSSH_VERSION}.tar.gz" | sha256sum -c - && \
    tar xzf openssh-${OPENSSH_VERSION}.tar.gz

RUN cd openssh-${OPENSSH_VERSION} && \
    ./configure LDFLAGS="-static" --without-pam --without-selinux --without-libedit && \
    make sftp-server -j$(nproc) && \
    strip sftp-server && \
    cp sftp-server /opt/bin/

# -------------------------------------------------------------------
# Assemble a tiny toolbox rootfs. The final image is scratch: shell and tools
# live inside this measured debug container, never in the CVM host rootfs.
# -------------------------------------------------------------------
COPY entrypoint.sh /rootfs/entrypoint.sh
COPY healthcheck.sh /rootfs/healthcheck.sh
COPY toolbox-shell tinfoil-help tinfoil-containers tinfoil-logs tinfoil-exec tinfoil-nvidia-smi /rootfs/usr/local/bin/

RUN mkdir -p \
        /rootfs/bin \
        /rootfs/dev \
        /rootfs/etc \
        /rootfs/run/dropbear \
        /rootfs/run/root \
        /rootfs/tmp \
        /rootfs/usr/local/bin \
        /rootfs/var/run \
    && cp /bin/busybox /rootfs/bin/busybox \
    && for applet in $(/bin/busybox --list); do [ "$applet" = busybox ] && continue; ln -sf busybox "/rootfs/bin/${applet}"; done \
    && cp /opt/bin/dropbear /opt/bin/dropbearkey /opt/bin/dropbearconvert /opt/bin/scp /opt/bin/sftp-server /opt/bin/docker /rootfs/usr/local/bin/ \
    && chmod 0755 /rootfs/entrypoint.sh /rootfs/healthcheck.sh /rootfs/usr/local/bin/* /rootfs/bin/busybox \
    && chmod 0700 /rootfs/run/dropbear /rootfs/run/root \
    && chmod 1777 /rootfs/tmp \
    && printf '%s\n' \
        'root:x:0:0:root:/run/root:/usr/local/bin/toolbox-shell' \
        > /rootfs/etc/passwd \
    && printf '%s\n' \
        'root:x:0:' \
        > /rootfs/etc/group \
    && printf '%s\n' \
        '/usr/local/bin/toolbox-shell' \
        > /rootfs/etc/shells \
    && ln -sf /run/root /rootfs/root \
    && printf '%s\n' \
        'export DOCKER_HOST=unix:///var/run/docker.sock' \
        'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
        'export HISTFILE=/tmp/.ash_history' \
        'export PS1="tinfoil:\w# "' \
        > /rootfs/etc/profile \
    && printf '%s\n' \
        'export DOCKER_HOST=unix:///var/run/docker.sock' \
        'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
        'export HISTFILE=/tmp/.ash_history' \
        'export PS1="tinfoil:\w# "' \
        > /rootfs/etc/tinfoil-root-profile

# -------------------------------------------------------------------
# Stage 2: Minimal toolbox image
# -------------------------------------------------------------------
FROM scratch

COPY --from=builder /rootfs/ /

EXPOSE 2222
HEALTHCHECK --interval=5s --timeout=3s --retries=12 CMD ["/healthcheck.sh"]
ENTRYPOINT ["/entrypoint.sh"]
