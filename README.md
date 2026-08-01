# EC20 macOS：Vohive 兼容驱动与应用

本仓库的长期目标是交付兼容 Vohive 功能模型的原生 macOS 应用。实现按可验证阶段推进：先用
普通用户态 `IOUSBHost` 服务验证 AT 与 ECM，再用 `USBSerialDriverKit` 提供正式串口，最终按
功能需要实现 QMI 与 `NetworkingDriverKit` 数据面。

当前状态已进入 **P3 Vohive Darwin bring-up**：P1 的用户态 USB/PTY 桥仍是硬件基础；仓库已
固定导入 Vohive 上游，并加入经过 socket peer 与 PTY 端点认证的 `ec20d` 发现客户端。
Vohive 使用的 `go.bug.st/serial` v1.6.4 已通过 mock 和 EC20 实机 `AT` 验证，Darwin provider
现已接入 `CompatibleModem`、`Pool`、`/api/devices/discovered`、Darwin 热插拔 watcher 和 ECM
网络控制器。EC20 已受控切换到 `usbnet=1`，macOS 的 `AppleUserECM` 在 interface 4 创建 `en11`；
Vohive 能把该接口与 interface 2 的 AT attachment 关联，并在模块重启后自动换用新的 PTY attachment。
完整 Vohive 后端可构建为 arm64/amd64 Mach-O，但它仍不是可安装的 `.app`/DriverKit 驱动。
完整嵌入式 Web 已跑通登录、发现、添加、状态收敛、AT 终端和删除流程；真实前端进一步完成 ECM
设备详情和“重启模组”恢复验收。真实 EC20 Manager 已完成 SIM、LTE 漫游注册、Vohive API 出站
PDU SMS 和运营商回复入站长短信验收。ECM 的绑定 IPv4 公网出口已通过，绑定 IPv6 尚未通过；
USSD 在当前漫游网络返回超时，来电、代理公网出口和产品化串口仍需继续验收。

设计与实施文档：

- [总体架构](docs/architecture.md)
- [Vohive 兼容契约](docs/vohive-compatibility.md)
- [P0–P6 产品路线图](docs/roadmap.md)
- [P1 ec20d 使用、协议与限制](docs/p1-ec20d.md)
- [Vohive Darwin 真实 EC20 接入实验](docs/experiment-vohive-real-2026-08-01.md)
- [首轮实机记录](docs/experiment-2026-08-01.md)
- [P1 daemon/PTY 实机记录](docs/experiment-p1-2026-08-01.md)
- [P2 ECM 与 Vohive 热插拔实机记录](docs/experiment-p2-ecm-2026-08-01.md)
- [Vohive 上游固定、同步与许可证](docs/vohive-upstream.md)
- [Vohive Darwin HardwareProvider 与 Pool 接入](docs/vohive-darwin-provider.md)
- [Vohive Darwin 后端构建与依赖](docs/vohive-darwin-build.md)
- [Vohive Darwin Manager 串口所有权与 mock 生命周期](docs/vohive-darwin-manager.md)
- [Vohive Darwin Web 端到端运行与前端能力呈现](docs/vohive-darwin-web.md)
- [Vohive Darwin 浏览器直连启动](docs/vohive-darwin-web-run.md)
- [Vohive Darwin 连续 URC mock 注入与安全边界](docs/vohive-darwin-urc.md)
- [Vohive Darwin 出站 SMS 事务与实机验收](docs/vohive-darwin-sms.md)

## 当前阶段：用户态 AT、PTY 与 Vohive Darwin Provider

这不是 Linux `option.c`/`GobiNet` 的直接移植，也还不是 DriverKit 驱动。它先用 macOS 的
`IOUSBHost.framework` 在普通用户态独占打开 EC20 的 **USB 接口 2**，验证 macOS 到模块的
AT bulk 通道是否真实可用，并只执行不会改变模块状态的查询命令。

当前目标固定为：

- USB VID/PID：`2c7c:0125`
- configuration：`1`
- AT interface：`2`
- 网络 interface：`4`，本程序永远不会匹配或打开它

## 安全边界

P0 探针使用硬编码 allowlist，只接受：

- `AT`
- `ATI`
- `AT+GMR`
- `AT+QCFG="usbnet"`

因此 `AT+QCFG="usbnet",1`、`AT+CFUN=1,1`、复位、拨号、短信及任意自定义命令都会在
USB 写入前被拒绝。程序不使用 USB device capture/seize；如果接口已经有 owner，它会退出，
不会强制抢占。

`ec20d` 默认也只允许只读查询，完整清单见 [P1 文档](docs/p1-ec20d.md)。PTY 启动时记录本次
attach 的 IORegistry ID，之后每条命令都按该 ID 重新匹配；模块拔出后不会把旧 PTY 透明转接到
同一 USB 端口上的另一台模块。PTY 节点权限为 `0600`，但 macOS PTY 本身不能保证独占打开，
当前必须只运行一个受信任的 Vohive/串口客户端。

