# Multi-stage build for the Flexisip SIP proxy.
# Stage 1 builds from upstream source; stage 2 is a clean runtime image.
# Unofficial community build. See NOTICE for attribution.

# ---- builder stage --------------------------------------------------------
FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive

# Build tools + flexisip's dev dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    ccache \
    cmake \
    doxygen \
    elfutils \
    git \
    ninja-build \
    pkg-config \
    python3 \
    python3-pystache \
    python3-six \
    yasm \
    wget \
    libssl-dev \
    libhiredis-dev \
    libjansson-dev \
    libjsoncpp-dev \
    libsqlite3-dev \
    libpq-dev \
    libmariadb-dev \
    libmariadb-dev-compat \
    libnghttp2-dev \
    libsnmp-dev \
    libxerces-c-dev \
    libsrtp2-dev \
    libgsm1-dev \
    libopus-dev \
    libmbedtls-dev \
    libspeex-dev \
    libspeexdsp-dev \
    libxml2-dev \
    libvpx-dev \
    libsystemd-dev \
    libboost-dev \
    libboost-system-dev \
    libboost-thread-dev \
    libcpp-jwt-dev \
    libsoci-dev \
    nlohmann-json3-dev \
 && rm -rf /var/lib/apt/lists/*

# Build libnghttp2_asio 1.51.0 from source (not in Ubuntu 24.04 repos).
RUN cd /tmp \
 && wget -q https://github.com/nghttp2/nghttp2/releases/download/v1.51.0/nghttp2-1.51.0.tar.gz \
 && tar -xf nghttp2-1.51.0.tar.gz \
 && cmake -S nghttp2-1.51.0 -B nghttp2-1.51.0/build -GNinja -DENABLE_ASIO_LIB=ON \
 && cmake --build nghttp2-1.51.0/build --target install \
 && rm -rf nghttp2-1.51.0 nghttp2-1.51.0.tar.gz \
 && ldconfig

# The upstream source (flexisip + recursive submodules) is pre-cloned on the
# CI runner into src-proxy/ (see .github/workflows/build.yml) and passed in
# here. .git is preserved so cmake's bc_compute_full_version (git describe)
# works, matching the prior shallow-clone behavior. No gitlab access is
# needed inside the build.
COPY src-proxy/ /src/
WORKDIR /src
RUN cmake -G Ninja -B build \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX=/opt/belledonne-communications \
        -DSYSCONF_INSTALL_DIR=/etc \
        -DENABLE_G729=ON \
 && cmake --build build \
 && cmake --install build \
 && tar -C / -czf /install.tgz opt

# ---- runtime stage --------------------------------------------------------
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/belledonne-communications/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LABEL org.opencontainers.image.title="flexisip-proxy"
LABEL org.opencontainers.image.description="SIP proxy (unofficial community build) for TeleCrypt-io"
LABEL org.opencontainers.image.licenses="AGPL-3.0"
LABEL org.opencontainers.image.source="https://github.com/TeleCrypt-io/flexisip-docker"
LABEL org.opencontainers.image.vendor="TeleCrypt-io"
LABEL org.opencontainers.image.documentation="https://github.com/TeleCrypt-io/flexisip-docker/blob/main/README.md"

# Runtime libraries the proxy binary links against. Names use the t64 ABI
# where the upstream .deb's Depends declares them.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libsystemd0 \
    libssl3t64 \
    libboost-system1.83.0 \
    libboost-thread1.83.0 \
    libhiredis1.1.0 \
    libjansson4 \
    libjsoncpp25 \
    libsqlite3-0 \
    libpq5 \
    libmariadb3 \
    libnghttp2-14 \
    libsnmp40t64 \
    libxerces-c3.2t64 \
    libsrtp2-1 \
    libgsm1 \
    libopus0 \
    libspeex1 \
    libspeexdsp1 \
    libxml2 \
    libvpx9 \
    python3 \
    python3-google-auth \
    python3-requests \
 && rm -rf /var/lib/apt/lists/*

# Bring in the built proxy from the builder stage via tar (avoids a
# buildkit cache-mount conflict that some snapshotter versions hit
# when COPY --from=builder copies a tree containing a 'bin' subdir).
COPY --from=builder /install.tgz /tmp/install.tgz
RUN tar -xzf /tmp/install.tgz -C / && rm /tmp/install.tgz

VOLUME ["/etc/opt/belledonne-communications"]
VOLUME ["/var/opt/belledonne-communications"]
EXPOSE 5061/tcp

COPY docker/proxy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["flexisip", "--server", "proxy"]
