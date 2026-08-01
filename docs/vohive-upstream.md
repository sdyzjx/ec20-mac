# Vohive 上游固定、同步与许可证说明

更新日期：2026-08-01

## 1. 当前固定版本

Vohive 源码位于父仓库的 `third_party/vohive/`，通过 Git subtree 以 `--squash` 方式导入：

| 项目 | 固定值 |
|---|---|
| 上游仓库 | `https://github.com/1239t/vohive.git` |
| 上游提交 | `0965af3d3c59bf51ef09ebd7edcafc06f516321f` |
| subtree 目录 | `third_party/vohive` |
| 父仓库导入提交 | `1dcfa9035a4dd0aa9bf9223fdb826b34d10b7a23` |
| squash 内容提交 | `ed44aab0d1a0e51fead53b62e231c11de2a20ae4` |

导入提交的第二个 parent 是 squash 内容提交；其 commit message 保存：

```text
git-subtree-dir: third_party/vohive
git-subtree-split: 0965af3d3c59bf51ef09ebd7edcafc06f516321f
```

在导入点，上游 tree 与父仓库中的 subtree tree 都是：

```text
5b69a7d1b8166d499cc2a85ad1c5c44aed174af8
```

最初导入等价于以下命令。现有工作树已经包含该 subtree，**不要再次执行 `subtree add`**：

```sh
git subtree add \
  --prefix=third_party/vohive \
  https://github.com/1239t/vohive.git \
  0965af3d3c59bf51ef09ebd7edcafc06f516321f \
  --squash
```

## 2. 父仓库历史与上游历史不可混淆

`third_party/vohive` 不是 submodule，也不是一个嵌套 Git 仓库。它没有独立 `.git`；目录内文件
属于当前 EC20 macOS 父仓库。因此：

- `1dcfa90...` 是父仓库的 subtree merge，不是 Vohive 上游提交；
- `ed44aab...` 是 `git subtree --squash` 生成的内容提交，也不是上游提交；
- `0965af3...` 才是本次固定的 Vohive 上游身份；
- `git -C third_party/vohive rev-parse HEAD` 仍会得到父仓库 HEAD，不能用它证明上游版本；
- 不要在 `third_party/vohive` 中执行普通 `git pull`、创建新的 `.git`，或把父仓库 merge/squash
  hash 填进 Vohive 的 upstream revision 字段；
- 本项目的 Darwin 修改应作为父仓库中路径受限、可审阅的独立提交；`--squash` 不会保留完整
  Vohive 上游提交历史，也不会改变上游许可证。

若要把 Darwin 修改贡献给上游，应从真正的上游 commit/branch 创建独立工作分支并移植补丁，
不要直接把父仓库 subtree split 的合成历史当作上游分支推送。

## 3. Provenance 审计

先确认工作树状态，避免把未提交的本地补丁误判成上游内容：

```sh
git status --short
git show -s --format=fuller 1dcfa9035a4dd0aa9bf9223fdb826b34d10b7a23
git show -s --format='%B' ed44aab0d1a0e51fead53b62e231c11de2a20ae4
```

若本地还没有上游 remote，可添加专用 remote；如果已经存在，先核对 URL，不要静默改指向：

```sh
if git remote get-url vohive-upstream; then
  test "$(git remote get-url vohive-upstream)" = \
    "https://github.com/1239t/vohive.git"
else
  git remote add vohive-upstream https://github.com/1239t/vohive.git
fi
git fetch --no-tags vohive-upstream
```

URL 检查失败时应先人工确认，不要自动执行 `set-url` 把一个同名 remote 改到其他仓库。

验证固定 commit 与导入点内容完全一致：

```sh
git cat-file -e 0965af3d3c59bf51ef09ebd7edcafc06f516321f^{commit}
git rev-parse 0965af3d3c59bf51ef09ebd7edcafc06f516321f^{tree}
git rev-parse 1dcfa9035a4dd0aa9bf9223fdb826b34d10b7a23:third_party/vohive
```

最后两个命令在本次固定版本应同时输出：

```text
5b69a7d1b8166d499cc2a85ad1c5c44aed174af8
```

查看导入以后父仓库对 subtree 的本地修改：

```sh
git diff --name-status \
  1dcfa9035a4dd0aa9bf9223fdb826b34d10b7a23 \
  -- third_party/vohive

git log --oneline -- third_party/vohive
```

tree 相等只证明导入点的文件内容相同，不证明许可证允许目标用途，也不替代对 Git 对象、依赖
锁文件和发布产物的安全审计。

## 4. 同步新的上游版本

上游同步必须使用经过审阅的精确 SHA，不直接追随会移动的 `main`：

```sh
git status --short
git fetch --no-tags vohive-upstream

git log --oneline \
  0965af3d3c59bf51ef09ebd7edcafc06f516321f..vohive-upstream/main
git diff --stat \
  0965af3d3c59bf51ef09ebd7edcafc06f516321f..vohive-upstream/main
git diff --name-status \
  0965af3d3c59bf51ef09ebd7edcafc06f516321f..vohive-upstream/main
```

