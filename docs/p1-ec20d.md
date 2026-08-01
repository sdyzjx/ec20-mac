# P1 当前切片：`ec20d` 用户态服务与 mock IPC

更新日期：2026-08-01

## 1. 这次实现了什么

这是 P1 的第一个可运行切片，不是路线图中 P1 的全部验收结果，更不是可分发的 macOS 驱动。
它把 P0 已验证的 USB AT transport 放进一个长期运行的普通用户态进程，并提供版本化的本地
Unix socket 接口和配套命令行客户端：

- `ec20d`：在连接级 AT 租约期间拥有 EC20 interface 2，串行处理本地 IPC 请求；
- `ec20ctl`：用于协议握手、列出设备和执行一条受策略限制的 AT 命令；
- `--mock`：提供固定的虚拟 EC20，完整测试 IPC 和客户端但不枚举、打开或写入 USB；
- NDJSON 协议 codec：校验 schema/API major、字段类型、单条消息大小和稳定错误码；
- 默认只读 AT allowlist：危险命令在进入 USB transport 前拒绝。

普通模式仍只匹配 `2c7c:0125`、configuration 1、interface 2。daemon 可按 `instance_id` 选择
设备；`ec20ctl at` 在省略 `--instance` 时才要求当前恰好有一台匹配设备。它不打开保留给网络的
interface 4，也不使用 capture/seize 抢占已有 owner。

本切片没有实现以下 P1 目标：

- URC 与当前命令响应分流或 `SubscribeURC`；
- `devices.watch`、IOKit 热插拔通知、拔出后重连或 generation 事件；
- PTY bridge；
- 多客户端并发 accept、后台命令队列、租约超时和跨连接租约恢复；
- 短信 `>` prompt、多阶段 payload、Ctrl-Z 结束符或二进制输入；
- 面向生产的任意 AT 授权/审计、QMI、ECM 数据面或 Vohive Darwin backend；当前只有显式开发开关。

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

CTest 当前包含协议、daemon/client 自测和 mock 端到端测试，共五项；所有自测都不访问 USB。

运行不接触硬件的端到端 mock 测试：

```sh
./tests/ec20d_mock_integration.sh
```

脚本只启动 `ec20d --mock`，等待专用临时 socket，然后分别验证 `hello`、`list` 和 `at AT`
均以退出码 0 完成。它不依赖 `jq`，临时目录和 daemon 在成功、失败或收到信号时都会清理。
如果构建产物不在默认 `build/`，可以覆盖：

```sh
EC20D_BIN=/absolute/path/ec20d \
EC20CTL_BIN=/absolute/path/ec20ctl \
./tests/ec20d_mock_integration.sh
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

mock 设备使用固定的 `instance_id` `usb-03120000-1`，`AT` 返回命令 echo 和独立的 `OK`
终止行。mock 结果只证明 IPC、policy 和客户端路径成立，不能作为 USB 实机测试证据。

### 3.2 实机只读模式

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

## 4. Unix socket 的权限边界

未指定 `--socket` 时，服务使用当前用户临时目录中的 `ec20d.sock`；测试和多实例运行建议始终
显式传入绝对路径。`ec20ctl` 使用相同默认值，也可通过 `EC20D_SOCKET` 或 `--socket` 覆盖。
当前安全边界是：

- socket 创建后权限收紧为 `0600`；
- 服务校验连接方的 effective UID，只接受与 daemon 相同的本地用户；
- daemon 不应以 root 运行；Vohive 和 `ec20ctl` 也不需要 root；
- 协议单条记录最大 1 MiB；超过限制或无法形成完整 NDJSON 记录会关闭/拒绝该请求；
- socket 只承载本地请求，不监听 TCP，也不提供远程访问。

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

租约绑定创建它的 IPC 连接；连接断开时自动释放。当前服务一次只处理一个连接，因此已经保证
USB 命令不交错，但其他客户端要等待当前连接结束。后续仍需并发 accept、显式排队、租约超时和
URC event；Vohive 不应把目前的串行 server 行为固化为长期 ABI。

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

## 7. PTY 可行性实测

PTY bridge 尚未在本仓库实现，但已做过独立的最小兼容性实验：

- 环境：macOS 26.2 arm64、Go 1.26、`go.bug.st/serial` v1.6.4；
- `serial.Open("/dev/ttys001", 115200)` 成功；
- 双向传递 `AT`/`OK` 的字节保持一致；
- `SetReadTimeout(75ms)` 成功；
- 运行时切换 9600 和 230400 baud 成功。

这说明 Vohive 使用的 Go 串口库能够把 PTY slave 当作基本字节流，但同时观察到：

- `GetPortsList` 不会枚举该 PTY，必须由 `ec20d` 把动态路径显式交给 Vohive；
- 第二次 `Open` 仍可成功，不能依赖 PTY 自动提供真实串口的独占语义；
- `SetDTR` 返回 `ENOTTY`，modem control line 语义不完整；
- `/dev/ttys*` 路径是动态的，daemon 重启或重新创建 PTY 后会变化；
- 本次只验证基本字节流，没有验证 AT echo/URC 分流、拔出、并发 client 和短信 prompt。

所以 PTY 只能作为 P1 到 Vohive 的临时实验桥；产品版仍必须由 `USBSerialDriverKit` 提供真正的
`/dev/cu.ec20-*-at`。

## 8. 当前限制与下一步

当前 daemon 对命令采用请求—完整响应模型。没有 URC dispatcher 时，不应运行会持续产生异步
输出的业务；没有短信 prompt 状态机时，即使放宽 allowlist 也不能用 `AT+CMGS` 安全发送正文。
没有 `devices.watch`/热插拔恢复时，模块拔出后应停止 daemon、重新插入再启动，不能假设旧
instance、file descriptor 或 socket session 仍有效。

下一切片应按以下顺序推进：

1. 并发 accept、显式命令队列、租约超时和公平调度；
2. 响应和 URC 分流、订阅及断线 resync；
3. IOKit watch、真实 generation 和拔出/重连；
4. PTY bridge 与 Vohive 派生 Go 测试；
5. 短信 prompt 和其他有状态 AT transaction 的专用 API。

本切片没有执行 `AT+QCFG="usbnet",1`，没有改变 `usbnet=0`，没有复位模块，也没有进行 ECM
重新枚举或产生 `enX`。ECM 实验属于 P2；只有准备独立恢复通道并完成相应恢复文档后才能执行。
