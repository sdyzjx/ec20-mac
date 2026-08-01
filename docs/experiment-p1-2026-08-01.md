# P1 `ec20d`、PTY 与 Vohive 串口兼容实验

日期：2026-08-01（Asia/Taipei）

## 1. 目的与结论

本轮验证 P1 用户态链路：`ec20d` 在 macOS 创建受限 PTY，把 Vohive 使用的 Go 串口库连接到
EC20 interface 2，并且在模块拔插身份变化时 fail closed。

结论：

- `ec20d --pty` 已能发布 owner-only `/dev/ttys*`；
- Objective-C POSIX smoke 和 `go.bug.st/serial` v1.6.4 smoke 均通过 mock 集成；
- Go smoke 已通过 registry-pinned 实机 PTY 发送只读 `AT`，收到独立 `OK` 并退出 0；
- daemon 停止后 socket、PTY 和 USB interface 均正确释放；
- 七项 CTest 全部通过，CTest 路径不访问 USB。

这证明 Vohive 的基本串口 transport 可以使用 P1 PTY，不代表 URC、短信、多客户端、热插拔、
ECM/QMI 或完整 Vohive Darwin 应用已经完成。

## 2. 环境与硬件基线

- macOS：26.2 arm64，build `25C56`；
- Xcode：26.5 (`17F42`)；
- Go：`go1.26.0 darwin/arm64`；
- Go serial dependency：`go.bug.st/serial` v1.6.4，由独立 `go.mod`/`go.sum` 固定；
- PTY 功能代码基线：`7cc0288`（`feat(ec20d): add Vohive-compatible PTY bridge`）；
- USB：Quectel `2c7c:0125`；
- 模块：EC20F，固件基线 `EC20CEFDGR06A08M4G`；
- 当前 attach 的 location ID：`0x03120000`；
- AT：configuration 1、interface 2；
- 网络：interface 4，本轮没有打开或写入；
- P0 已知 USB 模式：`usbnet=0`，本轮没有修改或重启模块。

IORegistry registry ID 是每次 attach 动态生成的身份。本记录故意不保存其具体值，也不把它当作
IMEI 或其他长期身份。

## 3. 构建与七项自动测试

构建命令：

```sh
export DEVELOPER_DIR=/Volumes/data/Applications/Xcode-26.5.0.app/Contents/Developer
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

cmake --fresh -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_SYSROOT="$MACOS_SDK"
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

2026-08-01 实际结果：

| # | 测试 | 结果 |
|---:|---|---|
| 1 | `ec20-at-probe-self-test` | Passed |
| 2 | `ec20-ipc-protocol-self-test` | Passed |
| 3 | `ec20d-self-test` | Passed |
| 4 | `ec20ctl-self-test` | Passed |
| 5 | `ec20d-mock-integration` | Passed |
| 6 | `ec20d-pty-mock-integration` | Passed |
| 7 | `ec20d-vohive-serial-integration` | Passed |

```text
100% tests passed, 0 tests failed out of 7
```

前四项使用内存/self-test fixture；后三项明确启动 `ec20d --mock`。因此这七项不会枚举或打开
实机 USB。第七项只在 CMake 找到 Go 时注册，并执行：

```sh
cd tools/vohive-serial-smoke
GOWORK=off go run -mod=readonly . /dev/ttysNNN AT
```

Go smoke 使用 `serial.Open` 的 115200/8N1 设置、75 ms read timeout、3 秒 transaction deadline
和 64 KiB 响应上限。它只接受 P0 四条精确只读命令，识别独立 `OK`、`ERROR`、`+CME ERROR:`
和 `+CMS ERROR:`，但不打印收到的响应正文。

## 4. PTY mock 验证

集成脚本创建私有临时目录并启动：

```sh
ec20d --mock --pty --socket <temp>/ec20d.sock
```

`ec20ctl list` 返回唯一动态 `/dev/ttys*`。Foundation 可能把 JSON 中的 `/` 编码为 `\/`，测试
只为提取路径做 unescape，不使用 `jq`。随后两种 client 均发送 `AT\r` 并收到独立 `OK`：

- `ec20-pty-smoke`：POSIX open、raw termios、poll、EINTR/EAGAIN 和 64 KiB 上限；
- Vohive Go smoke：`go.bug.st/serial` v1.6.4、115200/8N1、75 ms read timeout。

测试成功后向 daemon 发送 SIGTERM，等待正常退出并确认 Unix socket 已删除。整个 mock 流程不
访问 USB。

## 5. Registry-pinned 实机验证

### 5.1 启动并固定本次 attach

使用已知 location ID 显式选择模块：

```sh
./build/ec20d \
  --pty \
  --pty-location-id 0x03120000 \
  --socket <temp>/ec20d.sock