完成代码、许可证、`go.mod`/`go.sum`、`web/package-lock.json`、构建流程和 Darwin 冲突审计后，
记下审核过的完整新 SHA，再执行：

```sh
git subtree pull \
  --prefix=third_party/vohive \
  vohive-upstream \
  <reviewed-upstream-full-sha> \
  --squash
```

同步前工作树应干净，并保留可恢复分支。同步产生的冲突必须在父仓库解决；完成后重新运行
provenance、许可证、前端、Go/Darwin build 和功能测试，并在提交说明中同时记录旧/新上游 SHA。
不要把本项目的 Darwin 补丁伪装成上游自带代码，也不要仅更新本文 SHA 而没有实际 subtree
同步。

## 5. 许可证与 Required Notice

固定版本的 Vohive 使用 **PolyForm Noncommercial License 1.0.0**。它允许的用途以许可证文本
定义的非商业用途为限；`git subtree --squash`、修改代码或与本应用打包都不会把它转换为宽松
开源许可证。本项目若计划销售、收费部署、随商业硬件分发或用于预期商业应用，必须在发布前向
权利人取得适用的商业授权。本文不是法律意见。

Vohive 的 `LICENSE` 必须随源码和适用的分发产物保留，且分发者必须保留许可证要求的原文：

```text
Required Notice: Copyright iniwex5 (https://github.com/iniwex5/vohive)
```

不得删除、改写或用父仓库版权声明替代 Required Notice。macOS App 的 Third-Party Notices、源码
分发包和其他适用载体都应包含 PolyForm 条款或其 URL 以及上述 Required Notice。Vohive 所含依赖
和 vendored `third_party/sipgo` 还有各自许可证，仍需独立生成依赖清单并审计；保留 Vohive
LICENSE 不等于已经满足所有第三方许可证。

## 6. Go 1.26.3 与 toolchain

固定上游的 `go.mod` 声明：

```go
go 1.26.3
```

当前文件没有单独的 `toolchain` directive，但默认 `GOTOOLCHAIN=auto` 时，较旧的 Go launcher
可自动选择或下载满足 `go 1.26.3` 的 toolchain。本机外层 `go version` 是 Go 1.26.0，而在该
module 中查询 `go env GOVERSION` 已选择 Go 1.26.3。这个下载/选择行为必须在 CI 和离线构建中
显式管理，不能通过把上游 `go` directive 降到本机版本来绕过。

审计命令：

```sh
cd third_party/vohive
GOWORK=off go env GOMOD GOVERSION GOTOOLCHAIN
GOWORK=off go mod verify
```

可重复构建应固定已批准的 Go 1.26.3 toolchain、使用 `GOWORK=off` 避免父目录 workspace 注入，
并保留上游 `go.sum`。自动 toolchain 下载和 module 下载都属于供应链网络访问，应在可审计的 CI
步骤中完成并缓存；不要在未审阅的同步提交里运行 `go mod tidy` 后直接接受大范围依赖变化。

## 7. 前端 `web/dist` 构建前置

subtree 不包含生成的 `web/dist` 或 `internal/web/dist`。后端文件 `internal/web/fs.go` 使用：

```go
//go:embed all:dist
```

因此在构建 `cmd/vohive` 或运行会编译 `internal/web` 的 Go test 前，必须先构建 Vue/Vite 前端，
并把结果同步到 Go package 所在目录。
上游 release workflow 使用 Node.js 22；本地应优先保持相同 major，并使用 lockfile：

```sh
cd third_party/vohive
npm ci --prefix web
npm run build --prefix web
rm -rf internal/web/dist
mkdir -p internal/web
cp -R web/dist internal/web/dist
```

等价的上游入口是：

```sh
make frontend-dist
```

`web/dist` 是 Vite 的第一阶段产物，`internal/web/dist` 才是 `go:embed` 实际读取的位置。两者都是
生成物，默认不应提交；打包/CI 应从 `web/package-lock.json` 重建并在 backend build 之前检查
目录存在。即使前端准备完成，固定上游仍不能**原样**通过 Darwin backend build；本仓库通过
`ae5894b` 及后续 Darwin provider 补丁解决了当前已知编译阻塞，构建入口见
[Vohive Darwin 后端构建说明](vohive-darwin-build.md)。

## 8. 固定上游的 Darwin 阻塞与本地处理状态

以下是固定上游在 macOS/Darwin 上的已知阻塞，不是完整清单。准备好前端资源并应用本仓库本地
补丁后，下面的 backend 编译门禁现在可以通过：

```sh
cd third_party/vohive
GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
  go build -tags "with_utls nomsgpack" \
  -o /tmp/vohive-darwin-audit ./cmd/vohive
```

### 8.1 `SO_BINDTODEVICE`

