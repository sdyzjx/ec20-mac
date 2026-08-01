# Vohive Darwin provider：首版只读发现

状态：实验性 bring-up，尚未接入 Vohive 的 `CompatibleModem`、`Pool` 或业务后端。实现提交：
`56b9761`（`feat(vohive): add authenticated Darwin ec20d discovery`）。
验证日期：2026-08-01。

## 1. 本切片完成了什么

本切片在仓库内的 Vohive 源码副本中加入了一个最小 Darwin 发现客户端，用来验证 Vohive 能否
安全消费 `ec20d` 的本地设备快照：

- 协议客户端：`third_party/vohive/internal/platform/ec20d`；
- 只读诊断命令：`third_party/vohive/cmd/vohive-darwin-probe`，在 Vohive 模块目录内对应
  `./cmd/vohive-darwin-probe`；
- mock 端到端测试：`tests/vohive_darwin_provider_integration.sh`；
- CTest 注册：`vohive-darwin-provider-unit` 和 `vohive-darwin-provider-integration`。

`vohive-darwin-probe` 只读取 Unix socket 元数据。它不会打开快照返回的 PTY，不会构造或发送
AT 命令，也不会接管 interface 2。当前成果证明的是“Vohive Go 代码能够识别一个经过严格校验的
Darwin PTY 快照”，不是完整的 modem backend。

## 2. 连接和协议流程

客户端的公开入口是：

```go
client, err := ec20d.NewClient(socketPath)
snapshot, err := client.DiscoverPTY(ctx)
```

`DiscoverPTY` 每次建立一个短生命周期的 `AF_UNIX` stream 连接，并在同一连接上严格按以下顺序
完成两个 NDJSON request/response round trip：

1. `system.hello`，request ID 为 `hello-1`；
2. `devices.list`，request ID 为 `list-2`；
3. 校验并缩减快照；
4. 立即关闭连接。

当前 `ec20d` 一次只处理一个已接受连接，因此这里不能缓存或长期占用连接，否则会阻塞
`ec20ctl` 和其他本地客户端。context deadline 会被设置到 socket；context 取消时也会主动令当前
I/O deadline 到期，并向调用方保留 `context.Canceled`/`context.DeadlineExceeded` 错误语义。

协议握手前，客户端还会把连接绑定到本地信任边界：socket 必须是当前 effective UID 拥有的
Unix socket、权限精确为 `0600`，连接后的 peer credential UID 也必须与当前 effective UID 一致。
Darwin 使用 `LOCAL_PEERCRED`，Linux 构建使用 `SO_PEERCRED`。这能阻止高权限进程误连普通用户
daemon，也能拒绝宽权限端点；但同 UID 进程本来就处于同一用户信任域，成品仍必须把 socket
放入私有 runtime 目录，优先采用 launchd socket activation，不能只依赖 `/tmp` 文件名。

### 2.1 Envelope 校验

当前实现对每次响应执行以下检查：

- schema 必须精确为 `ec20.vohive/1`；
- `api_version` 必须严格是两个无符号十进制分量 `major.minor`，major 与客户端 `1.0` 相同；
  同 major 的新增 minor/未知 JSON 字段可以被忽略；
- response `id` 必须与当前 request ID 完全一致；
- `ok=true` 时必须有非空、非 `null` 的 `result`，且不能同时携带 `error`；
- `ok=false` 时返回包含 `code`、`message` 和 `retryable` 的 `RemoteError`；
- 单条 request 或 response（包括结尾 LF）不得超过 1 MiB；
- socket 路径必须是无 CR、LF、NUL 的绝对规范化路径；已连接端点还须通过上面的 owner、mode
  与 peer credential 校验。

握手还必须满足：

- `server == "ec20d"`；
- `daemon_instance_id` 非空；
- capability 同时包含 `devices.list` 和 `at.pty`。

如果 daemon 只发布 `at.rpc`，本客户端会明确失败，不会把 RPC 设备伪装成串口设备。

### 2.2 PTY 设备安全校验

`devices.list` 中只有 `at.transport == "pty"` 的对象会进入首版 PTY 快照。每个候选还必须满足：

- `instance_id` 非空、`generation > 0`，且 instance ID 和 PTY path 在本快照内不重复；
- VID/PID 精确为 `2c7c:0125`；
- USB location ID 非空；
- USB configuration 为 1；
- AT interface 为 2、network interface 为 4；
- `lifecycle.state == "ready"` 且 `at.available == true`；
- `at.rpc_device_id == null`；
- 设备 capability 包含 `management.at`；
- path 必须匹配 Darwin PTY 的规范化 `/dev/ttys[0-9a-f]+` 形式；
- 对 path 执行 `lstat` 后必须是当前 effective UID 拥有的字符设备，不能是普通文件或 symlink；
- ownership 精确为 `cooperative_single_client`。

