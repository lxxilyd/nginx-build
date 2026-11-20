#!/usr/bin/env bash
#
# build-static.sh
#
# 用 Docker(alpine/musl) 编译“完全静态”的 nginx，产物不依赖目标机 glibc，
# 可直接丢到低内核版本的 Linux（麒麟/RHEL/CentOS 老机器）上运行。
#
# 依赖范围与 build-local.sh 一致：
#   nginx + PCRE2 + zlib 静态编入；OpenSSL(可选) 静态编入；不打包 glibc/ld-linux。
#   不引入 quictls / HTTP3 等额外模块。
#
# 源码像 build.sh 一样在容器里按版本自动下载。
# 升级：只改下面“版本配置”里的变量，然后重新执行本脚本。
#
# 用法：
#   ./build-static.sh              # 默认构建 amd64 + arm64 + armv7
#   ./build-static.sh amd64        # 只构建 amd64
#   WITH_SSL=1 ./build-static.sh amd64   # 带 HTTPS(OpenSSL 静态编入)
#
# 跨架构在 x86 宿主上需要 binfmt/qemu：
#   docker run --privileged --rm tonistiigi/binfmt --install all
#

set -euo pipefail

# ======================================================================
# 版本配置：升级时改这里，然后重新跑脚本即可
# ======================================================================
NGINX_VERSION="${NGINX_VERSION:-1.31.9}"
PCRE2_VERSION="${PCRE2_VERSION:-10.47}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.4}"   # 仅 WITH_SSL=1 时使用
ALPINE_VERSION="${ALPINE_VERSION:-3.22}"      # 构建基础镜像(musl 工具链)

WITH_SSL="${WITH_SSL:-0}"                     # 0=不启用 SSL, 1=静态编入 OpenSSL
JOBS="${JOBS:-}"                              # 留空则用容器内的 nproc

# ======================================================================
# 目录与固定参数
# ======================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_BASE="${OUTPUT_BASE:-${SCRIPT_DIR}/output}"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/_build_static}"
DOCKERFILE="${WORK_DIR}/Dockerfile.static"
IMAGE_BASE="nginx-static-musl"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
die()  { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未找到 docker 命令。"

[ "$WITH_SSL" = "0" ] || [ "$WITH_SSL" = "1" ] || die "WITH_SSL 只能是 0 或 1。"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_BASE}"

# ======================================================================
# 1. 生成 Dockerfile（版本由 ARG 在 build 时注入）
# ======================================================================
log "生成 Dockerfile：${DOCKERFILE}"

cat > "${DOCKERFILE}" <<'DOCKERFILE_EOF'
# 注意：FROM 里用到的 ARG 必须在 FROM 之前声明，否则展开为空。
ARG ALPINE_VERSION=3.22

FROM alpine:${ALPINE_VERSION} AS builder

# FROM 之前声明的 ARG 在 stage 内不可见，必须在这里重新声明一次，
# 否则配合 set -u 会出现 "parameter not set"。
ARG ALPINE_VERSION=3.22
ARG NGINX_VERSION
ARG PCRE2_VERSION
ARG ZLIB_VERSION
ARG OPENSSL_VERSION
ARG WITH_SSL
ARG JOBS

RUN apk add --no-cache \
        build-base musl-dev linux-headers perl \
        wget tar gzip file ca-certificates

WORKDIR /build

# ---- 按版本下载源码（与 build.sh 一致）----
RUN wget -q "https://proxy.lixxing.top/https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" && \
    tar xzf "nginx-${NGINX_VERSION}.tar.gz" && \
    mv "nginx-${NGINX_VERSION}" nginx

RUN wget -q "https://proxy.lixxing.top/https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" && \
    tar xzf "pcre2-${PCRE2_VERSION}.tar.gz" && \
    mv "pcre2-${PCRE2_VERSION}" pcre2

RUN wget -q "https://proxy.lixxing.top/https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" && \
    tar xzf "zlib-${ZLIB_VERSION}.tar.gz" && \
    mv "zlib-${ZLIB_VERSION}" zlib

RUN if [ "${WITH_SSL}" = "1" ]; then \
        wget -q "https://proxy.lixxing.top/https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" && \
        tar xzf "openssl-${OPENSSL_VERSION}.tar.gz" && \
        mv "openssl-${OPENSSL_VERSION}" openssl; \
    fi

