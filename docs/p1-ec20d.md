# P1 当前切片：`ec20d`、Unix Socket 与 PTY

更新日期：2026-08-01

## 1. 这次实现了什么

这是 P1 的第一个可运行切片，不是路线图中 P1 的全部验收结果，更不是可分发的 macOS 驱动。
它把 P0 已验证的 USB AT transport 放进一个长期运行的普通用户态进程，并提供版本化的本地
Unix socket 接口和配套命令行客户端：

- `ec20d`：通过连接级 RPC 租约或 PTY handler 受控打开 EC20 interface 2；
- `ec20ctl`：用于协议握手、列出设备和执行一条受策略限制的 AT 命令；
- `--mock`：提供固定的虚拟 EC20，完整测试 IPC 和客户端但不枚举、打开或写入 USB；
- `--pty`：创建权限为 `0600` 的动态 `/dev/ttys*`，让现有串口客户端通过实验桥访问 AT；
- Vohive serial smoke：固定使用 `go.bug.st/serial` v1.6.4 验证 115200/8N1、75 ms read timeout
  和基本 `AT`/`OK` 字节流；
- NDJSON 协议 codec：校验 schema/API major、字段类型、单条消息大小和稳定错误码；
- 默认只读 AT allowlist：危险命令在进入 USB transport 前拒绝。

普通模式仍只匹配 `2c7c:0125`、configuration 1、interface 2。daemon 可按 `instance_id` 选择
设备；`ec20ctl at` 在省略 `--instance` 时才要求当前恰好有一台匹配设备。它不打开保留给网络的
interface 4，也不使用 capture/seize 抢占已有 owner。

本切片没有实现以下 P1 目标：

- URC 与当前命令响应分流或 `SubscribeURC`；
- `devices.watch`、IOKit 热插拔通知、拔出后重连或 generation 事件；
- PTY 的强制单客户端所有权；当前是 `cooperative_single_client`，同 UID 多开仍可能混帧；
- 多客户端并发 accept、后台命令队列、租约超时和跨连接租约恢复；
- 除已支持的 `AT+CMGS` prompt/十六进制 PDU/Ctrl-Z 外的其他多阶段或二进制输入；
- 面向生产的任意 AT 授权/审计、QMI、ECM 数据面或完整 Vohive Darwin backend；当前只验证了
  Vohive 使用的 Go 串口库和 PTY 的基本兼容性。

因此当前成品只能作为只读 AT/IPC 架构验证使用。Vohive 完整兼容仍按
[产品路线图](roadmap.md)继续推进。

## 2. 构建与测试

项目使用安装在 data 硬盘上的 Xcode。显式指定 SDK，避免 CMake 误用 Command Line Tools：

```sh
export DEVELOPER_DIR=/Volumes/data/Applications/Xcode-26.5.0.app/Contents/Developer
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

cmake --fresh -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_SYSROOT="$MACOS_SDK"
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

P1 最初建立的七项核心 CTest 如下；它们全部是 self-test 或 `--mock` 集成，不访问 USB：

| CTest | 覆盖内容 |
|---|---|
| `ec20-at-probe-self-test` | AT 终止行、响应边界和只读 policy |
| `ec20-ipc-protocol-self-test` | NDJSON envelope、版本、大小限制和错误响应 |
| `ec20d-self-test` | daemon policy、device object、PTY framing 与 capability |
| `ec20ctl-self-test` | client framing、响应/事件校验和 AT 流程 |
| `ec20d-mock-integration` | Unix socket 上的 hello/list/AT 及负向 policy |
| `ec20d-pty-mock-integration` | mock PTY、POSIX raw termios 和独立 `OK` |
| `ec20d-vohive-serial-integration` | `go.bug.st/serial` v1.6.4 通过 mock PTY 收发 AT |

P3 继续在此基础上加入 provider、Manager 安全门和完整 Web 流程，当前根套件为 13/13，详见
[Darwin Web 端到端文档](vohive-darwin-web.md)。Go 相关项只在 CMake 找到 Go toolchain 时注册；
缺少 Go 不会阻止 Objective-C 核心构建，但不能据此宣称 Vohive 兼容已通过。

运行不接触硬件的端到端 mock 测试：

```sh
./tests/ec20d_mock_integration.sh
./tests/ec20d_pty_integration.sh
./tests/ec20d_vohive_serial_integration.sh
```

三个脚本都只启动 `ec20d --mock`：第一项验证 RPC hello/list/AT，第二项验证 POSIX PTY smoke，
第三项通过固定版本的 Vohive 串口依赖验证相同 PTY。它们不依赖 `jq`，临时目录和 daemon 在
成功、失败或收到信号时都会清理。
如果构建产物不在默认 `build/`，可以覆盖：

```sh
EC20D_BIN=/absolute/path/ec20d \
EC20CTL_BIN=/absolute/path/ec20ctl \
./tests/ec20d_mock_integration.sh

