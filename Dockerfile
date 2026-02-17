FROM python:3.10-slim

# 1. 安装基础工具
RUN apt-get update && apt-get install -y \
    nginx \
    supervisor \
    git \
    curl \
    gnupg \
    build-essential \
    wget \
    && rm -rf /var/lib/apt/lists/*

# 2. 安装 Node.js 20
RUN mkdir -p /etc/apt/keyrings
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
RUN echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
RUN apt-get update && apt-get install -y nodejs

# 3. 安装 Go 1.24（DS2API 需要）
RUN curl -fsSL https://go.dev/dl/go1.24.0.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH=$PATH:/usr/local/go/bin
ENV GOPROXY=https://proxy.golang.org,direct

# 4. 部署 Edge TTS
WORKDIR /app/tts
RUN git clone https://github.com/travisvn/openai-edge-tts.git .
RUN pip install --no-cache-dir -r requirements.txt

# 5. 部署 DS2API (替换 deepseek-free-api，Go + React)
WORKDIR /app/deepseek
RUN git clone https://github.com/CJackHwang/ds2api.git .
# 构建前端 WebUI
WORKDIR /app/deepseek/webui
RUN npm install
RUN npm run build
# 构建 Go 后端
WORKDIR /app/deepseek
RUN go build -ldflags="-s -w" -o ds2api ./cmd/ds2api
# 创建必要目录
RUN mkdir -p caches data logs static/admin && chmod -R 777 caches data logs

# 6. 部署 Qwen2API (位于 /app/qwen)
WORKDIR /app/qwen
RUN git clone https://github.com/Rfym21/Qwen2API.git .
RUN npm install
WORKDIR /app/qwen/public
RUN npm install
RUN npm run build
WORKDIR /app/qwen
RUN mkdir -p caches data logs && chmod -R 777 caches data logs

# 7. 部署 QwenChat2Api (/app/qw)
WORKDIR /app/qw
RUN git clone https://github.com/ckcoding/qwenchat2api.git .
RUN npm install
RUN npm audit fix || true

# 8. 创建环境变量隔离启动脚本
# DS2API 启动脚本（直接启动，只读取 DS2API_ 变量）
RUN cat > /app/start-ds2api.sh << 'EOF'
#!/bin/bash
cd /app/deepseek
# DS2API 会自动识别 DS2API_ 前缀的环境变量
exec ./ds2api
EOF
RUN chmod +x /app/start-ds2api.sh

# Qwen2API 启动脚本（严格过滤 DS2API 专用变量，防止干扰）
RUN cat > /app/start-qwen.sh << 'EOF'
#!/bin/bash
# 清除所有 DS2API 专用环境变量，确保 Qwen2API 不读取这些配置
unset DS2API_ADMIN_KEY DS2API_JWT_SECRET DS2API_JWT_EXPIRE_HOURS \
      DS2API_CONFIG_PATH DS2API_CONFIG_JSON DS2API_WASM_PATH \
      DS2API_STATIC_ADMIN_DIR DS2API_AUTO_BUILD_WEBUI \
      DS2API_ACCOUNT_MAX_INFLIGHT DS2API_ACCOUNT_CONCURRENCY \
      DS2API_ACCOUNT_MAX_QUEUE DS2API_ACCOUNT_QUEUE_SIZE \
      DS2API_VERCEL_INTERNAL_SECRET DS2API_VERCEL_STREAM_LEASE_TTL_SECONDS \
      VERCEL_TOKEN VERCEL_PROJECT_ID VERCEL_TEAM_ID DS2API_VERCEL_PROTECTION_BYPASS

cd /app/qwen
exec npm start
EOF
RUN chmod +x /app/start-qwen.sh

# 9. 配置 Nginx 和 Supervisor
WORKDIR /app
COPY nginx.conf /etc/nginx/sites-available/default
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

ENV PORT=8080
EXPOSE 8080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
