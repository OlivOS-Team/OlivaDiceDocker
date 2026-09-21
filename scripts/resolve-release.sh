#!/usr/bin/env bash
#
# 解析上游 release，输出完整版本清单 JSON 到 stdout。
#
# 只负责"解析"——对比、提交、触发构建都在 workflow 里做，两边职责分开。
#   bash scripts/resolve-release.sh | jq .
#   GH_TOKEN=xxx bash scripts/resolve-release.sh > release_info.json
#
set -euo pipefail

OLIVOS_REPO='OlivOS-Team/OlivOS'
ORG='OlivOS-Team'
API='https://api.github.com'
PER_PAGE=100

# 一个仓库对应一个 opk 的插件
CORE_PLUGINS=(
    OlivaDiceCore
    OlivaDiceJoy
    OlivaDiceLogger
    OlivaDiceMaster
    OlivaDiceOdyssey
    OlivaStoryCore
    ChanceCustom
)

# 一个仓库出多个 opk 的插件：仓库名 -> 资产文件名
MULTI_PLUGIN_REPO='OlivaDiceWebUI'
MULTI_PLUGIN_ASSETS=(
    'OlivaDiceWebUI.opk'
    'OlivaDiceWebUIStandalone.opk'
)

api() {
    local path="$1" out
    if [ -n "${GH_TOKEN:-}" ]; then
        out=$(curl -sfL -H "Authorization: Bearer ${GH_TOKEN}" \
                     -H 'Accept: application/vnd.github.v3+json' "${API}/${path}") || {
            echo "错误：请求 ${path} 失败（网络或 API 限流）" >&2; exit 1; }
    else
        out=$(curl -sfL -H 'Accept: application/vnd.github.v3+json' "${API}/${path}") || {
            echo "错误：请求 ${path} 失败（网络或 API 限流，可设 GH_TOKEN）" >&2; exit 1; }
    fi
    printf '%s' "$out"
}

releases_of() {
    api "repos/$1/releases?per_page=${PER_PAGE}"
}

# 最新正式版：prerelease 为 false 里 published_at 最晚的那个。
# 按时间排而不是按标签字符串排，因为 WebUI 的标签是 v20260921(1) 这种，没法做版本比较。
pick_stable() {
    jq -r '[.[] | select(.prerelease == false and .draft == false and .published_at != null)]
           | sort_by(.published_at) | last | .tag_name // ""'
}

# 预发布通道：所有 release 里 published_at 最晚的那个（含预发布）。
# 不能直接取 prerelease==true，因为有的仓库预发布比正式版还旧——OlivaDiceCore 的
# 最新预发布停在 2025-12-14，正式版已经到 2025-12-31，硬取预发布会把版本往回退。
pick_pre() {
    jq -r '[.[] | select(.draft == false and .published_at != null)]
           | sort_by(.published_at) | last | .tag_name // ""'
}

release_of_tag() {
    jq -r --arg tag "$1" '[.[] | select(.tag_name == $tag)] | first'
}

# 在 release 里找 assets 中匹配正则的第一个下载地址，没有就输出 null
asset_url() {
    jq -r --arg re "$1" '
        [.assets[] | select(.name | test($re))] | first
        | if . == null then "null" else .browser_download_url end'
}

# 组装一个插件条目：{"name","tag","file","url"}
# name 是插件身份，file 是下载下来的 opk 文件名，二者对多数插件相同但概念上分开
plugin_entry() {
    local repo="$1" plugin="$2" asset="$3" rel="$4" tag="$5" url
    url=$(printf '%s' "$rel" | asset_url "^$(printf '%s' "$asset" | sed 's/\./\\./g')\$")
    if [ "$url" = 'null' ]; then
        echo "警告：${repo} 的 ${tag} 里找不到 ${asset}，跳过" >&2
        return 0
    fi
    jq -n --arg name "$plugin" --arg tag "$tag" --arg file "$asset" --arg url "$url" \
        '{name: $name, tag: $tag, file: $file, url: $url}'
}

