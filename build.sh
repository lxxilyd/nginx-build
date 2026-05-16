#!/bin/bash
set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Nginx 构建工具 (含一键启动脚本)${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. 自动获取最新版本号
NGINX_VERSION=$(curl -s https://nginx.org/en/download.html | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -z "$NGINX_VERSION" ] && NGINX_VERSION="1.31.0"
echo -e "${GREEN}检测到最新版本: ${NGINX_VERSION}${NC}"

# 2. 环境清理
OUTPUT_BASE="output"
rm -rf "${OUTPUT_BASE}"
mkdir -p "${OUTPUT_BASE}/amd64" "${OUTPUT_BASE}/arm64"

# 3. 编写 Dockerfile
cat > Dockerfile.nginx << 'DOCKERFILE_EOF'
FROM alpine:3.19 AS builder
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
RUN apk add --no-cache gcc musl-dev pcre-dev openssl-dev openssl-libs-static \
    zlib-dev zlib-static linux-headers make wget curl build-base libc-dev tar

WORKDIR /build
ARG NGINX_VERSION
RUN wget -q https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz && mv nginx-${NGINX_VERSION} nginx

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
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_flv_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-pcre \
    --with-cc-opt="-static -O3" \
    --with-ld-opt="-static"

RUN make -j$(nproc) && make install DESTDIR=/output

# --- 关键步骤：生成便捷脚本 ---
WORKDIR /output/usr/local/nginx
RUN mkdir -p logs temp/client_body temp/proxy temp/fastcgi temp/uwsgi temp/scgi && \
    chmod -R 777 logs temp

# 创建一键启动脚本
RUN echo '#!/bin/sh' > start.sh && \
    echo 'BASE_DIR=$(cd "$(dirname "$0")"; pwd)' >> start.sh && \
    echo 'echo "正在启动 Nginx (目录: $BASE_DIR)..."' >> start.sh && \
    echo '$BASE_DIR/sbin/nginx -p "$BASE_DIR" -c "$BASE_DIR/conf/nginx.conf"' >> start.sh && \
    echo 'echo "启动成功！访问: http://localhost:80"' >> start.sh && \
    chmod +x start.sh

# 创建一键停止脚本
RUN echo '#!/bin/sh' > stop.sh && \
    echo 'BASE_DIR=$(cd "$(dirname "$0")"; pwd)' >> stop.sh && \
    echo '$BASE_DIR/sbin/nginx -p "$BASE_DIR" -s stop' >> stop.sh && \
    echo 'echo "Nginx 已停止。"' >> stop.sh && \
    chmod +x stop.sh

FROM alpine:3.19
COPY --from=builder /output/usr/local/nginx /usr/local/nginx
WORKDIR /usr/local/nginx
DOCKERFILE_EOF

# 4. 构建与打包函数
build_and_pack() {
    local arch=$1
    local platform=$2
    local target_dir="${OUTPUT_BASE}/${arch}"
    local tar_name="nginx-${NGINX_VERSION}-static-${arch}.tar.gz"
    
    echo -e "${YELLOW}正在构建 ${arch}...${NC}"
    docker build --platform "${platform}" --build-arg NGINX_VERSION="${NGINX_VERSION}" -t "nginx-p-${arch}" -f Dockerfile.nginx .
    
    echo -e "${YELLOW}提取并生成压缩包...${NC}"
    docker run --rm --platform "${platform}" "nginx-p-${arch}" tar -C /usr/local/nginx -cf - . | tar -C "${target_dir}" -xf -
    (cd "${target_dir}" && tar -czf "../${tar_name}" .)
    rm -rf "${target_dir}"
    echo -e "${GREEN}完成: output/${tar_name}${NC}"
}

# 5. 解析输入参数，执行单架构构建
# 允许通过 ./build.sh amd64 或 ./build.sh arm64 调用
ARCH_ARG=$1

if [ "$ARCH_ARG" = "amd64" ]; then
    build_and_pack "amd64" "linux/amd64"
elif [ "$ARCH_ARG" = "arm64" ]; then
    build_and_pack "arm64" "linux/arm64"
else
    echo -e "${RED}未指定有效架构，默认执行双架构本地构建...${NC}"
    build_and_pack "amd64" "linux/amd64"
    build_and_pack "arm64" "linux/arm64"
fi

# 6. 环境变量导出 (保持不变)
if [ -n "$GITHUB_ACTIONS" ]; then
    echo "NGINX_VER=${NGINX_VERSION}" >> $GITHUB_ENV
fi