# ---- 完全静态编译 ----
# CONFIGURE_ARGS 与 build-local.sh 保持一致，仅在 cc/ld 选项上追加 -static。
# -fstack-protector（而非 -strong）：与 local 原版一致，兼容老 GCC 语义。
# PCRE2、zlib、OpenSSL(可选) 由 nginx 从源码静态编入。
WORKDIR /build/nginx
RUN set -eux; \
    SSL_ARGS=""; \
    if [ "${WITH_SSL}" = "1" ]; then \
        SSL_ARGS="--with-http_ssl_module --with-stream_ssl_module --with-stream_ssl_preread_module --with-openssl=/build/openssl --with-openssl-opt=no-shared"; \
    fi; \
    MAKE_JOBS="${JOBS:-$(nproc)}"; \
    ./configure \
        "--prefix=/opt/nginx-${NGINX_VERSION}" \
        --sbin-path=sbin/nginx \
        --conf-path=conf/nginx.conf \
        --error-log-path=logs/error.log \
        --http-log-path=logs/access.log \
        --pid-path=logs/nginx.pid \
        --lock-path=logs/nginx.lock \
        --http-client-body-temp-path=temp/client_body \
        --http-proxy-temp-path=temp/proxy \
        --http-fastcgi-temp-path=temp/fastcgi \
        --http-uwsgi-temp-path=temp/uwsgi \
        --http-scgi-temp-path=temp/scgi \
        --user=nobody \
        --group=nobody \
        --with-pcre=/build/pcre2 \
        --with-zlib=/build/zlib \
        --with-http_gzip_static_module \
        --with-http_stub_status_module \
        --with-http_realip_module \
        --with-http_v2_module \
        --with-stream \
        ${SSL_ARGS} \
        --with-cc-opt="-static -O2 -fPIC -fstack-protector --param=ssp-buffer-size=4 -D_FORTIFY_SOURCE=2" \
        --with-ld-opt="-static -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack"; \
    make -j"${MAKE_JOBS}"; \
    make install DESTDIR=/output; \
    strip "/output/opt/nginx-${NGINX_VERSION}/sbin/nginx"; \
    file "/output/opt/nginx-${NGINX_VERSION}/sbin/nginx"; \
    file "/output/opt/nginx-${NGINX_VERSION}/sbin/nginx" | grep -Eq 'statically linked|static-pie|static linked' || { echo "ERROR: 产物不是静态链接！" >&2; exit 1; }

# ---- 准备打包目录 ----
WORKDIR /output/opt/nginx-${NGINX_VERSION}
RUN mkdir -p logs temp/client_body temp/proxy temp/fastcgi temp/uwsgi temp/scgi && \
    chmod -R 755 . && \
    { cp /etc/ssl/certs/ca-certificates.crt conf/ca-certificates.crt 2>/dev/null || true; }

# 编译信息随包导出，便于现场核对
# 注意：Dockerfile 的 RUN 只吃一行，每行结尾必须有 \ 续行。
RUN set -eux; \
    if [ "${WITH_SSL}" = "1" ]; then \
        SSL_INFO="${OPENSSL_VERSION}"; \
    else \
        SSL_INFO="disabled"; \
    fi; \
    { \
        echo "Static nginx build information"; \
        echo "================================"; \
        echo "nginx      : ${NGINX_VERSION}"; \
        echo "PCRE2      : ${PCRE2_VERSION}"; \
        echo "zlib       : ${ZLIB_VERSION}"; \
        echo "OpenSSL    : ${SSL_INFO}"; \
        echo "Arch       : $(uname -m)"; \
        echo "Base image : alpine:${ALPINE_VERSION}"; \
        echo "libc       : $(ldd --version 2>&1 | head -1 || true)"; \
        echo; \
        echo "file sbin/nginx:"; \
        file sbin/nginx; \
        echo; \
        echo "nginx -V:"; \
        ./sbin/nginx -V 2>&1 || true; \
    } > BUILD-INFO.txt
DOCKERFILE_EOF