EC20D_BIN=/absolute/path/ec20d \
EC20CTL_BIN=/absolute/path/ec20ctl \
EC20_PTY_SMOKE_BIN=/absolute/path/ec20-pty-smoke \
./tests/ec20d_pty_integration.sh

GO_BIN=/absolute/path/go ./tests/ec20d_vohive_serial_integration.sh
```

## 3. 运行方式

### 3.1 Mock 模式（推荐先运行）

终端一：

```sh
SOCKET_PATH="${TMPDIR:-/tmp}/ec20d-demo.sock"
./build/ec20d --mock --socket "$SOCKET_PATH"
```

终端二：

```sh
SOCKET_PATH="${TMPDIR:-/tmp}/ec20d-demo.sock"
./build/ec20ctl --socket "$SOCKET_PATH" hello
./build/ec20ctl --socket "$SOCKET_PATH" list
./build/ec20ctl --socket "$SOCKET_PATH" at AT
```

mock 设备使用固定的 `instance_id` `usb-03120000-1`。普通命令返回 echo 和独立的 `OK`；常用只读
查询还返回确定性数据，例如 `AT+CGSN` 为 `867530900000001`、`AT+CSQ` 为 `+CSQ: 20,99`、
`AT+CPIN?` 为 `READY`。这些 fixture 用于验证 Vohive 的解析和 UI 流程，不能作为 USB 实机证据。

PTY mock 模式会在 `devices.list` 的 `at.path` 发布动态路径，并把 AT RPC capability 切换为
`at.pty`。仅当同时启用 `--mock --pty` 时还会发布测试 capability `mock.urc.inject`：

```sh
SOCKET_PATH="${TMPDIR:-/tmp}/ec20d-pty-demo.sock"
./build/ec20d --mock --pty --socket "$SOCKET_PATH"
./build/ec20ctl --socket "$SOCKET_PATH" list
./build/ec20ctl --socket "$SOCKET_PATH" mock-urc '+CPIN: READY'
```

从输出取得 `/dev/ttys*` 后，可以运行 Objective-C smoke，或运行与 Vohive 相同串口库的 Go
smoke：

```sh
./build/ec20-pty-smoke /dev/ttysNNN AT

cd tools/vohive-serial-smoke
GOWORK=off go run -mod=readonly . /dev/ttysNNN AT
```

### 3.2 实机 RPC 只读模式

确认没有运行 P0 探针、串口工具或另一份 daemon 后启动：

```sh
SOCKET_PATH="${TMPDIR:-/tmp}/ec20d-live.sock"
./build/ec20d --socket "$SOCKET_PATH"
```

另一个终端执行：

```sh
./build/ec20ctl --socket "$SOCKET_PATH" hello
./build/ec20ctl --socket "$SOCKET_PATH" list
./build/ec20ctl --socket "$SOCKET_PATH" at AT
./build/ec20ctl --socket "$SOCKET_PATH" at 'AT+QCFG="usbnet"'
```

停止 daemon 使用 `Ctrl-C`/SIGTERM。进程应关闭连接、释放 interface 2 并删除自己创建的 socket；
随后可用 `ec20-at-probe --list` 确认 USB interface 能再次打开。不要并行运行 probe 和 daemon，
二者都需要独占 interface 2。

本切片已完成一次真实只读端到端验证：daemon 返回 `usb-03120000-1`，`ec20ctl` 在同一连接依次
完成 hello、list、acquire、`AT`、release，模块返回独立 `OK`，随后 daemon 达到请求上限自动
退出并释放接口。该验证没有发送配置、复位、拨号或短信命令。

### 3.3 实机 registry-pinned PTY 模式

实机 PTY 必须明确选中启动时看到的 modem。当前设备 location ID 为 `0x03120000`：

```sh
SOCKET_PATH="$(mktemp -d "${TMPDIR:-/tmp}/ec20d-live-pty.XXXXXX")/ec20d.sock"
./build/ec20d \
  --pty \
  --pty-location-id 0x03120000 \
  --socket "$SOCKET_PATH"
