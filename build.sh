#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Nginx 全自动静态构建工具 (Latest)${NC}"
echo -e "${GREEN}========================================${NC}"

NGINX_VERSION=$(curl -s https://nginx.org/en/download.html | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -z "$NGINX_VERSION" ] && NGINX_VERSION="1.31.2"
echo -e "${GREEN}检测到最新 Nginx 版本: ${NGINX_VERSION}${NC}"

echo -e "${YELLOW}正在获取最新 quictls 版本号...${NC}"
QUICTLS_TAG=$(curl -s https://api.github.com/repos/quictls/openssl/releases/latest | grep -oP '"tag_name": "\K[^"]+')
[ -z "$QUICTLS_TAG" ] && QUICTLS_TAG="openssl-3.3.0-quic1"
echo -e "${GREEN}检测到最新 quictls 版本: ${QUICTLS_TAG}${NC}"

echo -e "${YELLOW}正在获取最新 PCRE2 版本号...${NC}"
PCRE_VERSION=$(curl -s https://api.github.com/repos/PCRE2Project/pcre2/releases/latest | grep -oP '"tag_name": "pcre2-\K[0-9]+\.[0-9]+')
[ -z "$PCRE_VERSION" ] && PCRE_VERSION="10.45" # 备用版本
echo -e "${GREEN}检测到最新 PCRE2 版本: ${PCRE_VERSION}${NC}"

OUTPUT_BASE="output"
rm -rf "${OUTPUT_BASE}"
mkdir -p "${OUTPUT_BASE}/$1"

cat > Dockerfile.nginx << 'DOCKERFILE_EOF'
FROM alpine:latest AS builder

ARG NGINX_VERSION
ARG QUICTLS_TAG
ARG PCRE_VERSION

RUN apk add --no-cache gcc musl-dev zlib-dev zlib-static linux-headers make wget curl build-base libc-dev tar perl

WORKDIR /build

RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" && \
    tar xzf "nginx-${NGINX_VERSION}.tar.gz" && mv "nginx-${NGINX_VERSION}" nginx

RUN wget -q "https://github.com/quictls/openssl/archive/refs/tags/${QUICTLS_TAG}.tar.gz" && \
    tar xzf "${QUICTLS_TAG}.tar.gz" && \
    mv openssl-openssl-* quictls

RUN wget -q "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz" && \
    tar xzf "pcre2-${PCRE_VERSION}.tar.gz" && mv "pcre2-${PCRE_VERSION}" pcre

WORKDIR /build/nginx
RUN ./configure \
    --prefix=/usr/local/nginx \
    --sbin-path=sbin/nginx \
    --conf-path=conf/nginx.conf \
    --pid-path=logs/nginx.pid \
    --lock-path=logs/nginx.lock \
    --error-log-path=logs/error.log \
    --http-log-path=logs/access.log \
    --http-client-body-temp-path=temp/client_body \
    --http-proxy-temp-path=temp/proxy \
    --http-fastcgi-temp-path=temp/fastcgi \
    --http-uwsgi-temp-path=temp/uwsgi \
    --http-scgi-temp-path=temp/scgi \
    --with-threads \
    --with-file-aio \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_sub_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_auth_request_module \
    --with-http_random_index_module \
    --with-http_secure_link_module \
    --with-http_stub_status_module \
    --with-http_slice_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_realip_module \
    --with-stream_ssl_preread_module \
    --with-http_v3_module \
    --with-openssl=/build/quictls \
    --with-pcre=/build/pcre \
    --with-pcre-jit \
    --with-cc-opt="-static -O3 -fstack-protector-strong -fPIC" \
    --with-ld-opt="-static"

RUN make -j$(nproc) && make install DESTDIR=/output

WORKDIR /output/usr/local/nginx
RUN mkdir -p logs temp/client_body temp/proxy temp/fastcgi temp/uwsgi temp/scgi && \
    chmod -R 777 logs temp

RUN echo '#!/bin/sh' > start.sh && \
    echo 'BASE_DIR=$(cd "$(dirname "$0")"; pwd)' >> start.sh && \
    echo 'echo "正在启动 Nginx (目录: $BASE_DIR)..."' >> start.sh && \
    echo '$BASE_DIR/sbin/nginx -p "$BASE_DIR" -c "$BASE_DIR/conf/nginx.conf"' >> start.sh && \
    echo 'echo "启动成功！访问: http://localhost:80"' >> start.sh && \
    chmod +x start.sh

RUN echo '#!/bin/sh' > stop.sh && \
    echo 'BASE_DIR=$(cd "$(dirname "$0")"; pwd)' >> stop.sh && \
    echo '$BASE_DIR/sbin/nginx -p "$BASE_DIR" -s stop' >> stop.sh && \
    echo 'echo "Nginx 已停止。"' >> stop.sh && \
    chmod +x stop.sh

FROM alpine:latest
COPY --from=builder /output/usr/local/nginx /usr/local/nginx
WORKDIR /usr/local/nginx
DOCKERFILE_EOF

build_and_pack() {
    local arch=$1
    local platform=$2
    local target_dir="${OUTPUT_BASE}/${arch}"
    local tar_name="nginx-${NGINX_VERSION}-static-${arch}.tar.gz"
    mkdir -p "${OUTPUT_BASE}/${arch}"
    
    echo -e "${YELLOW}正在构建 ${arch}...${NC}"
    docker build --platform "${platform}" \
                 --build-arg NGINX_VERSION="${NGINX_VERSION}" \
                 --build-arg QUICTLS_TAG="${QUICTLS_TAG}" \
                 --build-arg PCRE_VERSION="${PCRE_VERSION}" \
                 -t "nginx-p-${arch}" -f Dockerfile.nginx .
    
    echo -e "${YELLOW}提取并生成压缩包...${NC}"
    docker run --rm --platform "${platform}" "nginx-p-${arch}" tar -C /usr/local/nginx -cf - . | tar -C "${target_dir}" -xf -
    (cd "${target_dir}" && tar -czf "../${tar_name}" .)
    rm -rf "${target_dir}"
    echo -e "${GREEN}完成: output/${tar_name}${NC}"
}

ARCH_ARG=$1

if [ "$ARCH_ARG" = "amd64" ]; then
    build_and_pack "amd64" "linux/amd64"
elif [ "$ARCH_ARG" = "arm64" ]; then
    build_and_pack "arm64" "linux/arm64"
elif [ "$ARCH_ARG" = "armv7" ]; then
    build_and_pack "armv7" "linux/arm/v7"
else
    echo -e "${RED}未指定有效架构，默认执行多架构本地构建...${NC}"
    build_and_pack "amd64" "linux/amd64"
    build_and_pack "arm64" "linux/arm64"
	build_and_pack "armv7" "linux/arm/v7"
fi

if [ -n "$GITHUB_ACTIONS" ]; then
    echo "NGINX_VER=${NGINX_VERSION}" >> $GITHUB_ENV
fi