# ======================================================================
# 2. 按架构构建、导出、打包
# ======================================================================
build_and_pack() {
    local arch="$1"
    local platform="$2"
    local image="${IMAGE_BASE}-${arch}"
    local target="${OUTPUT_BASE}/${arch}/nginx-${NGINX_VERSION}"
    local tar_name="nginx-${NGINX_VERSION}-static-${arch}.tar.gz"

    log "构建 ${arch} (${platform}) ..."
    docker build --platform "${platform}" \
        --build-arg NGINX_VERSION="${NGINX_VERSION}" \
        --build-arg PCRE2_VERSION="${PCRE2_VERSION}" \
        --build-arg ZLIB_VERSION="${ZLIB_VERSION}" \
        --build-arg OPENSSL_VERSION="${OPENSSL_VERSION}" \
        --build-arg WITH_SSL="${WITH_SSL}" \
        --build-arg JOBS="${JOBS}" \
        --build-arg ALPINE_VERSION="${ALPINE_VERSION}" \
        -t "${image}" -f "${DOCKERFILE}" "${WORK_DIR}"

    log "导出 ${arch} 产物 ..."
    rm -rf "${target}"
    mkdir -p "${target}"
    docker run --rm --platform "${platform}" "${image}" \
        tar -C "/output/opt/nginx-${NGINX_VERSION}" -cf - . | tar -C "${target}" -xf -

    # nginx 的 user 指令只接受「用户名/组名」，内部走 getpwnam()/getgrnam()
    # 查系统的 /etc/passwd、/etc/group，不接受 65534:65534 这种数字形式。
    # 静态二进制同样依赖系统账号表，所以必须写真实存在的账号（nobody 是通用约定）。
    cat > "${target}/conf/nginx.conf" <<'NGINXCONF'
user nobody;
worker_processes auto;

error_log logs/error.log warn;
pid logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent"';

    access_log logs/access.log main;

    sendfile on;
    keepalive_timeout 65;

    gzip on;
    gzip_min_length 1024;
    gzip_comp_level 5;
    gzip_types
        text/plain
        text/css
        application/json
        application/javascript
        application/xml
        image/svg+xml;

    server {
        listen 8080;
        server_name _;

        root html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
NGINXCONF

    # 统一入口：用 -p 指向解压目录，实现“放哪里都能跑”
    cat > "${target}/nginxctl" <<'NGINXCTL'
#!/bin/sh
BASE_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$BASE_DIR" ] || { echo "Cannot determine nginx base directory." >&2; exit 1; }
exec "$BASE_DIR/sbin/nginx" -p "$BASE_DIR/" -c conf/nginx.conf "$@"
NGINXCTL
    chmod 0755 "${target}/nginxctl"

    if [ -f "${target}/html/index.html" ]; then
        :
    else
        mkdir -p "${target}/html"
        cat > "${target}/html/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>nginx (static)</title></head>
<body><h1>nginx is running (static build)</h1></body></html>
HTML
    fi

    # 本地自检：静态链接 + 配置语法
    local fout
    fout="$(file "${target}/sbin/nginx" 2>/dev/null || true)"
    log "${arch} 二进制: ${fout}"
    printf '%s\n' "${fout}" | grep -q 'statically linked' || die "${arch}: 产物非静态链接。"

    # 配置语法自检：在同类 musl 容器里跑，避免宿主机 glibc 环境干扰。
    # 以 root 执行才能覆盖 user 指令（非 root 时 nginx 会忽略该指令并告警）。
    if docker run --rm -v "${target}:/t" --entrypoint /bin/sh "${image}" \
            -c 'cd /t && ./nginxctl -t' 2>&1; then
        log "${arch}: 配置校验通过。"
    else
        die "${arch}: nginx 配置校验失败。"
    fi

    # SHA256
    ( cd "${target}" && sha256sum sbin/nginx conf/nginx.conf > SHA256SUMS 2>/dev/null || shasum -a 256 sbin/nginx conf/nginx.conf > SHA256SUMS )

    log "打包 ${tar_name} ..."
    ( cd "${OUTPUT_BASE}/${arch}" && tar -czf "../${tar_name}" "nginx-${NGINX_VERSION}" )
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "${OUTPUT_BASE}" && sha256sum "${tar_name}" > "${tar_name}.sha256" )
    elif command -v shasum >/dev/null 2>&1; then
        ( cd "${OUTPUT_BASE}" && shasum -a 256 "${tar_name}" > "${tar_name}.sha256" )
    fi
    rm -rf "${OUTPUT_BASE}/${arch}"

    log "完成：output/${tar_name}"
}

ARCH_ARG="${1:-}"
case "${ARCH_ARG}" in
    amd64) build_and_pack "amd64" "linux/amd64" ;;
    arm64) build_and_pack "arm64" "linux/arm64" ;;
    # armv7) build_and_pack "armv7" "linux/arm/v7" ;;
    "")
        warn "未指定架构，构建 amd64 + arm64（跨架构需已安装 binfmt/qemu）。"
        build_and_pack "amd64" "linux/amd64"
        build_and_pack "arm64" "linux/arm64"
        # build_and_pack "armv7" "linux/arm/v7"
        ;;
    *) die "未知架构：${ARCH_ARG}（可选 amd64 / arm64 / armv7）" ;;
esac

log "全部完成。版本：nginx=${NGINX_VERSION} pcre2=${PCRE2_VERSION} zlib=${ZLIB_VERSION} ssl=${WITH_SSL}"
