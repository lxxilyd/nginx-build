#!/bin/bash
set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Nginx 静态编译构建脚本${NC}"
echo -e "${GREEN}========================================${NC}"

# 获取架构参数（从环境变量或参数）
TARGET_ARCH="${1:-${TARGET_ARCH:-amd64}}"
NGINX_VERSION="${NGINX_VERSION:-latest}"

echo -e "${GREEN}目标架构: ${TARGET_ARCH}${NC}"
echo -e "${GREEN}Nginx 版本: ${NGINX_VERSION}${NC}"

# 获取最新版本号
if [ "$NGINX_VERSION" = "latest" ]; then
    NGINX_VERSION=$(curl -s https://nginx.org/en/download.html | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "${GREEN}使用最新版本: ${NGINX_VERSION}${NC}"
fi

# 设置平台
case ${TARGET_ARCH} in
    amd64)
        PLATFORM="linux/amd64"
        ;;
    arm64|aarch64)
        PLATFORM="linux/arm64"
        TARGET_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}不支持的架构: ${TARGET_ARCH}${NC}"
        exit 1
        ;;
esac

# 创建 Dockerfile
cat > Dockerfile.nginx << 'DOCKERFILE_EOF'
FROM --platform=${PLATFORM} alpine:3.19 AS builder

ARG NGINX_VERSION

# 安装编译依赖
RUN apk add --no-cache \
    gcc \
    musl-dev \
    pcre-dev \
    openssl-dev \
    zlib-dev \
    linux-headers \
    make \
    wget \
    git \
    curl \
    perl \
    build-base

WORKDIR /build

# 下载 Nginx 源码
RUN echo "==> 下载 Nginx ${NGINX_VERSION} 源码..." && \
    wget -q https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz && \
    mv nginx-${NGINX_VERSION} nginx && \
    rm nginx-${NGINX_VERSION}.tar.gz

# 下载 proxy_connect 模块
RUN echo "==> 下载 ngx_http_proxy_connect_module..." && \
    git clone --depth 1 https://github.com/chobits/ngx_http_proxy_connect_module.git /build/proxy_connect

# 应用补丁
WORKDIR /build/nginx
RUN echo "==> 应用 proxy_connect 模块补丁..." && \
    if [ -f /build/proxy_connect/patch/proxy_connect_rewrite_${NGINX_VERSION}.patch ]; then \
        patch -p1 < /build/proxy_connect/patch/proxy_connect_rewrite_${NGINX_VERSION}.patch; \
    elif [ -f /build/proxy_connect/patch/proxy_connect_${NGINX_VERSION}.patch ]; then \
        patch -p1 < /build/proxy_connect/patch/proxy_connect_${NGINX_VERSION}.patch; \
    else \
        echo "警告: 未找到匹配的补丁，尝试通用补丁"; \
        if [ -f /build/proxy_connect/patch/proxy_connect_rewrite_1.31.0.patch ]; then \
            patch -p1 < /build/proxy_connect/patch/proxy_connect_rewrite_1.31.0.patch; \
        fi; \
    fi

# 配置编译选项
RUN ./configure \
    --prefix=/usr/local/nginx \
    --pid-path=/var/run/nginx/nginx.pid \
    --lock-path=/var/lock/nginx.lock \
    --user=nginx \
    --group=nginx \
    --with-http_ssl_module \
    --with-http_flv_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-http_v2_module \
    --with-pcre \
    --with-pcre=static \
    --with-openssl=static \
    --with-zlib=static \
    --with-cc-opt="-static -O2 -fPIC" \
    --with-ld-opt="-static" \
    --http-client-body-temp-path=/var/tmp/nginx/client/ \
    --http-proxy-temp-path=/var/tmp/nginx/proxy/ \
    --http-fastcgi-temp-path=/var/tmp/nginx/fcgi/ \
    --http-uwsgi-temp-path=/var/tmp/nginx/uwsgi \
    --http-scgi-temp-path=/var/tmp/nginx/scgi \
    --add-module=/build/proxy_connect

# 编译
RUN make -j$(nproc)

# 安装到临时目录
RUN make install DESTDIR=/output

# 创建必要的目录
RUN mkdir -p /output/var/{log,run}/nginx && \
    mkdir -p /output/var/tmp/nginx/{client,proxy,fcgi,uwsgi,scgi} && \
    chmod -R 755 /output/var/tmp/nginx

# 第二阶段：准备最终产物
FROM scratch AS final
COPY --from=builder /output/usr/local/nginx /usr/local/nginx
COPY --from=builder /output/var /var
DOCKERFILE_EOF

# 替换 Dockerfile 中的变量
sed -i "s/\${PLATFORM}/${PLATFORM}/g" Dockerfile.nginx

# 构建 Docker 镜像
echo -e "${YELLOW}开始构建 Docker 镜像...${NC}"
docker build \
    --build-arg NGINX_VERSION=${NGINX_VERSION} \
    -t nginx-static-${TARGET_ARCH} \
    -f Dockerfile.nginx .

# 创建输出目录
mkdir -p output/${TARGET_ARCH}

# 提取文件
echo -e "${YELLOW}提取编译产物...${NC}"
CONTAINER_ID=$(docker create nginx-static-${TARGET_ARCH})
docker cp ${CONTAINER_ID}:/usr/local/nginx/sbin/nginx output/${TARGET_ARCH}/nginx
docker cp ${CONTAINER_ID}:/usr/local/nginx/conf output/${TARGET_ARCH}/
docker cp ${CONTAINER_ID}:/usr/local/nginx/html output/${TARGET_ARCH}/
docker rm ${CONTAINER_ID}

# 整理目录结构
mkdir -p output/${TARGET_ARCH}/sbin
mv output/${TARGET_ARCH}/nginx output/${TARGET_ARCH}/sbin/
chmod +x output/${TARGET_ARCH}/sbin/nginx

# 创建启动脚本
cat > output/${TARGET_ARCH}/run.sh << 'SCRIPT_EOF'
#!/bin/sh
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NGINX_SBIN="${SCRIPT_DIR}/sbin/nginx"
NGINX_CONF="${SCRIPT_DIR}/conf/nginx.conf"

sudo mkdir -p /var/log/nginx /var/run/nginx
sudo mkdir -p /var/tmp/nginx/client /var/tmp/nginx/proxy /var/tmp/nginx/fcgi /var/tmp/nginx/uwsgi /var/tmp/nginx/scgi
sudo useradd -r -s /sbin/nologin nginx 2>/dev/null || true

${NGINX_SBIN} -t -c ${NGINX_CONF}
if [ $? -eq 0 ]; then
    echo "Starting nginx..."
    ${NGINX_SBIN} -c ${NGINX_CONF}
    echo "Nginx started successfully"
    echo "PID: $(cat /var/run/nginx/nginx.pid 2>/dev/null)"
else
    echo "Configuration test failed"
    exit 1
fi
SCRIPT_EOF
chmod +x output/${TARGET_ARCH}/run.sh

# 打包
echo -e "${YELLOW}打包文件...${NC}"
cd output/${TARGET_ARCH}
tar czf ../nginx-static-${TARGET_ARCH}-${NGINX_VERSION}.tar.gz ./*
cd ../..

echo -e "${GREEN}✅ 构建完成！${NC}"
echo -e "${GREEN}产物: output/nginx-static-${TARGET_ARCH}-${NGINX_VERSION}.tar.gz${NC}"
ls -lh output/*.tar.gz