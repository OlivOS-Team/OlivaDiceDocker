# OlivaDiceDocker

在 Linux 上用 docker-compose 快速组装 [OlivOS](https://github.com/OlivOS-Team/OlivOS) + [NapCat](https://github.com/NapNeko/NapCatQQ) 或 [LLBot](https://github.com/LLOneBot/LuckyLilliaBot)，附带青果骰的常用核心插件。

和旧项目最大的区别：**不再在构建时拉取上游源码**。镜像直接消费上游编译好的 release 产物——主程序用 PyInstaller 打好的单文件二进制，插件用各自 release 里的 opk。构建从几分钟降到几十秒，也不再需要 Python 环境。

[GHCR](https://github.com/OlivOS-Team/OlivaDiceDocker/pkgs/container/olivadicedocker) · 镜像地址 `ghcr.io/olivos-team/olivadicedocker`

> 目前只在 GHCR 上发布。Docker Hub 那边配好之后会同步推一份 `shiaworkshop/olivadice`，两个仓库的 tag 和内容完全一致，用哪个都行。

## 镜像标签

- `latest` / `stable` / `<版本号>` —— 正式发布通道，对应上游最新的正式版
- `pre` / `<版本号>` —— 预发布通道，对应上游最新的预发布版

`latest` 始终指向正式版，预发布通道不会去动它。

## 一键部署

```bash
bash <(curl -sL olivos.dice.zone)
```

交互式引导，按提示选版本渠道、登录方式和要部署的数量即可。

### 参数用法

```bash
bash <(curl -sL olivos.dice.zone) -a 123456 -c stable -m napcat -n 1
```

- `-a`：骰娘 QQ 号
- `-c`：版本渠道（latest / stable / pre，默认 latest）
- `-m`：登录方式（napcat / llbot，默认 napcat）
- `-n`：部署数量（1-99，默认 1）
- `-y`：静默模式，跳过确认

## 手动部署

### 准备工作

装好 Docker 和 Docker Compose。然后建目录、写 `.env`：

```bash
mkdir -p -m 755 /opt/OlivaDiceDocker
cd /opt/OlivaDiceDocker

wget https://raw.githubusercontent.com/OlivOS-Team/OlivaDiceDocker/refs/heads/main/docker-compose.yml
echo 'ACCOUNT=你的骰娘QQ号' > .env
```

`.env` 里的 `ACCOUNT` 就是骰娘账号，必须改掉。

### 运行

```bash
docker compose up -d      # 启动
docker compose ps         # 查看状态
docker compose down       # 停止
```

更新到新版本：

```bash
docker compose pull
docker compose up -d
```

程序文件在容器启动时会自动比对更新，配置和数据都留着，不用担心被覆盖。

### 登录

容器日志里能看到二维码，也推荐直接访问 NapCat 或 LLBot 的 WebUI 扫码登录，端口 6099 起。

## 管理面板

镜像里带了 OlivaDiceWebUI 的两个版本：

- **独立服务版**（`OlivaDiceWebUIStandalone.opk`）：自己监听 HTTP 端口，默认 **8765**，compose 里已经映射好了。这是容器环境下实际能用的那个。
- **官方接入版**（`OlivaDiceWebUI.opk`）：挂在 OlivOS 自带的 WebUI 窗口里。OlivOS 那个窗口是桌面版的 pywebview，无头容器没有图形界面，所以这个版本装是装了，但在这个场景下用不上。

独立版的监听地址和端口由插件自己维护，在面板里改就行。**不要**去设 `OLIVADICE_STANDALONE_WEBUI_PORT` 之类的环境变量——环境变量优先级高于面板里的设置，一设就再也改不动了。

## 数据目录

所有数据都在 compose 文件同级的 `OlivOS/` 目录：

- `conf/` —— OlivOS 自身配置，第一次启动自动生成
- `plugin/app/` —— 插件 opk，镜像里带的那些会在启动时更新
- `plugin/data/` —— 骰子数据、人物卡、存档，升级不会动

你自己放进 `plugin/app/` 的第三方插件不会被碰，只有镜像里固定的那几个会被更新。

## 从 OlivOS-Docker 迁移

把 compose 里的镜像名从 `shiaworkshop/olivos` 换成 `ghcr.io/olivos-team/olivadicedocker`，重新拉取启动即可。

旧方案是在容器里克隆源码跑的，数据目录里躺着一整套源码。新入口脚本启动时会先把这些清掉——特别是那个 `OlivOS/` 目录，它和新的可执行文件同名，不清掉会直接导致程序起不来。`conf/` 和 `plugin/data/` 都会原样保留。

## 更新机制

镜像只在两种情况下发新版：

1. 上游 OlivOS 主程序发了新版本
2. OlivaDiceCore 发了新版本

其余插件（Joy / Logger / Master / Odyssey / StoryCore / ChanceCustom / WebUI）的新版本不会单独触发构建，但每次构建时都会连同当时的最新版本一起打包进去。这么定是因为 WebUI 一天能发两三次，全都要触发构建的话 Docker Hub 上会被刷屏。

版本信息全部记在 `release_info.json` 里，由 `scripts/resolve-release.sh` 解析上游生成。同一个清单构建出来的镜像，每个组件的版本都是固定的，不会出现同一个 tag 拉两次内容不一样的情况。

## 架构说明

目前只发布 `linux/amd64`。

上游 OlivOS 的构建流程只产出 x86-64 的 Linux 包，暂时没有 arm64。构建流程已经按双架构写好了——清单里 `arm64` 那一格一旦有地址，镜像就会自动开始发 arm64，不需要再改任何配置。

## 维护说明

镜像发布全走 Actions，用到的两个工作流：

- `sync-release.yml` 每 6 小时跑一次，解析上游版本写进 `release_info.json`。只有 OlivOS 主程序或 OlivaDiceCore 出了新版才会提交清单并触发构建，其余插件的新版本只是在构建时一并带上。
- `docker-publish.yml` 读清单构建镜像并推送。也可以手动跑，指定通道即可。

需要配的东西：

**`GH_PAT`（必需）** —— `sync-release` 要往仓库里提交清单，还要触发构建工作流，这两件事默认的 `GITHUB_TOKEN` 都做不了。需要一个带 `repo` 和 `workflow` 权限的 PAT，配在仓库的 Actions secrets 里。

**GHCR 包可见性（首次必须手动改一次）** —— GHCR 的包**首次推送后默认是私有的**，这时候用户 `docker pull` 会拿到 403。推完第一个镜像后去 package 的 Settings 里把 visibility 改成 public。

**`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`（可选）** —— 两个都配了就会在推 GHCR 的同时也推一份到 Docker Hub；没配就只推 GHCR，工作流会自动跳过 Docker Hub 那一步，不会报错。

发新版本不需要手动打 tag，`sync-release` 检测到上游更新会自动跑完整条链路。

## 许可

AGPL-3.0
