#!/bin/bash
#
# OlivOS 容器入口。
#
# 镜像里 /release-backup 是干净的程序副本，/app/OlivOS 是容器内的运行目录。
# 每次启动把两边比一遍、不一样的覆盖过去：升级能生效，目录被清空也能自愈，
# 但不会每次启动都重写那个 47MB 的二进制。
#
# /app/OlivOS 本身不挂载，只有 conf/ plugin/ logfile/ data/ 这些数据子目录挂出来，
# 所以这里同步的都是容器内的文件，碰不到用户的数据。
#
set -e

APP_DIR=/app/OlivOS
BACKUP_DIR=/release-backup
PLUGIN_DIR="${APP_DIR}/plugin/app"

log() { echo "[entrypoint] $*"; }

# ---------- 1. 检查旧版挂载方式 ----------
# 新版 compose 只挂数据子目录，/app/OlivOS 是容器内的运行目录。如果有人还按老办法
# 把整个目录挂进来，里面可能躺着一个和可执行文件同名的 OlivOS/ 目录（源码模式
# 留下的 Python 包），下面拷贝时 cp 会把二进制塞进那个目录里，程序起来找不到文件。
# 这种情况直接报错说清楚，不替用户删东西。
if [ -d "${APP_DIR}/OlivOS" ]; then
    log "错误：${APP_DIR}/OlivOS 是个目录，与可执行文件同名，程序起不来"
    log "看起来还在用旧版 compose（整个 /app/OlivOS 挂进来）。请按 README 的迁移步骤把数据搬到 data/ 下"
    exit 1
fi

# ---------- 2. 同步程序文件 ----------
mkdir -p "${APP_DIR}" "${PLUGIN_DIR}"

sync_file() {
    local src="$1" dst="$2"
    if [ ! -f "${dst}" ] || ! cmp -s "${src}" "${dst}"; then
        cp -f "${src}" "${dst}"
        log "已更新 $(basename "${dst}")"
    fi
}

sync_file "${BACKUP_DIR}/OlivOS" "${APP_DIR}/OlivOS"
chmod +x "${APP_DIR}/OlivOS"

for opk in "${BACKUP_DIR}"/plugin/app/*.opk; do
    [ -e "${opk}" ] || continue
    sync_file "${opk}" "${PLUGIN_DIR}/$(basename "${opk}")"
done

# ---------- 3. 配置初始化 ----------
# 账号、WebUI 监听地址、登录端配置都交给这个脚本。它只补缺不覆盖——
# 用户自己配的其它平台账号（比如 kook）、改过的端口，都不会被弄丢。
export APP_DIR BACKUP_DIR
olivos-init-config
# 必须用 exec：否则 PID 1 是这个 shell，停止容器时 SIGTERM 发给 shell 而不是
# OlivOS，宽限期白等，最后整个 cgroup 被 SIGKILL，骰子没机会落盘。
cd "${APP_DIR}"
log "启动 OlivOS"
exec ./OlivOS "$@"
