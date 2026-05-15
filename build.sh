#!/bin/bash
set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Nginx 自动双架构构建并打包脚本${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. 自动获取最新版本号
echo -e "${YELLOW}正在检测 Nginx 最新源码版本...${NC}"
NGINX_VERSION=$(curl -s https://nginx.org/en/download.html | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [ -z "$NGINX_VERSION" ]; then
    NGINX_VERSION="1.31.0"
    echo -e "${RED}抓取失败，回退到默认版本: ${NGINX_VERSION}${NC}"
else
    echo -e "${GREEN}检测到最新版本: ${NGINX_VERSION}${NC}"
fi

# 2. 环境清理与目录准备
OUTPUT_BASE="output"
rm -rf "${OUTPUT_BASE}"
mkdir -p "${OUTPUT_BASE}/amd64" "${OUTPUT_BASE}/arm64"

# 3. 编写 Dockerfile
cat > Dockerfile.nginx << 'DOCKERFILE_EOF'
FROM alpine:3.19 AS builder
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
RUN apk add --no-cache \
    gcc musl-dev pcre-dev openssl-dev openssl-libs-static \
    zlib-dev zlib-static linux-headers make wget curl \
    build-base libc-dev tar

WORKDIR /build
ARG NGINX_VERSION
RUN wget -q https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz && \
    mv nginx-${NGINX_VERSION} nginx

WORKDIR /build/nginx
RUN ./configure \
    --prefix=/usr/local/nginx \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-pcre \
    --with-cc-opt="-static -O3" \
    --with-ld-opt="-static"

RUN make -j$(nproc) && make install DESTDIR=/output

FROM alpine:3.19
COPY --from=builder /output/usr/local/nginx /usr/local/nginx
WORKDIR /usr/local/nginx
DOCKERFILE_EOF

# 4. 构建与打包函数
build_and_pack() {
    local arch=$1
    local platform=$2
    local target_dir="${OUTPUT_BASE}/${arch}"
    local tar_name="nginx-${NGINX_VERSION}.tar.gz"
    
    echo -e "${YELLOW}开始构建 ${arch} 版本...${NC}"
    docker build \
        --platform "${platform}" \
        --build-arg NGINX_VERSION="${NGINX_VERSION}" \
        -t "nginx-build-${arch}" \
        -f Dockerfile.nginx .
    
    echo -e "${YELLOW}提取 ${arch} 文件...${NC}"
    docker run --rm --platform "${platform}" "nginx-build-${arch}" tar -C /usr/local/nginx -cf - . | tar -C "${target_dir}" -xf -
    
    echo -e "${YELLOW}正在生成压缩包: ${arch}/${tar_name}...${NC}"
    # 进入架构目录进行打包，确保解压后不带多余的路径层级
    (cd "${target_dir}" && tar -czf "${tar_name}" ./*)
    
    # 清理掉解压出的原始文件（可选），只保留压缩包
    # find "${target_dir}" -maxdepth 1 ! -name "${tar_name}" ! -path "${target_dir}" -exec rm -rf {} +
    
    echo -e "${GREEN}${arch} 处理完成！${NC}"
}

# 5. 执行 amd64 和 arm64 的构建
build_and_pack "amd64" "linux/amd64"
build_and_pack "arm64" "linux/arm64"

# 6. 结果展示
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 所有架构构建并打包完成！${NC}"
echo -e "${YELLOW}文件清单:${NC}"
ls -lh ${OUTPUT_BASE}/amd64/nginx-${NGINX_VERSION}.tar.gz
ls -lh ${OUTPUT_BASE}/arm64/nginx-${NGINX_VERSION}.tar.gz

echo -e "\n${GREEN}架构校验:${NC}"
# 从生成的压缩包中直接读取二进制信息
tar -xOzf "${OUTPUT_BASE}/amd64/nginx-${NGINX_VERSION}.tar.gz" ./sbin/nginx | file - | sed "s/-/amd64 version:/"
tar -xOzf "${OUTPUT_BASE}/arm64/nginx-${NGINX_VERSION}.tar.gz" ./sbin/nginx | file - | sed "s/-/arm64 version:/"
echo -e "${GREEN}========================================${NC}"

if [ -n "$GITHUB_ACTIONS" ]; then
    echo "NGINX_VER=$NGINX_VERSION" >> $GITHUB_ENV
fi