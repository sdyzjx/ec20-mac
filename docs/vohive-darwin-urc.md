# Vohive Darwin 连续 URC mock 注入与安全边界

状态：`ec20d --mock --pty` 已能在命令响应之外注入一条主动上报记录；Vohive 的真实
`modem.Manager` 已在 race detector 下通过 `+CPIN: READY`、`+CMTI`、`+CUSD`、`RING/+CLIP`
和 `NO CARRIER` 字节路径。出站短信 prompt/Ctrl-Z transaction 也已完成。这些业务 URC
仍需要真实网络和第二台终端的实机验收。

相关提交：`0414bab`。

## 1. 字节路径

```text
ec20ctl mock-urc '+CPIN: READY'
        │ AF_UNIX / mock.urc.inject
        ▼
ec20d --mock --pty
        │ CR/LF framed unsolicited bytes
        ▼
EC20PTYBridge master → /dev/ttys* → go.bug.st/serial
        ▼
Vohive Manager readLoop → rxChan → handleURC → SIM callback
```

这条测试没有绕过串口层直接调用 `handleURC`，因此能发现 PTY framing、异步读取、命令响应与 URC
交错、停止和 fd 生命周期问题。

## 2. Bridge 并发规则

`EC20PTYBridge` 新增 `injectUnsolicitedData`。命令 handler 的响应和主动注入共享同一 write lock，
任何一条记录都会完整写完后才开始下一条，避免两个线程把字节交错。写入仍使用 nonblocking fd；
缓冲区满时同时等待 master 可写和 stop pipe，停止不会被无限阻塞。

输入必须已经包含 framing，长度限制为 1–65536 字节。Bridge self-test 验证：

- 正常 `+CUSD` 风格数据能原样到达 slave；
- 命令 framing/overflow recovery 不回归；
- bridge 停止后拒绝注入。

## 3. mock-only IPC

协议方法为 `mock.urc.inject`，命令行入口：

```sh
./build/ec20ctl --socket /absolute/path/ec20d.sock \
  mock-urc '+CPIN: READY'
```

它只在 `--mock --pty` 的 `system.hello.capabilities` 中出现。daemon 还会在服务端重复检查：

- 非 mock：`permission_denied`；
- mock 但无 PTY：`not_ready`；
- 非 1–1024 字节可打印 ASCII：`invalid_request`；
- bridge 写入失败：`transport_error`。

因此该方法不能向真实 EC20 发送字节，也不会扩大默认 AT allowlist。它是测试控制面，不是生产
Vohive API。

## 4. 当前集成门

`ec20d-vohive-manager-integration` 在 Manager ready 后设置 SIM callback，通过独立 `ec20ctl` 进程
注入 `+CPIN: READY`，并在两秒内要求收到 `READY`。之后继续执行普通 `AT`、端口 lease 冲突、
StopAndWait 与 reopen，证明一次 URC 不会破坏命令队列或关闭流程。

运行：

```sh
ctest --test-dir build \
  -R ec20d-vohive-manager-integration \
  --output-on-failure
```

根 CTest 仍为 13/13；本次增强了既有 Manager integration，而不是增加一个只调用 parser 的测试。

## 5. 已闭环的 deterministic 业务门

1. `+CUSD`：Web API 发送 USSD 后注入响应，验证 waiter channel 和 JSON 结果；
2. `+CMTI`：mock `AT+CPMS`/`AT+CMGR`/`AT+CMGD`，验证存储区切换、PDU 解码和 SMS callback；
3. `RING/+CLIP/NO CARRIER`：验证来电、号码和挂断 callback；
4. race detector 发现并修复了运行中设置 `smsCallback` 与入站处理并发读取的竞态。

下一步是在明确授权、单客户端和第二台电话配合下执行真实入站 URC 测试。