```

daemon 在启动时同时记录匹配 USB service 的动态 registry ID；后续每条 PTY 命令都按这个
registry ID 重新打开 interface 2，而不是只按 location ID 重选。若原模块被拔出、同一端口插入
另一模块，新 service 的 registry ID 不同，命令会失败，不会误发给替换设备。registry ID 只在
本次 attach 内有效，不能存入 Vohive 作为长期设备身份。

用 `ec20ctl list` 取得当前 `/dev/ttys*` 后，实测以下命令退出 0：

```sh
cd tools/vohive-serial-smoke
GOWORK=off go run -mod=readonly . /dev/ttysNNN AT
```

模块返回独立 `OK`，工具只打印 `vohive serial smoke: PASS`，不会打印响应正文。SIGTERM 后
socket 和 PTY 都消失，随后 `./build/ec20-at-probe --list` 退出 0，证明 interface 2 已释放。
完整证据见 [P1 实验记录](experiment-p1-2026-08-01.md)。

## 4. Unix socket 的权限边界

未指定 `--socket` 时，服务使用当前用户临时目录中的 `ec20d.sock`；测试和多实例运行建议始终
显式传入绝对路径。`ec20ctl` 使用相同默认值，也可通过 `EC20D_SOCKET` 或 `--socket` 覆盖。
当前安全边界是：

- socket 创建后权限收紧为 `0600`；
- 服务校验连接方的 effective UID，只接受与 daemon 相同的本地用户；
- daemon 不应以 root 运行；Vohive 和 `ec20ctl` 也不需要 root；
- 协议单条记录最大 1 MiB；超过限制或无法形成完整 NDJSON 记录会关闭/拒绝该请求；
- socket 只承载本地请求，不监听 TCP，也不提供远程访问。

PTY slave 同样限制为当前用户所有、权限 `0600`，但这是文件访问控制，不是独占锁。多个同 UID
进程仍可能同时打开同一路径并把字节写入同一个 stream。`devices.list` 因此明确报告
`ownership="cooperative_single_client"`：当前必须由 Vohive/测试编排保证只有一个 client，不能
把 `0600` 或一次成功的 `serial.Open` 理解成强制独占。

`0600` 不能替代安全的父目录。自定义路径应放在仅当前用户可写的目录，不要把 socket 放进其他
用户可替换文件的共享目录。生产应用还需基于 audit token/code signing identity 校验客户端；
当前同 UID 校验只是开发阶段边界。

## 5. IPC 协议

transport 是 `AF_UNIX` stream socket；每个请求和响应都是一行 UTF-8 JSON，以 LF 结束。当前
schema 是 `ec20.vohive/1`，API 是 `1.0`。API minor 可以向前扩展，但不兼容的 schema/API
major 会返回 `unsupported_api`。

请求 envelope：

```json
{"schema":"ec20.vohive/1","api_version":"1.0","id":"1","method":"system.hello","params":{}}
```

成功响应：

```json
{"schema":"ec20.vohive/1","api_version":"1.0","id":"1","ok":true,"result":{}}
```

失败响应：

```json
{"schema":"ec20.vohive/1","api_version":"1.0","id":"1","ok":false,"error":{"code":"permission_denied","message":"command is not allowed","retryable":false}}
```

当前稳定错误码包括 `invalid_request`、`unsupported_api`、`not_found`、`not_ready`、`busy`、
`permission_denied`、`timeout`、`device_removed`、`transport_error` 和 `resync_required`。客户端
必须根据 `ok` 和 `error.code` 判断结果，不应匹配人类可读的 `message`。

当前公开方法：

| 方法 | 参数 | 作用 |
|---|---|---|
| `system.hello` | client 名称和版本 | 返回 daemon 版本、实例 ID 和当前 capability |
| `devices.list` | `{}` | 返回 revision 和当前设备快照；当前不提供持续 watch |
| `at.acquire` | `instance_id`、`generation` | 在当前 IPC 连接取得 interface 2 独占租约 |
| `at.execute` | 设备、generation、lease、命令和上限 | 在租约内执行一条 policy 允许的 AT 命令 |
| `at.release` | 设备、generation、lease | 关闭 USB transport 并释放租约 |
| `mock.urc.inject` | `line` | 仅 `--mock --pty` 可用，向 PTY 注入一条主动上报测试记录 |

租约绑定创建它的 IPC 连接；连接断开时自动释放。当前服务一次只处理一个连接，因此已经保证
USB 命令不交错，但其他客户端要等待当前连接结束。后续仍需并发 accept、显式排队、租约超时和
URC event；Vohive 不应把目前的串行 server 行为固化为长期 ABI。

启用 `--pty` 后，`system.hello` 发布 `at.pty`，`devices.list` 返回 `at.transport="pty"`、动态
`at.path` 和 `cooperative_single_client`；同一 daemon 的 RPC `at.acquire` 会返回 busy，避免
RPC 和 PTY 两条上层通道同时控制 modem。PTY worker 只负责 CR/LF 命令 framing 和串行调用
handler，无法识别两个同时打开 slave 的本地进程，所以上述 busy 规则不能解决 PTY 多开混帧。

`mock.urc.inject` 严格拒绝真实模式和无 PTY 模式，只接受 1–1024 字节可打印 ASCII，并由 bridge
统一添加 CR/LF。它不会被真实 daemon 的 capability 宣告；即使客户端直接请求，真实模式也返回
`permission_denied`，不会写入 USB。详细测试边界见 [Darwin URC 文档](vohive-darwin-urc.md)。

## 6. 默认只读 AT 策略

默认只允许以下精确命令：

```text
AT
ATI
AT+GMR
AT+CGSN
AT+CSQ
AT+CPIN?
AT+COPS?
AT+QCFG?
AT+QCFG=?
AT+QCFG="<只含字母、数字、点、下划线或连字符的键>"
```

命令必须是可打印 ASCII，不能包含 CR/LF；transport 只在通过 policy 后追加一个 `\r`。例如：

- `AT+QCFG="usbnet",1`：拒绝；
- `AT+CFUN=1,1`：拒绝；
- 拨号、发送短信、SIM/eSIM 写操作和复位：拒绝；
- 把两条命令用换行拼接：拒绝。

拒绝发生在 USB 写入前。`--allow-arbitrary-at` 是明确的开发开关，仍要求命令以 `AT` 开头，
但会放开持久配置和其他状态变更；它不能成为应用默认值。生产接口应为 USB 模式切换、短信发送
等状态变更提供明确、可审计且带确认的高层方法。

PTY handler 使用同一 daemon policy。额外的 Objective-C/Go smoke 工具范围更窄，只接受 P0
四条精确命令 `AT`、`ATI`、`AT+GMR`、`AT+QCFG="usbnet"`，没有放开开关。当前 mock 与实机
PTY 验证都只发送了 `AT`。

## 7. PTY 实现与验证

PTY bridge 已在本仓库实现。它使用 `openpty` 创建 raw slave，校验 slave 是当前用户拥有的字符
设备并收紧为 `0600`；私有 worker 从 master 读取可打印 ASCII，以 CR/LF 组成命令，并把 handler
返回的原始字节写回。单命令输入上限为 4096 bytes，停止时通过专用 pipe 唤醒 worker、等待线程
退出，再关闭 master、slave anchor 和 pipe。

验证分三层：

1. `EC20PTYBridge` self-test 覆盖碎片输入、批量命令、非法/超长输入恢复和 stop；
2. `ec20-pty-smoke` 通过 POSIX `open`、raw termios、poll 和 3 秒/64 KiB 边界验证独立 `OK`；
3. `tools/vohive-serial-smoke` 固定 `go.bug.st/serial` v1.6.4，使用 115200/8N1 和 75 ms
   read timeout，通过 mock PTY 与 registry-pinned 实机 PTY 完成 `AT`。

实机结果为 `vohive serial smoke: PASS`、退出 0；模块返回独立 `OK`，Go 工具不输出响应正文。
SIGTERM 后 socket/PTY 清理完成，P0 probe 能重新打开 interface 2。这个结果证明当前桥能承载
Vohive 的基本串口字节流，但不等于完整 Vohive backend 已经接通。

已知 PTY 限制：

- `GetPortsList` 不会可靠枚举 PTY，Vohive 必须读取 `devices.list.at.path`；
- `/dev/ttys*` 每次启动动态变化，不能作为持久设备 ID；
- ownership 只是 `cooperative_single_client`；即使都是同 UID，两个 `Open`/writer 仍可能把字节
  混入同一 stream，daemon 无法按 client 还原边界；
- `SetDTR` 在可行性实验中返回 `ENOTTY`，PTY 不具备真实串口完整的 modem-control 语义；
- PTY 上设置 baud rate 只满足串口 API，不改变 EC20 USB bulk transport 的实际速率。

所以 PTY 仍是 P1 到 Vohive 的临时实验桥；产品版必须由 `USBSerialDriverKit` 提供真正的
`/dev/cu.ec20-*-at`，或者让 Vohive Darwin backend 使用带明确所有权的 IPC transport。

## 8. 当前限制与下一步

当前 RPC 和 PTY 都采用请求—完整响应模型。PTY 为每条命令按启动时固定的 registry ID 打开
interface 2，事务结束立即关闭 USB transport；这样能够阻止同一端口替换模块时的误操作，但
没有常驻 reader，因此不能实时收取或订阅 URC。事务开始时发现的 stale input 只会并入本次 PTY
响应，不是可靠的事件通道。

停止 PTY 时会唤醒并 join worker；如果 worker 已进入同步 USB handler，stop 必须等待当前
transport 返回。命令读取有固定 deadline、响应上限也限制内存，但 interface open 和整个同步
handler 没有独立的取消/stop deadline，因此目前不能承诺 SIGTERM 等待严格有界。`AT+CMGS`
已有 prompt/PDU/Ctrl-Z 状态机和 ESC 恢复工具，但仍只能在显式开发开关下使用。没有 `devices.watch`/热插拔恢复
时，固定 registry ID 只会让旧设备操作失败，不会自动发现新 generation 或重建 PTY。

下一切片应按以下顺序推进：

1. 为 PTY/RPC 建立同一套强制 owner、并发 accept、显式命令队列、租约超时和公平调度；
2. 把 registry-pinned USB ownership 演进为可取消的常驻 transport，实现响应/URC 分流、订阅和
   断线 resync；
3. 增加 IOKit watch、真实 generation、拔出取消和受控重连，继续保证替换设备 fail closed；
4. 把已验证的短信 prompt/Ctrl-Z 事务从 PTY 过渡层下沉为带权限的正式 API；
5. 把 `devices.list`/事件与串口路径接入 Vohive Darwin DeviceProvider，再开始 P2 ECM 门禁。

本切片没有执行 `AT+QCFG="usbnet",1`，没有改变 `usbnet=0`，没有复位模块，也没有进行 ECM
重新枚举或产生 `enX`；所有实机命令只访问 configuration 1/interface 2，从未打开或写入
interface 4。ECM 实验属于 P2；只有准备独立恢复通道并完成相应恢复文档后才能执行。
