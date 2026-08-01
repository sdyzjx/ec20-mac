# Vohive Darwin 后端构建与依赖说明

状态：可以在 macOS 生成并运行 Vohive 后端 Mach-O bring-up 二进制；它不是 `.app`、没有
Developer ID/公证，也未包含 DriverKit system extension。

相关提交：

- `9b059bc`：固定导入 `swu-go` v0.0.3；
- `ae5894b`：Darwin/Linux 网络与依赖可移植层；
- `fbd8d42`：Darwin ec20d HardwareProvider 接入；
- `b4da41f`：可重复执行的 Darwin backend build 脚本。

## 1. 固定依赖来源

Vohive 来源与 PolyForm Noncommercial 限制见 [Vohive 上游说明](vohive-upstream.md)。本轮还通过
Git subtree 固定导入：

| 项目 | 固定值 |
|---|---|
| 仓库 | `https://github.com/1239t/swu-go.git` |
| tag | `v0.0.3` |
| 上游提交 | `c4fb4016432c3851d2f4e6ba44261368b01a2be3` |
| subtree 目录 | `third_party/swu-go` |
| 父仓库提交 | `9b059bc` |
| squash 内容提交 | `9ae1279` |
| 许可证 | MIT（源码目录内保留 `LICENSE`） |

Vohive 的 `go.mod` 使用本地、固定副本：

```go
replace github.com/1239t/swu-go => ../swu-go
```

这避免构建时混入另一个未审阅版本，但不消除 Go module、npm 和 toolchain 下载的供应链风险。
发布 CI 仍须固定缓存、校验 lockfile/go.sum，并生成完整 Third-Party Notices。

## 2. 已处理的编译边界

固定上游原本包含多处 Linux-only 假设。本仓库的本地补丁目前做到：

- `internal/netbind` 在 Linux 使用 `SO_BINDTODEVICE`，Darwin 按地址族使用
  `IP_BOUND_IF`/`IPV6_BOUND_IF` 和 interface index；失败时 fail closed；
- proxy、netprobe 和 QMI manager 共用 `netbind`，不再直接引用 Darwin 不存在的常量；
- `swu-go` 的 Linux `MSG_ERRQUEUE` listener 使用 build tag 隔离；非 Linux 明确没有这项可选
  PMTU/ICMP error-queue 能力，不伪装成功；
- timeval 使用可移植的 `syscall.NsecToTimeval`；
- udev/netlink loop 与 QMI holder 检测按平台分文件，共享类型不再困在 `_linux.go`；
- Darwin 设备发现使用认证的 `ec20d` provider，不扫描 `/sys` 或伪造 Linux device node。

这些修改解决的是编译和已覆盖路径的安全语义。它们不等于 QMI、VoWiFi、音频或 service manager
已经在 macOS 实现。

## 3. 前端生成物

Vohive 后端使用 `go:embed all:dist`。subtree 不提交 `web/dist` 或 `internal/web/dist`，所以默认
构建会执行上游 `make frontend-dist`：

1. 基于 `web/package-lock.json` 运行 `npm ci`；
2. 运行 Vite build；
3. 把结果复制到 `internal/web/dist`；
4. Go build 将其嵌入后端。

当前本机实际使用 Node.js 24.10.0、npm 11.6.0 构建成功；上游 release workflow 使用 Node 22，
正式 CI 应优先固定并验证上游 major，而不是依赖开发机的全局版本。

本次 `npm ci` 报告 16 个已知漏洞（4 moderate、12 high）。没有自动执行 `npm audit fix`，因为它
可能越过 lockfile 中经过审阅的版本或引入行为变化。它们是发布前必须逐项归因、升级或接受风险的
阻塞项；当前 bring-up 构建成功不能视为前端供应链审计通过。

生成目录已被忽略，不应提交到父仓库。

## 4. 构建命令

默认重建前端并构建当前主机架构：

```sh
./tools/build-vohive-darwin.sh
```

指定架构和输出：

```sh
./tools/build-vohive-darwin.sh \
  --arch arm64 \
  --output /tmp/vohive-arm64

./tools/build-vohive-darwin.sh \
  --arch amd64 \
  --output /tmp/vohive-amd64
```

