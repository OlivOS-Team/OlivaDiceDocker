# OlivaDiceDocker

在 Linux 上用 Docker 部署 [OlivOS](https://github.com/OlivOS-Team/OlivOS) + [NapCat](https://github.com/NapNeko/NapCatQQ)，附带青果骰的常用核心插件。

镜像不依赖上游源码。构建时直接下载上游 release 里编译好的产物——主程序用 PyInstaller 打好的单文件二进制，插件用各自 release 里的 opk。所以构建很快，镜像里也不需要 Python 环境。

镜像地址：`ghcr.io/olivos-team/olivadicedocker`

## 镜像标签

- `latest` / `stable` / `<版本号>` —— 正式发布通道，对应上游最新的正式版
- `pre` / `<版本号>` —— 预发布通道，对应上游最新的预发布版

`latest` 始终指向正式版，预发布通道不会去动它。

## 用 docker-compose 部署

推荐用这种方式。仓库里的 `docker-compose.yml` 是一份 NapCat 的组装示例，可以直接拿来用。

组装出来是两个容器：`olivos-app` 跑 OlivOS 本体，`napcat` 负责 QQ 登录，两者在同一张 bridge 网络上按服务名互相访问。

对外开的端口：

- **20480** —— OlivOS 自带的 WebUI
- **6099** —— NapCat 的 WebUI，扫码登录用的

两个容器没有启动顺序要求，`olivos-app` 连不上 NapCat 时会自己重试。

### 准备

先装好 Docker 和 Docker Compose，然后建目录、把 compose 和 `.env` 放进去：

```bash
mkdir -p -m 755 /opt/OlivaDiceDocker
cd /opt/OlivaDiceDocker

wget https://raw.githubusercontent.com/OlivOS-Team/OlivaDiceDocker/refs/heads/main/docker-compose.yml
echo 'ACCOUNT=你的骰娘QQ号' > .env
```

`.env` 里的 `ACCOUNT` 是骰娘账号，必须改掉。

### 启动

```bash
docker compose up -d      # 启动
docker compose ps         # 查看状态
docker compose logs -f    # 跟踪日志
docker compose down       # 停止
```

更新到新版本：

```bash
docker compose pull
docker compose up -d
```

程序文件在容器启动时会自动比对更新，配置和数据都留着，不会被覆盖。

### 登录

容器日志里能看到二维码，也可以直接访问 NapCat 的 WebUI 扫码登录，端口 6099。

## 用 docker run 部署

不想用 compose 的话，等价的手工方式是这样。两个容器要在同一张网络上，否则 OlivOS 找不到 NapCat。

```bash
ACCOUNT=你的骰娘QQ号

docker network create olivos

# 登录端
docker run -d \
  --name napcat \
  --network olivos \
  --hostname olivos-${ACCOUNT} \
  -p 6099:6099 \
  -e ACCOUNT=${ACCOUNT} \
  -e MODE=olivos \
  -v "$PWD/napcat/config:/app/napcat/config" \
  -v "$PWD/napcat/QQ_DATA:/app/.config/QQ" \
  -v "$PWD/OlivOS:/app/OlivOS" \
  mlikiowa/napcat-docker:latest

# OlivOS 本体
# 名字要用 olivos-app：自动生成的 OneBot 配置里指向的是
# http://olivos-app:55001/OlivOSMsgApi/...，NapCat 得靠这个名字找到它。
docker run -d \
  --name olivos-app \
  --network olivos \
  -p 20480:20480 \
  -e LOGIN_UIN=${ACCOUNT} \
  -e MODE=napcat \
  -v "$PWD/OlivOS:/app/OlivOS" \
  -v "$PWD/napcat/config:/app/napcat/config" \
  ghcr.io/olivos-team/olivadicedocker:latest
```

两个容器没有启动顺序要求，谁先起来都行——OlivOS 连不上 NapCat 时会自己重试。

## 管理面板

这里有两个不同的 WebUI，别混了。

**OlivOS 自带的 WebUI** —— 默认监听 **20480**，compose 里映射的就是这个。登录要输令牌，令牌在 `conf/webui_token.txt`，第一次启动时自动生成。

有两点要注意：

- 容器启动时初始化脚本会自动把 `models.OlivOS_webUI.server.host` 写成 `0.0.0.0`。上游默认绑 `127.0.0.1`，容器里那样映射出去也没人连得上，所以替你改了。只动 host 这一个字段，你自己设过的端口、令牌路径都保留。
- 这个功能目前只在**预发布通道**（0.11.90-alpha.x）里有，稳定版 0.11.81 还没合进去。用 stable 的话这个端口是空的。

**OlivaDiceWebUI 插件** —— 镜像里带了它的两个版本，跟上面那个是两回事：

- **官方接入版**（`OlivaDiceWebUI.opk`）：做成 OlivOS 自带 WebUI 里的一个页面，自己不占端口。前提是上面那个 WebUI 能访问。
- **独立服务版**（`OlivaDiceWebUIStandalone.opk`）：自己监听 HTTP 端口，默认 **8765**，不依赖 OlivOS 的 WebUI。compose 里默认没映射，需要的话把那行 `8765:8765` 的注释打开。

独立版的监听地址和端口由插件自己维护，在面板里改就行。**不要**去设 `OLIVADICE_STANDALONE_WEBUI_PORT` 之类的环境变量——环境变量优先级高于面板里的设置，一设就再也改不动了。

## 数据目录

所有数据都在 compose 文件同级的 `OlivOS/` 目录：

- `conf/` —— OlivOS 自身配置，第一次启动自动生成
- `plugin/app/` —— 插件 opk，镜像里带的那些会在启动时更新
- `plugin/data/` —— 骰子数据、人物卡、存档，升级不会动

你自己放进 `plugin/app/` 的第三方插件不会被碰，只有镜像里固定的那几个会被更新。

## 配置是怎么生成的

容器每次启动都会跑一遍初始化脚本，原则是**只补缺，不覆盖**：

- `conf/config.json` —— 确保 WebUI 监听地址是 `0.0.0.0`。只改这一个字段，端口、令牌路径、以及其它模型的配置都保持你设的值。
- `conf/account.json` —— 确保当前 `MODE` 对应的账号在。**已有账号一律保留**：你另外配的 kook、别的 QQ、别的接入方式都不会被删掉；同 id 的条目也只在缺字段时补齐，不会整个替换。
- NapCat / LLBot 的登录端配置 —— 文件不存在才生成，已存在的一律不动。

配置如果是坏的 JSON（比如手工改崩了），会先备份成 `*.broken-<时间戳>` 再重建，不会直接丢掉。整个脚本是幂等的，重复启动不会有额外改动。

如果之前用的是容器内拉源码的老方案，数据目录里会残留一整套源码。入口脚本启动时会先清掉这些——特别是那个 `OlivOS/` 目录，它和新的可执行文件同名，不清掉会直接导致程序起不来。`conf/` 和 `plugin/data/` 都会原样保留。

## 更新机制

镜像只在两种情况下发新版：

1. 上游 OlivOS 主程序发了新版本
2. OlivaDiceCore 发了新版本

其余插件（Joy / Logger / Master / Odyssey / StoryCore / ChanceCustom / WebUI）的新版本不会单独触发构建，但每次构建时都会连同当时的最新版本一起打包进去。这么定是因为 WebUI 一天能发两三次，全都要触发构建的话镜像仓库会被刷屏。

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

**推 Docker Hub（可选）** —— 需要一个官方 Docker Hub 账号。在仓库的 Variables 里加一个 `DOCKERHUB_REPO`（值形如 `账号名/仓库名`），再在 Secrets 里配 `DOCKERHUB_USERNAME` 和 `DOCKERHUB_TOKEN`。三个都齐了就会在推 GHCR 的同时也推一份；任何一个没配就只推 GHCR，工作流会自动跳过，不会报错。

发新版本不需要手动打 tag，`sync-release` 检测到上游更新会自动跑完整条链路。

## 许可

AGPL-3.0
