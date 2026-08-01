# Vohive Darwin HardwareProvider 与设备池接入

状态：P3 bring-up 已接入 Vohive `CompatibleModem`、`Pool`、设备发现 API 和 Darwin 主程序工厂；
尚未完成 Worker/Manager 实机运行、连续 URC、短信/通话或蜂窝数据面。

实现提交：

- `56b9761`：认证的 `ec20d` Go 协议客户端与只读 probe；
- `fbd8d42`：Darwin `HardwareProvider`、Pool/API 接入、有限 deadline 和串口探测仲裁。

验证日期：2026-08-01。

## 1. 当前数据流

```text
EC20 USB interface 2
        │
      ec20d ── AF_UNIX / ec20.vohive/1 ── ec20d.Client
                                              │
                                   EC20DHardwareProvider
                                              │
                                      HardwareSnapshot
                                              │
                         ┌────────────────────┴────────────────────┐
                         │                                         │
                      device.Pool                       /api/devices/discovered
                         │
                 runtime Worker attachment
```

Darwin 的 `cmd/vohive` 通过 build-tag factory 默认注入 provider。socket 路径优先读取
`EC20D_SOCKET`，未设置时使用 `filepath.Join(os.TempDir(), "ec20d.sock")`。非 Darwin 构建仍调用
原有 `device.NewPool(cfg)`，Linux QMI/sysfs 行为不被替换。

`HardwareProvider` 是构造期依赖：

```go
type HardwareProvider interface {
    Snapshot(context.Context) (HardwareSnapshot, error)
}
```

`NewPool(cfg, options...)` 保留原调用兼容性；Darwin 使用
`WithHardwareProvider(provider)`。调用者拿到的是复制后的 modem/ATPorts 数据，不能修改 provider
持有的快照。

## 2. ec20d 协议和本地信任边界

`DiscoverPTY` 每次建立短生命周期 Unix stream 连接，并依次完成：

1. `system.hello`；
2. `devices.list`；
3. 校验并缩减快照；
4. 关闭连接。

客户端要求：

- schema 精确为 `ec20.vohive/1`，API 使用严格 `major.minor` 语法且 major 必须兼容；
- response ID 与 request ID 一致，成功/错误 envelope 不能混用；
- 单条 NDJSON request/response（含 LF）不超过 1 MiB；
- server 是 `ec20d`，capability 同时包含 `devices.list` 与 `at.pty`；
- socket 是当前 effective UID 拥有、权限精确为 `0600` 的 Unix socket；
- 已连接 peer 的 UID 也等于当前 effective UID；Darwin 使用 `LOCAL_PEERCRED`，Linux 测试实现使用
  `SO_PEERCRED`。

`EC20DHardwareProvider.Snapshot` 额外施加 3 秒上限，调用方更短 deadline 或主动 cancel 优先。
因此 daemon 即使 accept 后不回 hello/list，也不会永久卡住 bootstrap 或持有 Pool 的重扫锁。
错误保留 `context.Canceled`/`context.DeadlineExceeded` 的 `errors.Is` 语义。

当前默认路径位于临时目录只是 bring-up 约定；成品应使用 Host App 私有 runtime 目录和 launchd
生命周期。相同 UID 的其他进程仍属于同一用户信任域，peer credential 不是应用沙箱替代品。

## 3. PTY 校验与 CompatibleModem 映射

只有满足全部条件的 `devices.list` 项会进入快照：

- VID/PID 为 `2c7c:0125`；
- USB configuration 1、AT interface 2、network interface 4；
- lifecycle 为 ready，AT available，且 capability 包含 `management.at`；
- transport 是 PTY，RPC device ID 为空；
- path 匹配 `/dev/ttys[0-9a-f]+`；
- `lstat` 结果是当前 UID 拥有的字符设备，不接受普通文件或 symlink；
- ownership 为 `cooperative_single_client`；
- instance、generation、path 和 attachment 信息在当前快照内一致且不重复。

映射规则：

| ec20d / 固定硬件事实 | `CompatibleModem` |
|---|---|
| attachment key | `USBPath`（仅运行期，不是 sysfs 路径） |
| PTY path | `ATPort` 与唯一 `ATPorts` 项 |
| `2c7c:0125` | `VendorID` / `ProductID` |
| PTY adapter | `DriverName=ec20d-pty` |
| AT-only | `Mode=at`、`TransportType=at` |
| interface 4 尚未接入 | `NetworkCapable=false`，`ControlPath`/`NetInterface` 为空 |

纯映射不会打开 PTY、不会发送 AT，也不会伪造 `/dev/cdc-wdm*`、QMI control path 或 `enX`。

## 4. attachment、IMEI 与单客户端规则

attachment key 由 daemon epoch、当前 attach identity 和 generation 生成。daemon 重启、IORegistry
attach 变化或 generation 变化都会得到新 key。以下字段禁止写入 YAML/数据库身份：

- `/dev/ttys*`；
- epoch、revision、registry/instance ID；
- attachment key 与 generation。

Pool 只把 attachment key 和 PTY path 写入 Worker 的运行时 `DeviceConfig`；`USBPath` 使用
`mapstructure:"-"`，持久化路径明确不写它。持久设备身份仍是验证后的 IMEI。

当配置或 API 明确要求 IMEI 时，Vohive 现有 enrichment 会短暂打开 PTY 并发送只读 `AT` 与
`AT+CGSN`。为避免 macOS cooperative PTY 上多个 reader 分食响应，本次接入增加两层约束：