由于 macOS PTY 不能阻止同 UID 多次打开，`cooperative_single_client` 不是内核级独占承诺；
字符设备/owner 校验也不能替代应用级仲裁。Host App 仍须保证只有一个 Vohive 实例使用该 PTY。

## 3. 最小 PTY snapshot

完整 `devices.list` 对象只在校验过程中存在。诊断命令得到的是刻意缩减后的结构：

```text
PTYSnapshot
├── epoch
├── revision
└── devices[]
    ├── instance_id
    ├── generation
    ├── attachment_key
    ├── location_id
    ├── registry_id（可选）
    ├── path
    └── ownership
```

这个结构不输出 IMEI、ICCID、firmware、短信、APDU 或 AT 内容。它用于发现和运行期关联，不是
设备配置文件，也不是持久身份记录。

### 3.1 epoch、revision 和 attachment key

- `epoch` 来自 `system.hello.result.daemon_instance_id`，每个 daemon 进程实例不同；
- `revision` 来自 `devices.list.result.revision`；
- `attachment_key` 使用 daemon epoch、attach identity 和 generation 生成。

算法与当前代码一致：

```text
attach_identity = trim(registry_id)，若 registry_id 为空则使用 instance_id
payload         = epoch + NUL + attach_identity + NUL + decimal(generation)
attachment_key  = "ec20d:" + lowercase_hex(SHA-256(payload))
```

因此 daemon 重启、IORegistry attach 变化或 generation 变化都会产生新的 attachment key。当前
`ec20d` 的 revision 尚不足以单独充当完整热插拔信号；未来 watcher 至少应比较：

```text
epoch + revision + attachment_key + PTY path
```

### 3.2 禁止持久化运行时路径

以下值只允许存在于内存中的当前快照或 Worker attachment：

- `/dev/ttys*`；
- `registry_id`；
- `epoch` 和 `revision`；
- `attachment_key`；
- `instance_id` 和 `generation` 的当前 attach 组合。

尤其不能把动态 PTY path 写入 Vohive YAML、数据库设备身份字段或用户偏好。daemon 重启后 PTY
编号可以变化，同一路径也可能被将来的其他 attach 复用。持久设备身份仍应使用经过验证的 IMEI；
本切片没有读取 IMEI。

## 4. 使用方法

### 4.1 单元测试

```sh
cd third_party/vohive
GOWORK=off go test -count=1 \
  ./internal/platform/ec20d \
  ./cmd/vohive-darwin-probe

GOWORK=off go test -race \
  ./internal/platform/ec20d \
  ./cmd/vohive-darwin-probe

GOWORK=off go vet \
  ./internal/platform/ec20d \
  ./cmd/vohive-darwin-probe
```

### 4.2 CTest mock 验证

先正常配置并构建本项目，然后运行 provider 的两个测试：

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build \
  -R 'vohive-darwin-provider-(unit|integration)' \
  --output-on-failure
```

mock integration 会启动：

```sh
build/ec20d --mock --pty --max-requests 2 --socket <temporary>/ec20d.sock
```

随后从 `third_party/vohive` 执行 probe 的 JSON 模式。测试只允许 hello 和 list 两个 request，验证
固定 mock instance、动态 `/dev/ttys*`、`cooperative_single_client`、socket/peer/PTY 端点认证、
诊断输出不包含 IMEI 或 firmware，并确认 daemon 退出后 socket 和 PTY 都已清理。单元测试还覆盖
取消错误、严格 API 版本、response ID、畸形响应和恰好 1 MiB 无 LF 的边界。本轮另用
`GOOS=linux GOARCH=amd64 go test -c` 验证了 Linux peer-credential 实现可交叉编译。

本次结果：

```text
vohive-darwin-provider-unit        PASS
vohive-darwin-provider-integration PASS
Vohive Darwin ec20d provider integration: PASS
```

mock 不枚举或写入真实 USB，不能代替实机证据。

### 4.3 实机只读发现

实机运行时应显式使用短 socket 路径，并按实际 location 选择唯一 modem：

```sh
EC20_LOCATION_ID=0x03120000 # 必须先用 ec20-at-probe --list 核对本机实际值
SOCKET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ec20d-vohive-live.XXXXXX")"
SOCKET_PATH="$SOCKET_DIR/ec20d.sock"

./build/ec20d \
  --pty \
  --pty-location-id "$EC20_LOCATION_ID" \
  --max-requests 2 \
  --socket "$SOCKET_PATH"
