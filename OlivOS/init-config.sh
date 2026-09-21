#!/bin/bash
#
# 容器启动时的配置初始化 / 修复。
#
# 三条原则：
#   1. 只补齐，不覆盖。用户已有的配置一律保留，无论是其它平台的账号还是
#      自己调过的参数。这个脚本跑在每次启动，不能把用户的东西弄丢。
#   2. 修好之后 OlivOS 能直接跑，不需要用户先手工改配置。
#   3. 幂等。同样的输入跑多少次结果都一样。
#
# 依赖 jq（镜像里已经装了）。
#
set -euo pipefail

APP_DIR="${APP_DIR:-/app/OlivOS}"
CONF_DIR="${APP_DIR}/conf"
ACCOUNT_FILE="${CONF_DIR}/account.json"
CONFIG_FILE="${CONF_DIR}/config.json"

UIN="${LOGIN_UIN:-123456}"
MODE="${MODE:-napcat}"

log() { echo "[init-config] $*"; }

# OlivOS 自带 WebUI 的 server 默认值。之所以要在这里写全，是因为上游合并
# config.json 时用的是 dict.update()，是浅合并——只写 {"host": "..."} 会把
# 整个 server 块替换掉，port、token_path 这些就都没了。
#   OlivOS/webUI/serverAPI.py 的 DEFAULT_SERVER
#   OlivOS/core/boot/bootDataAPI.py 里 OlivOS_webUI 的 server 段
WEBUI_SERVER_DEFAULTS='{
  "auto": false,
  "type": "http",
  "host": "0.0.0.0",
  "port": 20480,
  "token_path": "./conf/webui_token.txt",
  "static_path": "./data/webui/static",
  "buffer_limit": 500,
  "plugin_page_cache": 10
}'

mkdir -p "${CONF_DIR}"

# 读一个 JSON 文件，读不到或者解析不了就返回空
read_json_or_empty() {
    local f="$1"
    [ -f "$f" ] || return 0
    jq -e . "$f" 2>/dev/null || return 0
}

# 解析不了的 JSON 先备份再重建，绝不直接删掉
backup_broken() {
    local f="$1" bak
    bak="${f}.broken-$(date +%Y%m%d%H%M%S)"
    mv "$f" "$bak"
    log "警告：$(basename "$f") 不是合法 JSON，已备份为 $(basename "$bak")，将重新生成"
}

# ---------- 1. WebUI 监听地址 ----------
# 容器里把 WebUI 绑在 127.0.0.1 等于没人能访问，所以这里强制写成 0.0.0.0。
init_webui_host() {
    local current base out
    current=$(read_json_or_empty "${CONFIG_FILE}")
    if [ -f "${CONFIG_FILE}" ] && [ -z "${current}" ]; then
        backup_broken "${CONFIG_FILE}"
        current=""
    fi
    # 空文件就从空对象起手
    if [ -z "${current}" ]; then base='{}'; else base="${current}"; fi

    out=$(printf '%s' "${base}" | jq --argjson d "${WEBUI_SERVER_DEFAULTS}" '
        .models = (
            (if ((.models // null) | type) == "object" then .models else {} end)
            | .OlivOS_webUI = (
                (if ((.OlivOS_webUI // null) | type) == "object" then .OlivOS_webUI else {} end)
                | .server = ($d + (.server // {}) + {host: "0.0.0.0"})
              )
        )
    ')

    if [ "${current}" = "$(printf '%s' "${out}")" ]; then
        log "WebUI 监听地址已是 0.0.0.0，无需改动"
        return
    fi

    printf '%s\n' "${out}" > "${CONFIG_FILE}"
    log "已写入 ${CONFIG_FILE}：WebUI 改为监听 ${WEBUI_HOST:-0.0.0.0}（端口沿用配置里的值，默认 20480；被占用时 OlivOS 会自己往后找）"
}

# ---------- 2. 账号配置 ----------
# MODE 决定要保证存在哪个账号。这里只保证"这个账号在"，不动其它账号——
# 用户可能同时配了 kook、别的 QQ 或者别的接入方式，那些必须原样留着。
init_account() {
    local host entry current base out
    if [ "${MODE}" = "llbot" ]; then
        host="http://llbot"
    else
        host="http://napcat"
    fi

    entry=$(jq -n --argjson id "${UIN}" --arg host "${host}" '{
        id: $id,
        password: "",
        sdk_type: "onebot",
        platform_type: "qq",
        model_type: "default",
        server: {
            auto: false,
            type: "port",
            host: $host,
            port: 5700,
            access_token: "7777777"
        },
        extends: {},
        debug: false
    }')

    current=$(read_json_or_empty "${ACCOUNT_FILE}")
    if [ -f "${ACCOUNT_FILE}" ] && [ -z "${current}" ]; then
        backup_broken "${ACCOUNT_FILE}"
        current=""
    fi
    if [ -z "${current}" ]; then base='{}'; else base="${current}"; fi

    # 已有同 id 的条目就在它基础上补缺（$entry + . 是"以现有值为准"，
    # 只补上现有条目缺的键），没有才追加。绝不重建整个数组。
    out=$(printf '%s' "${base}" | jq --argjson e "${entry}" '
        .account = (
            (if ((.account // null) | type) == "array" then .account else [] end)
            | if any(.[]; (.id | tostring) == ($e.id | tostring))
              then map(if (.id | tostring) == ($e.id | tostring) then ($e + .) else . end)
              else . + [$e]
              end
        )
    ')

    if [ "${current}" = "$(printf '%s' "${out}")" ]; then
        log "账号 ${UIN} 已存在，无需改动（其它平台的账号保持原样）"
        return
    fi

    printf '%s\n' "${out}" > "${ACCOUNT_FILE}"
    log "已写入 ${ACCOUNT_FILE}：确保账号 ${UIN}（${MODE}）存在，其余账号保持不动"
}

# ---------- 3. 登录端配置 ----------
# 只在文件不存在时生成，已有的一律不碰——用户可能在上面调过参数。
init_login_config() {
    local target template dir
    dir="${NAP_CONFIG_DIR:-/app/napcat/config}"
    mkdir -p "${dir}"

    if [ "${MODE}" = "llbot" ]; then
        target="${dir}/config_${UIN}.json"
        template="${BACKUP_DIR:-/release-backup}/napcat/config/llbot-config-example.json"
    else
        target="${dir}/onebot11_${UIN}.json"
        template="${BACKUP_DIR:-/release-backup}/napcat/config/napcat-config-example.json"
    fi

    if [ -f "${target}" ]; then
        log "登录端配置已存在，保持不动：${target}"
        return
    fi

    if [ ! -f "${template}" ]; then
        log "警告：找不到模板 ${template}，跳过登录端配置"
        return
    fi

    cp "${template}" "${target}"
    log "已生成登录端配置：${target}"
}

init_webui_host
init_account
init_login_config