build_channel() {
    local mode="$1" pick="$2"

    # ---- 主程序 ----
    local rel tag one published amd64 arm64 app
    rel=$(releases_of "$OLIVOS_REPO")
    tag=$(printf '%s' "$rel" | $pick)
    if [ -z "$tag" ]; then
        echo "错误：${OLIVOS_REPO} 没取到 ${mode} 版本" >&2
        exit 1
    fi
    one=$(printf '%s' "$rel" | release_of_tag "$tag")
    published=$(printf '%s' "$one" | jq -r '.published_at // ""')

    # 同一个 tag 里上游会放两个 Linux 包：带版本号的和一个滚动别名
    # （OlivOS-Linux.zip / OlivOS-Linux-arm64.zip）。两者内容相同，但只有带版本号的
    # 那份地址是钉死的，所以按"名字里含 tag"排序优先取它，取不到才退回别名。
    # 顺序不能靠 assets 数组本来的次序，那个不保证。
    pick_linux() {
        printf '%s' "$one" | jq -r --arg tag "$tag" --argjson arm "$1" '
            [.assets[]
             | select(.name | test("\\.zip$"))
             | select(.name | startswith("OlivOS-Linux"))
             | select((.name | test("arm64|aarch64")) == $arm)]
            | sort_by(if (.name | contains($tag)) then 0 else 1 end)
            | first
            | if . == null then "null" else .browser_download_url end'
    }

    amd64=$(pick_linux false)

    # arm64：上游目前不产，等 arm64 发包的 workflow 合进去之后这里会自动接上
    arm64=$(pick_linux true)

    if [ "$amd64" = 'null' ]; then
        echo "错误：${OLIVOS_REPO} 的 ${tag} 里没有 Linux 包" >&2
        exit 1
    fi

    # 下载地址为空时写成真正的 JSON null，而不是字符串 "null"，
    # 否则 workflow 里 `.[$ch].app[$arch] // empty` 这类判断会全部失效
    app=$(jq -n --arg tag "$tag" --arg published "$published" \
                 --arg amd64 "$amd64" --arg arm64 "$arm64" \
        '{tag: $tag,
          published_at: $published,
          amd64: (if $amd64 == "null" then null else $amd64 end),
          arm64: (if $arm64 == "null" then null else $arm64 end)}')

    # ---- 插件 ----
    local plugins='[]' name entry asset
    for name in "${CORE_PLUGINS[@]}"; do
        rel=$(releases_of "${ORG}/${name}")
        tag=$(printf '%s' "$rel" | $pick)
        if [ -z "$tag" ]; then
            echo "警告：${ORG}/${name} 没取到 ${mode} 版本，跳过" >&2
            continue
        fi
        entry=$(plugin_entry "${ORG}/${name}" "$name" "${name}.opk" \
                             "$(printf '%s' "$rel" | release_of_tag "$tag")" "$tag")
        if [ -n "$entry" ]; then
            plugins=$(jq -n --argjson acc "$plugins" --argjson item "$entry" '$acc + [$item]')
        fi
    done

    rel=$(releases_of "${ORG}/${MULTI_PLUGIN_REPO}")
    tag=$(printf '%s' "$rel" | $pick)
    if [ -n "$tag" ]; then
        for asset in "${MULTI_PLUGIN_ASSETS[@]}"; do
            entry=$(plugin_entry "${ORG}/${MULTI_PLUGIN_REPO}" "${asset%.opk}" "$asset" \
                                 "$(printf '%s' "$rel" | release_of_tag "$tag")" "$tag")
            if [ -n "$entry" ]; then
                plugins=$(jq -n --argjson acc "$plugins" --argjson item "$entry" '$acc + [$item]')
            fi
        done
    else
        echo "警告：${ORG}/${MULTI_PLUGIN_REPO} 没取到 ${mode} 版本，跳过" >&2
    fi

    jq -n --argjson app "$app" --argjson plugins "$plugins" \
        '{app: $app, plugins: $plugins}'
}

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

STABLE=$(build_channel stable pick_stable)
PRE=$(build_channel pre pick_pre)

jq -n --arg generated "$GENERATED_AT" --argjson stable "$STABLE" --argjson pre "$PRE" \
    '{generated_at: $generated, stable: $stable, pre: $pre}'