Vohive 的默认 discovery 只读取 metadata；显式请求 `?with_imei=1` 或启动已配置 AT 设备时会短暂
发送只读 `AT`/`AT+CGSN`。该路径使用 attachment-scoped 缓存并串行化 cache miss，但尚未完成
跨进程的强制独占。Darwin Manager、IMEI probe 和 `SerialAT` 已共用进程内 port lease；本轮只在
mock PTY 启动完整 Manager/Worker 和 Web 流程；实机 Worker、Web、ECM 关联和模块重启恢复也已
通过一次端到端门禁。

## 使用 data 硬盘上的 Xcode 构建

```sh
export DEVELOPER_DIR=/Volumes/data/Applications/Xcode-26.5.0.app/Contents/Developer
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

cmake --fresh -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_SYSROOT="$MACOS_SDK"
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

显式给出 sysroot 是必要的：CMake 直接调用 `/usr/bin/clang` 时，仅设置 `DEVELOPER_DIR` 仍可能
捡到 `/Library/Developer/CommandLineTools` 的 SDK。上述方式无需修改全局 `xcode-select`。
如果系统可找到 Go，CTest 还会运行固定到 `go.bug.st/serial` v1.6.4 的 Vohive 串口兼容测试；
没有 Go 时 Objective-C 核心仍可构建和测试。

构建 Vohive Darwin 后端（默认按 lockfile 重建嵌入式前端）：

```sh
./tools/build-vohive-darwin.sh --arch arm64
```

输出是没有 Developer ID 签名的 bring-up Mach-O（linker 会应用 ad-hoc signature），不是可分发
`.app`。前端依赖审计、许可证、签名和打包限制见
[Darwin 构建说明](docs/vohive-darwin-build.md)。

前端直接由 Vohive 内嵌并通过浏览器访问，不需要打包原生 `.app`。受控启动和 loopback 监听方式见
[浏览器直连运行说明](docs/vohive-darwin-web-run.md)。

## 运行

先只查看接口和 endpoint：

```sh
./build/ec20-at-probe --list
```

`--list` 为读取 endpoint 描述符会短暂取得 interface 2 的独占权并立即释放；如果它已经有
owner，命令会返回失败，不会 seize。

执行完整的只读实验（两次 `AT`，然后读取型号、固件和当前 `usbnet` 值）：

```sh
./build/ec20-at-probe --experiment
```

也可以只执行一条 allowlist 内的查询：

```sh
./build/ec20-at-probe --command 'AT+QCFG="usbnet"'
```

启动实验 PTY（动态路径通过 `devices.list` 返回）：

```sh
SOCKET_PATH="${TMPDIR:-/tmp}/ec20d-live.sock"
./build/ec20d --pty --pty-location-id 0x03120000 --socket "$SOCKET_PATH"

# 另一个终端：读取 JSON 中的 at.path，并让 Vohive 显式打开该路径。
./build/ec20ctl --socket "$SOCKET_PATH" list
```

PTY 不会被 `GetPortsList` 自动枚举，也没有连续 USB reader。它已经为 `AT+CMGS=<length>` 提供
有界的 prompt/PDU/Ctrl-Z 专用事务，足以让 Vohive 发送 PDU SMS。`ec20d` 会在 detach 时发布空
snapshot，并为 reattach 分配新的 generation 和 PTY；Darwin watcher 会触发 Vohive 重扫和 Worker
重建。连续 USB reader 与跨进程多客户端强制隔离仍属于后续切片。停止 `ec20d` 会移除 PTY，
Vohive 不得持久化该动态路径。

如果一次交互式实验在 prompt 后被外部进程中止，可先停止所有串口客户端，再执行恢复命令；
它只向 interface 2 发送 ESC，随后仍必须用普通 `AT` 收到 `OK` 才能确认恢复：

```sh
./build/ec20-at-probe --recover-interactive
./build/ec20-at-probe --command AT
```

每条命令发送前先读取到 150 ms 的静默边界，陈旧数据以 `STALE` 标记；随后同时打印响应的
原始十六进制数据和解码文本。成功必须收到独立的 `OK` 行；`ERROR`、`+CME ERROR:`、
`+CMS ERROR:` 会判为模块错误，三秒内没有终止行或单条响应超过 64 KiB 则终止。

## 这一阶段的判定

- 两次 `AT` 都返回 `OK`：接口 2 的用户态 USB AT 链路成立。
- `ATI`/`AT+GMR` 返回有效信息：命令与多段 bulk 响应组装成立。
- `AT+QCFG="usbnet"` 返回值：据此决定下一步是否做 ECM 切换实验。
- 如果打开失败：先检查 macOS USB accessory 授权或是否出现了 interface owner；不要改成 seize。

当前实机已经在单独授权的 P2 实验中切换到 ECM。恢复、出口验证和已知限制见
[P2 ECM 实机记录](docs/experiment-p2-ecm-2026-08-01.md)。
