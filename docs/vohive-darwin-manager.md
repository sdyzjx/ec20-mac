# Vohive Darwin modem.Manager 串口所有权与生命周期

状态：`modem.Manager` 已在 `ec20d --mock` PTY 上完成启动、初始化、AT 命令、停止和 lease 释放的
race 检测；真实 EC20 上也已通过 Vohive HTTP API 启动 Worker/Manager，完成 SIM READY、
运营商、信号、注册和 PS attach 验证。短信、USSD、来电和 IP 数据面仍未验收。

实现提交：`7753554`（`fix(darwin): make modem port ownership fail closed`）。
验证日期：2026-08-01。

## 1. 为什么必须平台化

固定 Vohive 上游的 `Manager.Start` 会先调用 `fuser`，解析占用 PID，再发送 `SIGTERM`。这套逻辑
依赖 Linux `/proc/self/task`，在 Darwin 上既不能正确识别当前进程的所有执行上下文，也不符合
macOS Host App 的所有权模型。更危险的是，`ec20d` 为维持 PTY 生命周期会保留 slave anchor，
Darwin `fuser` 可能把提供 PTY 的 daemon 本身视为占用者。

本轮拆分后的策略：

| 平台 | 打开前行为 |
|---|---|
| Linux | 保留原 `fuser`/PID/SIGTERM 行为，避免改变上游现有部署 |
| Darwin | 只接受绝对 `/dev/*`、直接字符设备；拒绝普通文件和 symlink；绝不执行 `fuser` 或发信号 |
| 其他非 Linux | 不执行进程 takeover，由 serial library 的 open 结果决定 |

Darwin 若无法打开端口会返回错误，不能为了“自动恢复”终止其他进程。这是 fail closed，不是自动
抢占。

## 2. 进程内 serial lease

macOS PTY 允许同一用户多次打开，单靠 `serial.Open` 不足以阻止两个 reader 分食响应。本轮新增
以规范化 port path 为键的进程内 lease，覆盖：

- 长生命周期 `modem.Manager`；
- discovery 的 `ProbeIMEI`；
- API 使用的轻量 `SerialAT`。

同一路径已经由 Manager 持有时，IMEI probe 和 `SerialAT` 会在打开设备前返回包含当前 owner 的
错误。Manager 打开、read-timeout 配置或预检失败时会立即释放 lease；`Stop` 关闭 port 后释放，
随后 one-shot AT 客户端可以重新取得同一路径。

这只是 Vohive 进程内边界。另一个终端程序或另一个 Vohive 进程不会自动遵守该 map；成品 Host
App 仍要确保单实例，并由 `ec20d`/launchd 提供跨进程 lease 或拒绝第二个 backend。当前
`ownership=cooperative_single_client` 不能表述成内核级独占。

## 3. Manager 生命周期并发修复

把真实 Manager 放到 race detector 后，发现初始化 goroutine 与 `Stop` 并发读写 `running`、
`healthy`，同时 `Stop` 清空仍被 command loop 读取的 port 指针。本轮修改：

- `running`/`healthy` 改为 `atomic.Bool`；
- port 在后台 loop 存活期间保持稳定引用，`Stop` 只关闭，不并发清空；
- 设置 read timeout 失败也会关闭 port、释放 lease 并返回错误；
- 对受影响测试改用原子状态写入。

Manager mock 生命周期现在在 `go test -race` 下通过。

## 4. mock PTY 集成

CTest `ec20d-vohive-manager-integration` 执行：

1. 启动 `ec20d --mock --pty --allow-arbitrary-at`；
2. 通过 `ec20ctl devices.list` 取得唯一 owner-only `/dev/ttys*`；
3. 用真实 `go.bug.st/serial` 和真实 `modem.Manager` 打开该 PTY；
4. 等待 Manager init ready；
5. 通过 `ec20ctl mock-urc` 注入 `+CPIN: READY`，验证连续 reader 和 SIM callback；
6. 执行额外 `AT`，验证异步 URC 后命令/响应 loop 仍保持同步；
7. 验证运行中 `ProbeIMEI` 被 Manager lease 拒绝；
8. `StopAndWait` join read/run/cleanup loops；
9. 用 `SerialAT` 重新打开同一 PTY并收到 `OK`，证明 lease 已释放；
10. 停止 daemon，确认 socket 和 PTY 都清理。

`--allow-arbitrary-at` 只用于 `--mock` 进程。Manager 初始化会发送 `ATE0`、`AT+CMGF=0`、
`AT+CNMI=...`、`AT+CLIP=1`、`AT+QPCMV=1,2`，默认 ec20d 只读 allowlist 会拒绝这些命令；mock
模式不会枚举或写入 USB，所以此测试不会改变真实模块。

mock 对普通命令返回 echo + `OK`，并为 `ATI`、`AT+GMR`、`AT+CGSN`、`AT+CSQ`、`AT+CPIN?`、
`AT+COPS?` 和只读 `usbnet` 查询提供确定性 EC20 风格 payload。这使完整 Web 流程可以验证 IMEI、
信号和 AT 终端解析。新增的 mock-only IPC 还能在 Manager ready 后异步注入 URC，目前已证明
`+CPIN: READY` 能穿过 PTY 连续 reader 并到达 SIM status callback；它仍不能证明真实 SIM、短信
或通话已经工作。

运行：

```sh
./tests/ec20d_vohive_manager_integration.sh

ctest --test-dir build \
  -R 'ec20d-vohive-manager|vohive-darwin-modem-safety' \
  --output-on-failure
```

当前根 CTest 为 13/13，其中新增完整 Web integration。Provider integration 也由 harness 显式
SIGTERM daemon，避免
`--max-requests` 在最后一个 response 发出后立即移除 PTY、与客户端 `lstat` 认证形成竞态。

## 5. 真实设备门禁

2026-08-01 在明确授权后已执行实机 Manager 门禁。初始化序列会改变当前会话的
echo、短信格式/通知和来电/UAC 上报设置，因此后续实机回归仍必须：

1. 明确授权这些易恢复、但会改变运行状态的 AT 命令；
2. 停止其他串口客户端并确认只有一个 Vohive/Manager；
3. 保持 interface 4 和 `usbnet=0` 不变；
4. 先限定单设备、只读查询和可控停止；
5. 记录每条命令、响应、退出和 PTY 清理结果。

已确认 Worker 健康启动、自动选网、LTE 漫游注册和 `AT+CGATT: 1`；实验证据见
[真实 EC20 接入记录](experiment-vohive-real-2026-08-01.md)。

接下来在已经成立的连续 reader/URC 注入门上分别验证 `+CMTI`、`+CUSD`、`RING/+CLIP` 和短信
`>` prompt/Ctrl-Z transaction。一次 SIM 状态 URC 通过不能替代这些功能门禁。