只有已经存在 `third_party/vohive/internal/web/dist/index.html` 时，才可跳过前端：

```sh
./tools/build-vohive-darwin.sh --skip-frontend --arch arm64
```

可通过 `GO_BIN` 指定 Go launcher，通过 `DARWIN_ARCH`/`OUTPUT_PATH` 设置等价环境变量。脚本固定：

- `GOWORK=off`；
- `CGO_ENABLED=0`；
- `GOOS=darwin`；
- `-trimpath -buildvcs=false`；
- Vohive 当前需要的 `with_utls nomsgpack` tags；
- version 与 UTC build time ldflags。

这里的“repeatable”表示入口和参数受控，不表示 bit-for-bit reproducible：build time、Go toolchain、
npm 依赖源及前端产物都必须在正式 CI 进一步固定。

## 5. 当前验证结果

本机已实际生成：

```text
Mach-O 64-bit executable arm64
Mach-O 64-bit executable x86_64
```

两个架构均完成完整 `cmd/vohive` backend build；arm64 产物的 `-h` smoke 通过。Linux amd64
完整后端也重新构建成功，防止 Darwin factory 破坏原平台。

Apple linker 给当前 Go Mach-O 添加的是 ad-hoc signature：

```text
Signature=adhoc
TeamIdentifier=not set
```

因此准确表述是“没有 Developer ID 签名”，不是“完全没有任何 code signature”。ad-hoc 只满足
本机装载所需的最低形式，不可替代 Developer ID、Hardened Runtime、notarization、App Sandbox
或 DriverKit entitlement。

测试入口：

```sh
cmake --build build --target test

cd third_party/vohive
GOWORK=off go test -race -count=1 \
  ./internal/platform/ec20d \
  ./cmd/vohive-darwin-probe

GOWORK=off go test -race -count=1 \
  -run '^(Test.*HardwareProvider.*|TestAuthoritativeEmptyProviderSnapshotEvictsOfflineWorker|TestWithNilHardwareProviderKeepsLegacyMode|TestResolveCompatibleModemATPort.*|TestProbeIMEICached.*)$' \
  ./internal/modem \
  ./internal/device \
  ./internal/api

GOWORK=off go test ./...
```

仓库当前 CTest 为 13/13；新增项会构建完整 Darwin Vohive、启动 mock `ec20d`，并验证嵌入式 Web
与 API 的登录、发现、添加、overview 身份收敛、AT 和删除流程。功能相关定向 race/vet 通过，其中
真实 `modem.Manager` 对合成 PTY 的启动/停止生命周期也在 race detector 下执行。三个 SIM/MBIM
测试和一个 eSIM 测试原先使用了与断言不一致的合成 IMSI/IMEI；`52513aa` 只修正测试夹具，不改
生产解析逻辑。修正后 `GOWORK=off go test ./...` 在 Darwin 全量通过。

## 6. 这个产物现在能做什么

后端已经能够：

- 在 Darwin 主程序中构造认证的 `ec20d` HardwareProvider；
- 通过 Pool/API 读取 EC20 PTY metadata；
- 正确区分 provider 失败与成功空快照；
- 使用 fail-closed Darwin socket/interface binding 代码；
- 在显式要求 IMEI 时进行受串行仲裁、attachment-scoped 的只读探测。
- 在 Darwin 上以字符设备预检、进程内 lease 和 serial-open 错误取代 `fuser`/kill takeover。
- 启动嵌入式 Web，并在 AT-only Darwin 设备上完成登录、发现、添加、状态和 AT 终端流程；
- 在设备添加 UI 中显示 `AT / PTY` 和“仅 AT 控制面”，不把缺失数据面伪装成可用网络。

它目前不能作为完整 macOS 应用交付，缺少：

- 安全的 Darwin Manager/PTY lease 与完整业务实机回归；
- ECM/QMI 蜂窝网络 session 和可验证的代理出口；
- 连续 URC、短信、USSD、通话、CoreAudio、VoWiFi；
- `.app` UI/生命周期、launchd helper、安装/卸载/升级；
- Developer ID、notarization、DriverKit entitlement 与 dext。

在这些门禁完成前，脚本产物只用于本机 bring-up 与测试，不应分发或宣称 Vohive 完整兼容。