`internal/proxy/server/server.go`、`internal/netprobe/netprobe.go` 和 `internal/qmi/manager.go` 直接使用
Linux `syscall.SO_BINDTODEVICE`，该常量和语义在 Darwin 不存在，造成编译失败。Darwin 实现需要
平台文件/build tags，并使用按地址族的 `IP_BOUND_IF`/`IPV6_BOUND_IF` 及 interface index；绑定
失败必须 fail closed，不能静默从 Wi-Fi 出口发送。

本地状态：`ae5894b` 新增 `internal/netbind`，三处调用均已迁移；Darwin lo0 的 IPv4/IPv6
getsockopt 测试和 Linux 交叉编译通过。这解决了 socket binding 编译与基础语义，不代表蜂窝
`enX`、DNS 和路由控制已经完成。

### 8.2 `swu-go` 的 Linux error queue

间接依赖 `github.com/1239t/swu-go v0.0.3` 的 IPsec 代码使用 Linux `MSG_ERRQUEUE` 机制，包括
`unix.SockExtendedErr`、`IP_RECVERR`、`IPV6_RECVERR` 和 `syscall.MSG_ERRQUEUE`。这些符号在
Darwin 不可用，当前会阻断编译。需要由依赖提供 Darwin build tags/实现，或在 macOS 能力矩阵中
明确隔离依赖该路径的 VoWiFi/IPsec 功能；不能用空成功实现掩盖功能缺失。

本地状态：仓库固定导入 `swu-go` v0.0.3（上游
`c4fb4016432c3851d2f4e6ba44261368b01a2be3`），并以 build tag 隔离 Linux error queue。
非 Linux 明确没有可选 PMTU/ICMP error-queue listener；Darwin 可以编译，但 VoWiFi/IPsec 不因此
变成完整支持。来源和许可证见 [构建说明](vohive-darwin-build.md)。

### 8.3 udev/netlink 与 sysfs

`internal/device/udev.go` 订阅 `unix.NETLINK_KOBJECT_UEVENT`，这是 Linux udev/netlink 路径，
Darwin 没有对应常量或事件源。`internal/device/discovery_compat.go` 和
`internal/device/qmi_static_discovery.go` 还直接扫描 `/sys/bus/usb/devices`、`/sys/class/wwan`、
`ttyUSB*` 和 `cdc-wdm*`。netlink 部分是编译阻塞；sysfs 扫描即使被修到能够编译，在 macOS
运行时也不会发现设备。

Darwin 端必须以 build tags 隔离这些文件，并通过 IOKit/IORegistry 或本项目 `ec20d` 的版本化
API 实现 device snapshot/watch；不要在 macOS 伪造 `/sys`、udev 或 `/dev/cdc-wdm*`。

本地状态：udev loop 已按平台隔离；`fbd8d42` 把认证的 `ec20d` snapshot 注入
`CompatibleModem`、Pool 和 API。当前仍是按完整 snapshot 重扫，没有实现 `devices.watch` 或连续
IOKit hot-plug event stream。

### 8.4 QMI holder 与端口强制释放

`internal/qmi/control_device_holders_linux.go` 同时承载 Linux holder 检测和若干共享类型，Darwin
不仅缺少 `/proc` 实现，连共享符号也会在编译时缺失。应把平台无关类型移出 `_linux.go`，再为
Darwin 明确实现安全行为。

`internal/modem/manager.go` 的端口释放逻辑依赖 `fuser`、`/proc` 和向占用 PID 发送信号。macOS
成品不应照搬“扫描后杀掉外部进程”的策略；PTY 所有权必须由 Host App/daemon lease 协调，冲突
时 fail closed 并提示用户，不能为抢占串口终止不相关进程。

本地状态：QMI holder 的共享类型和平台实现已经拆分，Darwin 编译通过；`forceReleasePort` 的
`fuser`/`/proc`/kill 行为尚未平台化，是启动真实 Darwin Worker 前的明确阻塞项。

### 8.5 数据面、音频与系统集成

上游 QMI transport 直接打开 Linux control device；Darwin 即使完成编译，也需要为
`quectel-qmi-go` 增加可注入 transport，才能把 `USBDriverKit`/用户态 QMI bridge 接入。MBIM
依赖已有公开 transport 接口，若 EC20 固件能切到标准 MBIM/ECM，会比私有 QMI 数据面更早形成
可用闭环。

语音路径目前调用 ALSA 的 `arecord`/`aplay`，macOS 需要 CoreAudio 实现。systemd/OpenWrt 服务
管理、自更新与卸载也必须替换成签名 Host App、launchd helper 和 macOS updater。非 Linux 的
VoWiFi stub 不能算完整支持；要达到 Vohive 全功能，仍需真实的 Darwin 用户态 IPsec/ESP 网络栈，
不能用返回成功的空实现掩盖能力缺口。

当前本地补丁已能生成 Darwin arm64/amd64 完整后端 Mach-O，并接通 metadata 设备池；但在上述
运行时平台边界完成前，它仍只是可审计的 bring-up 后端，不能宣称已经是可分发或 Vohive 全功能
兼容的 macOS 应用。
