FROM ubuntu:24.04

# 上游的 Linux 产物是在 ubuntu-latest 上打出来的 PyInstaller 单文件。
# 基础镜像跟着用 Ubuntu 24.04，免得 glibc 比构建环境还旧导致二进制跑不起来。
# 不再需要 Python 和 pip——运行时全部打包在那个 47MB 的可执行文件里了。

ENV TZ=Asia/Shanghai

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        unzip \
        jq \
        tzdata \
        libstdc++6 \
        libsqlite3-0 \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

ARG BUILD_TYPE=stable
ARG TARGETARCH=amd64

# 程序一律先落在 /release-backup，启动时由入口脚本同步进数据目录。
# 好处是镜像里永远持有一份干净副本，用户把挂载目录清空了也能自愈。
RUN mkdir -p /release-backup/plugin/app /release-backup/napcat/config

COPY release_info.json /tmp/release_info.json

# ---- 主程序 ----
# 上游产物是按架构分的 PyInstaller 单文件，按 TARGETARCH 从清单里挑。
# arm64 的地址上游目前是 null，构建工作流会在那种情况下只发 amd64，
# 不会把构建憋死在这里。
RUN set -eux; \
    APP_URL=$(jq -r --arg bt "$BUILD_TYPE" --arg arch "$TARGETARCH" \
        '.[$bt].app[$arch] // empty' /tmp/release_info.json); \
    if [ -z "$APP_URL" ]; then \
        echo "清单里没有 ${BUILD_TYPE} 通道 ${TARGETARCH} 架构的主程序下载地址"; \
        exit 1; \
    fi; \
    echo "主程序来源: ${APP_URL}"; \
    wget -q -O /tmp/olivos.zip "$APP_URL"; \
    unzip -q /tmp/olivos.zip -d /release-backup; \
    rm -f /tmp/olivos.zip; \
    chmod +x /release-backup/OlivOS

# ---- 核心插件 ----
# opk 是纯 Python 的 zip 包，跟架构无关，所以两个平台共用同一批文件。
RUN set -eux; \
    jq -r --arg bt "$BUILD_TYPE" '.[$bt].plugins[].url' /tmp/release_info.json > /tmp/plugins.txt; \
    cd /release-backup/plugin/app; \
    while IFS= read -r url; do \
        echo "插件来源: ${url}"; \
        wget -q "$url"; \
    done < /tmp/plugins.txt; \
    ls -l /release-backup/plugin/app

# ---- 登录端配置模板 ----
# 直接用仓库里的文件，不再从 raw.githubusercontent 现拉，构建时少一层网络依赖
COPY NapCat/config-example.json /release-backup/napcat/config/napcat-config-example.json
COPY LLBot/config-example.json /release-backup/napcat/config/llbot-config-example.json

COPY OlivOS/entrypoint.sh /usr/local/bin/olivos-entrypoint
RUN chmod +x /usr/local/bin/olivos-entrypoint

WORKDIR /app/OlivOS
ENTRYPOINT ["olivos-entrypoint"]
