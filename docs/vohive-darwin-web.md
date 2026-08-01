# Vohive Darwin Web 端到端运行与前端能力呈现

状态：完整 Vohive Mach-O 已在 `ec20d --mock --pty` 上跑通嵌入式 Vue Web、认证 API、设备发现、
添加 Worker、overview 身份收敛、AT 终端和删除。该证据证明当前 Darwin 控制面可以被 Vohive
前端使用；它不代表真实 EC20、蜂窝数据、短信、USSD、通话或 VoWiFi 已完成。

相关提交：

- `dfa05c1`：确定性 mock EC20、完整 Web integration 和 AT-only 前端能力呈现；
- `233c200`：要求公开 overview 缓存最终收敛到 mock IMEI，避免只验证底层串口。

## 1. 为什么需要完整 Web 门禁

之前的测试分别证明了 IPC、PTY、Darwin provider 和 `modem.Manager`，但没有证明这些组件能通过
Vohive 主程序组合起来。前端还把 provider 的 `mode: "at"` 显示为 `UNKNOWN`，用户无法判断设备
为何没有网卡。

本轮把测试边界提高到实际用户路径：

```text
WebKit / Vue UI
       │ HTTP + bearer token
       ▼
Vohive embedded Web/API/Pool/Worker/modem.Manager
       │ /dev/ttys* (go.bug.st/serial)
       ▼
ec20d --mock --pty
```

测试固定从空配置启动，所有运行数据位于临时目录。`ec20d` 必须同时带 `--mock`；因此即使测试为
Manager 初始化开放任意 AT，它也无法枚举、打开或写入 USB。

## 2. 确定性 mock EC20

旧 mock 对所有命令只返回 echo + `OK`，无法让 `AT+CGSN` 解析出 IMEI，Vohive 会正确地把设备
标记为 degraded，前端也就不能执行添加流程。

现在 `--mock` 独占使用确定性响应器：

| 命令 | fixture payload |
|---|---|
| `ATI` | `Quectel`、`EC20F-MOCK`、`Revision: MOCK-1` |
| `AT+GMR` | `MOCK-1` |
| `AT+CGSN` | `867530900000001` |
| `AT+CSQ` | `+CSQ: 20,99` |
| `AT+CPIN?` | `+CPIN: READY` |
| `AT+COPS?` | mock operator |
| `AT+QCFG="usbnet"` | `usbnet=0` |

其他允许的命令继续返回 echo + `OK`，足以覆盖 Manager 初始化。真实设备路径没有调用这个响应器，
仍由 `EC20USBATTransport` 执行实际 bulk transaction。daemon self-test 同时验证 `AT` 终止行和
mock IMEI payload。

## 3. 自动端到端测试

入口：

```sh
./tests/vohive_darwin_web_integration.sh
```

若设置 `VOHIVE_BIN`，脚本使用指定 Mach-O；否则从固定 subtree 构建临时 Darwin 二进制。脚本还使用
本地 MCC/MNC fixture，启动过程不依赖下载国家表。

测试顺序：

1. 启动 `ec20d --mock --pty --allow-arbitrary-at`；
2. 启动带嵌入式前端的 Vohive 主程序并等待 `/ping`；
3. 验证 `/` 返回 VoHive SPA shell，入口 JS 的 content type 正确；
4. 用 mock 凭据登录并取得 bearer token；
5. 调用 `devices/discovered?with_imei=1`，要求出现 `ec20d-pty`、确定性 IMEI、`mode=at`、
   `network_capable=false`，且不能为 degraded；
6. 添加 AT-only 设备并要求 Worker 实际启动；
7. 轮询设备列表和公开 overview，要求运行态与 IMEI 缓存收敛；
8. 通过受管设备 API 执行 `AT+CGSN`；
9. 删除设备，SIGTERM 两个进程，并验证 socket/PTY 清理。

CTest 名称为 `vohive-darwin-web-integration`，当前根套件结果为 13/13：

```sh
ctest --test-dir build -R vohive-darwin-web-integration --output-on-failure
```

## 4. 前端变化与浏览器实测

`DiscoveredDevice.mode` 现在包含 `at`。设备添加对话框会：

- 显示 `AT / PTY`，不再显示 `UNKNOWN`；
- 没有 `enX` 时以 PTY path 作为设备卡片主标识；
- 对 `mode=at && network_capable=false` 显示“仅 AT 控制面”；
- 明确说明网络、代理和 VoWiFi 保持关闭，后端选择维持 AT。

2026-08-01 使用 Playwright CLI + WebKit 26.5 实际执行：登录 → 设备管理 → 添加设备 → 选择 mock
EC20 → 保存 → 打开 AT 终端 → 发送 `AT+CGSN`。页面显示 Worker 在线和 IMEI 响应
`867530900000001`，浏览器控制台为 0 error、0 warning。

Playwright 的 WebKit/FFmpeg 仅安装在开发用户缓存，不写入 Vohive `package.json` 或 lockfile。
自动 CTest 仍以 HTTP/API 为稳定门禁；交互式浏览器检查用于验证实际渲染和可操作性。

## 5. 构建与供应链状态

前端实际通过：

```sh
cd third_party/vohive/web
npm run lint
npm run typecheck
npm run build
```

然后由 `make -C third_party/vohive frontend-dist` 复制到 `internal/web/dist`，再嵌入 Mach-O。
生成目录继续被忽略，不提交到 Git。

`npm ci` 仍报告 16 个已知漏洞（4 moderate、12 high）。本轮没有自动执行 `npm audit fix`，正式
分发前必须逐项升级、归因或记录接受理由。

## 6. 仍然缺少的能力

当前“前端可用”已包含 mock 完整回归与真实 EC20 AT 控制面，但仍不包含未验收的业务与数据面：

- 真实 EC20 已运行 Vohive Worker/Manager，并验证身份、SIM、信号、运营商和注册；
- 没有连续 USB reader、URC、短信 `>`/Ctrl-Z transaction、USSD 或来电流程；
- `usbnet` 仍为 0，没有 ECM/MBIM/QMI session 或 `enX` 数据出口；
- 代理、流量、VoWiFi 与通话功能没有 Darwin 实机证据；
- 仍是 ad-hoc Mach-O，不是 `.app`，没有 launchd、Developer ID、公证或 DriverKit entitlement。

连续 URC 的 mock-only 注入门已在后续提交建立并通过 `+CPIN: READY` callback；下一切片继续覆盖
SMS/USSD/来电 transaction，再在明确授权下运行真实 Manager。网络能力仍优先验证 ECM，失败后再
进入 QMI/NetworkingDriverKit 数据面。