- 所有 IMEI cache miss 的实际串口探测在进程内全局串行，并在获得锁后复查缓存；
- 缓存键使用 `attachment key + PTY path`，不会因动态 PTY 编号被新 attach 复用而返回旧 IMEI。

旧 Linux/无 attachment 调用仍保留 port-only API 兼容行为。`7753554` 进一步让 Manager、IMEI
probe 和 `SerialAT` 共用进程内 port lease，并把 Darwin 的 `fuser`/`proc`/kill takeover 改为
字符设备预检 + serial open fail closed。跨进程独占仍须由 Host App/ec20d 生命周期保证。

## 5. Pool 与 HTTP 语义

Pool bootstrap、rescan 和 reconnect 共用 provider 快照。关键语义是：

- provider 错误会在任何 Worker 增删前返回，不能伪装成“零设备”；
- 成功的空 snapshot 是 authoritative empty，可以把对应离线 Worker 清理掉；
- 重扫由 mutex 串行，timeout 返回后锁会释放，下一次重试可继续；
- 非 QMI Worker 的 attachment key/PTY 变化会触发重建；
- 当前动态 attachment 只保存在运行内存，不回写设备配置。

`GET /api/devices/discovered` 在 Darwin 使用同一个 Pool provider：

- 成功：HTTP 200，包含 provider 设备或明确的空数组；
- provider 不可用/超时：HTTP 503，`error="hardware discovery unavailable"`；
- 默认不读 IMEI，保持 metadata-only；
- `?with_imei=1` 会进入上面的受仲裁 PTY enrichment，属于主动串口查询，不是纯 metadata 操作。

服务端不会把底层 socket 路径、peer 认证细节或 daemon 原始错误直接暴露给 HTTP 客户端。

## 6. 诊断与测试

只验证协议快照：

```sh
cd third_party/vohive
GOWORK=off go run ./cmd/vohive-darwin-probe \
  --socket /absolute/path/ec20d.sock \
  --json
```

额外经过 `EC20DHardwareProvider` 和 `Pool.DiscoverHardware`：

```sh
GOWORK=off go run ./cmd/vohive-darwin-probe \
  --socket /absolute/path/ec20d.sock \
  --pool \
  --json
```

`--pool` 输出仅包含 epoch/revision、attachment key、VID/PID、driver、PTY path、mode 和 network
capability。它不输出 IMEI、firmware 或 control path；但 attachment key 和 PTY path 仍是本地运行期
诊断信息，不应发布到不受信任的日志。

mock integration 启动 `ec20d --mock --pty`，先测直接 snapshot，再测 Pool 映射，完成后显式停止
daemon。
CTest 当前包括：

```text
vohive-darwin-provider-unit
vohive-darwin-device-provider-unit
vohive-darwin-provider-integration
ec20d-vohive-manager-integration
vohive-darwin-modem-safety-unit
vohive-darwin-web-integration
```

Provider harness 现在显式停止 daemon，不再使用 request 数量触发退出，避免最后一个 response 与
PTY `lstat` 认证竞态。完整根测试结果为 13/13。相关 provider/Pool/API、deadline、attachment
cache、Manager 生命周期和并发门禁通过 race 测试及 vet；Darwin arm64/amd64 与 Linux amd64
后端均完成构建回归。

### 6.1 实机 metadata-only 结果

实机使用当前 location `0x03120000` 启动：

```sh
SOCKET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ec20d-vohive-live.XXXXXX")"
SOCKET_PATH="$SOCKET_DIR/ec20d.sock"

./build/ec20d \
  --pty \
  --pty-location-id 0x03120000 \
  --max-requests 2 \
  --socket "$SOCKET_PATH"
```

另一个终端运行一次 `--pool --json`。验证结果：

- 找到一台 `2c7c:0125`；
- `DriverName=ec20d-pty`、`Mode=at`、`NetworkCapable=false`；
- attachment key 与动态 `/dev/ttys*` 正确进入 Pool；
- 没有打开 PTY，没有发送 AT，没有触碰 interface 4，也没有改变 `usbnet=0`。

本轮没有在实机执行 `?with_imei=1`、`AddWorkerFromConfig` 或完整 Vohive HTTP 服务；这些路径只在
mock PTY 上完成。mock/metadata 证据不能推导短信、通话、网络或热插拔已经可用。

## 7. 尚未完成

- Darwin Manager 的真实 EC20/Worker 生命周期与跨进程单实例 lease；
- 连续 USB reader、URC、来电、入短信、USSD、短信 prompt/Ctrl-Z transaction；
- daemon restart/拔插 watcher 与不中断恢复；
- ECM/MBIM controller、地址/DNS/路由观察与端到端代理出口；
- interface 4 的 QMI transport、Raw-IP/Ethernet 数据面和 `NetworkingDriverKit`；
- CoreAudio 语音路径及 VoWiFi/IPsec 的真实 Darwin 实现；
- 更细的 SMS/USSD/eSIM/网络 capability 门禁、Host App、launchd、签名、公证与 DriverKit entitlement。

下一步应为连续 reader、URC 与短信 transaction 建立 deterministic mock，再在明确授权的实机
门禁下做 Manager 测试。真实 Manager 初始化会发送易恢复但会改变会话状态的 AT 配置，具体安全
边界见 [Darwin Manager 文档](vohive-darwin-manager.md)。