```

另一个终端执行：

```sh
cd third_party/vohive
GOWORK=off go run ./cmd/vohive-darwin-probe \
  --socket "$SOCKET_PATH" \
  --json
```

也可以用 `EC20D_SOCKET` 设置默认 socket；未设置时 probe 使用
`filepath.Join(os.TempDir(), "ec20d.sock")`。命令还支持 `--timeout`，默认总 deadline 为 3 秒；
不加 `--json` 时只打印缩减后的一行设备摘要。

本次实机只读发现验证了 1 台 `2c7c:0125`：USB configuration 为 1、AT interface 为 2、network
interface 为 4、ownership 为 `cooperative_single_client`，并发布一个动态 `/dev/ttys*`。probe
返回了非空 epoch、非零 revision 和非空 attachment key。registry ID、location ID、PTY 编号、
epoch 和 attachment key 都是动态运行时值，本记录不固化这些具体值。

加固后的实机步骤再次通过了 socket owner/mode、peer UID 和真实 PTY 字符设备/owner 校验。
全程没有打开返回的 PTY，没有发送 `AT` 或任何其他 modem 命令，没有改变 `usbnet`，也没有
打开 interface 4。它只验证了真实 IOKit 枚举、ec20d metadata、Unix socket 协议和 Go provider
的安全映射。

## 5. 当前明确未完成的部分

目前代码仍是独立的只读 bring-up 工具，尚未：

- 把 `PTYSnapshot.Devices` 映射成 `internal/device.CompatibleModem`；
- 把 Darwin provider 注入 `device.Pool` 的 bootstrap、rescan 和 reconnect；
- 替换 `/api/devices/discovered` 对 Linux QMI/sysfs discovery 的直接调用；
- 将 attachment key 用作 IMEI probe cache 的 attach-scoped key；
- 启动 `modem.Manager` 或 `ATBackend`；
- 实现 `devices.watch`、IOKit hot-plug watcher 或可靠的拔插恢复；
- 实现实时 URC、入短信、USSD、来电、短信 prompt/Ctrl-Z transaction；
- 接入 ECM/QMI data plane、`enX`、Darwin socket/interface binding 或代理；
- 接入 Vohive 的 UI、配置添加流程和成品 Host App 生命周期。

当前 PTY bridge 每条命令临时打开 interface 2，并非连续 USB reader；即使下一步接入
`modem.Manager`，实时 URC 和 `AT+CMGS` 也不会因此自动可用。当前 daemon 只发布
`management.at`，上层不得据此宣称 SMS、USSD、SIM/eSIM 或网络能力已经完成。

## 6. 下一步接入点

建议按以下顺序继续，避免在业务层重新实现 Darwin 发现：

1. 在 `third_party/vohive/internal/device` 定义可注入的 `HardwareProvider`/`HardwareSnapshot`，
   Darwin 实现委托本切片的 `ec20d.Client`，Linux 实现继续包装现有 sysfs/QMI discovery。
2. 在 `internal/device/discovery_compat.go` 增加 PTY snapshot 到 `CompatibleModem` 的纯映射：
   `ATPort`/`ATPorts` 使用当前 PTY，driver 标为 `ec20d-pty`，network capability 保持 false。
3. 在 `internal/device/pool.go` 的 `collectRescanHardware`、`rescanAndReconnect` 和后台 change source
   注入 provider；保留当前 `NewPool` 调用方式，测试通过 option 注入 fake provider。
4. 在 `internal/device/pool_bootstrap.go` 让已保存 IMEI 的 AT device 能通过 provider 重新取得当前
   PTY，但绝不把路径写回配置文件。
5. 将 `internal/api/device_mgmt.go` 的 `/devices/discovered` 改为通过 Pool/provider 读取同一个硬件
   真相源，避免 API 和 Worker 看见不同设备集合。
6. 将 `internal/device/udev.go` 限定为 Linux；Darwin 在 `devices.watch` 可用前轮询完整 snapshot
   fingerprint，且严格区分“daemon 不可达”和“成功返回零设备”。
7. 修改 `internal/modem/imei_probe.go`：缓存键使用 attachment key，而不是动态 PTY path；只有
   完成单客户端所有权编排后，才允许发现流程短暂打开 PTY 读取 IMEI。
8. 首先做 `AT`、`AT+CGSN`、`AT+GMR`、`AT+CSQ` 的 Manager 级集成测试，再分别为 URC、短信
   prompt、热拔插和 daemon restart 建立独立门禁；不要用单条 AT smoke 推导完整业务可用。

上述接入完成前，`vohive-darwin-probe` 应继续保持只读、最小输出和独立可运行，作为协议回归与
安装诊断工具。