```

启动时 daemon 要求 location ID 恰好匹配一台 `2c7c:0125`，并记录该 USB service 的非零
registry ID。PTY 存续期间，每一条命令都用这个 registry ID 重新打开 configuration 1/interface 2。

这样可以防止 TOCTOU 误选：如果原 EC20 被拔出、同一 Hub 端口插入另一模块，location ID 可能
相同，但新 attach 的 registry ID 不同；后续 open 会失败并返回标准 PTY `ERROR`，不会把命令
发送给替换模块。当前实现不会自动把新模块纳入旧 PTY。

### 5.2 Vohive 串口库实测

从 `ec20ctl list` 读取本次动态 `at.path=/dev/ttysNNN`，然后执行：

```sh
cd tools/vohive-serial-smoke
GOWORK=off go run -mod=readonly . /dev/ttysNNN AT
```

实际结果：

```text
vohive serial smoke: PASS
```

- 退出码：0；
- 发送命令：只有 `AT`；
- 模块终止行：独立 `OK`；
- Go 日志：没有输出 AT 响应正文；
- 没有发送配置、复位、拨号、短信或 SIM/eSIM 写命令。

### 5.3 退出与资源释放

向 daemon 发送 SIGTERM 后：

- Unix socket 被安全删除；
- daemon 的 PTY worker 被唤醒并 join；
- master、slave anchor 和 stop pipe 全部关闭，动态 PTY 消失；
- 再执行 `./build/ec20-at-probe --list` 返回 0，证明 interface 2 可以重新打开。

daemon 只删除自己创建且 device/inode 仍匹配的 socket；PTY `/dev` 节点由系统管理，代码不直接
unlink 系统设备节点。

## 6. 安全边界复核

- Unix socket 原子创建为 `0600`，并通过 `getpeereid` 只接受同 effective UID；
- PTY slave 是当前用户拥有的字符设备，权限验证为 `0600`；
- PTY 和 RPC 共用 daemon 的默认只读 AT policy，危险命令在 USB open/write 前拒绝；
- smoke 工具没有任意命令开关，只允许 `AT`、`ATI`、`AT+GMR`、`AT+QCFG="usbnet"`；
- USB transport 不 capture/seize，只匹配 configuration 1/interface 2；
- 启动时的 location 选择会提升为本次 attach 的 registry ID pin；
- 没有执行 `AT+QCFG="usbnet",1`，没有改变 `usbnet=0`；
- 没有复位或重新枚举模块，没有打开、读取或写入 interface 4；
- 测试日志没有记录 IMEI、SIM、APN、短信或 AT 响应正文。

## 7. 已知限制

### 7.1 只有协作式单客户端

`devices.list` 报告 `at.ownership="cooperative_single_client"`。`0600` 只隔离其他 UID，不阻止
同 UID 的两个进程同时打开 slave。PTY 是一个共享 byte stream；两个 writer 的字节可能交错，
bridge 即使在单 worker 中串行执行完整命令，也无法恢复原始 client 边界。因此当前必须由应用
编排保证只有一个 PTY client，不能把它当作生产级独占串口。

### 7.2 每条命令重新开关 USB

当前 PTY handler 对每条命令按固定 registry ID 打开 interface 2，读取到终止行后立即关闭。
优点是不会长期持有 USB，也能拒绝替换模块；代价是没有常驻 reader，无法实时接收 URC。
transaction 开始时排出的 stale input 只能附加到当前 PTY 响应，不能替代有 revision 的 URC
event stream。

### 7.3 Stop 依赖当前同步 transport 返回

stop pipe 能立即唤醒空闲 PTY worker；如果 worker 正在同步 USB handler 内，`stop`/SIGTERM 要
等待当前 transaction 返回后才能 join。AT 读取有固定 timeout 和响应上限，但 interface open 与
整个同步 handler 没有独立取消或 stop deadline，因此不能把退出等待视为严格有界；这仍需在常驻
transport 阶段补齐。

### 7.4 其他未实现能力

- `devices.watch`、真实 generation、拔出事件、自动重连；
- 响应/URC 分流和订阅；
- 短信 `>` prompt、Ctrl-Z payload、多阶段 AT transaction；
- PTY DTR/RTS 等完整 modem-control 语义；可行性实验中 `SetDTR` 返回 `ENOTTY`；
- Vohive Darwin DeviceProvider、网络 controller 和 per-interface socket/DNS binding；
- ECM、QMI、标准 `/dev/cu.*` 和 `enX`。

## 8. 下一步

1. 统一 PTY/RPC owner，加入强制单 client、并发 accept、队列、租约超时和公平调度；
2. 用 registry-pinned、可取消的常驻 USB transport 替代每命令 open/close，实现实时 URC；
3. 增加 IOKit watch、generation、拔出取消和显式重连；
4. 实现短信 prompt 等有状态 AT 专用 API；
5. 将设备快照、事件和 PTY/未来串口路径接入 Vohive Darwin backend；
6. 准备独立恢复通道和恢复文档后，再进入 P2 ECM 模式切换实验。
