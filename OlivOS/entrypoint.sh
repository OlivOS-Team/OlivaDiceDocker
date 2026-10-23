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

# ---------- 1. 清理源码模式留下的残留 ----------
# 现在是留给老用户的兜底：更早的镜像是在容器里 git clone 源码然后 pip install
# 跑的，那时候 /app/OlivOS 是用户挂载进来的，里面躺着一整套源码。最关键的一条：
# 那套源码里的 OlivOS/ 是个目录（Python 包），而现在的 OlivOS 是个可执行文件，
# 两者同名。不先删掉的话，下面拷贝时 cp 会把二进制塞进那个目录里面，
# 程序起来就是找不到文件。
#
# 新版 compose 已经不再把 /app/OlivOS 挂进来了，正常情况下这整段都不会命中。
if [ -d "${APP_DIR}/OlivOS" ]; then
    log "清理源码模式残留：OlivOS/ 目录与新方案的可执行文件同名"
    rm -rf "${APP_DIR}/OlivOS"
fi

# 其余都是纯源码/构建期产物，新方案用不到
for leftover in main.py setup.py pyproject.toml OlivOS.spec OlivOS.egg-info hook script __pycache__; do
    if [ -e "${APP_DIR}/${leftover}" ]; then
        log "清理源码模式残留：${leftover}"
        rm -rf "${APP_DIR}/${leftover}"
    fi
done

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
