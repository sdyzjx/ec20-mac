# P2 ECM 与 Vohive 热插拔实机记录（2026-08-01）

本记录验证 Quectel EC20 `2c7c:0125` 在 macOS 上使用标准 CDC-ECM 描述符时，可以直接复用
Apple 网络驱动，并能被 Vohive Darwin provider 与同一模块的 AT attachment 关联。所有设备身份、
SIM 身份、公网/私网地址、socket 路径和动态 PTY 路径均不写入仓库。

## 实验范围

- EC20 interface 2：`ec20d` 用户态 AT/PTY bridge；
- EC20 interface 4：CDC-ECM，由 `AppleUserECM` 接管；
- 模块 USB 网络配置：`AT+QCFG="usbnet",1`；
- Vohive：真实 Darwin backend、真实 Web 前端、`EC20DHardwareProvider`、Darwin hotplug watcher
  和 ECM network controller；
- 系统默认路由保持原样，所有出口探测显式绑定 ECM 接口；
- 本轮没有发送新的短信，也没有执行 USSD。

## USB 与网络关联结果

IORegistry 回溯确认网络接口的 USB parent 同时满足：

| 字段 | 验收值 |
|---|---|
| USB VID/PID | `2c7c:0125` |
| USB configuration | `1` |
| network interface number | `4` |
| USB class/subclass | Communications / Ethernet Networking Control Model |
| interface owner | `AppleUserECM` |
| macOS network interface | 动态 `enX`，本机本轮为 `en11` |
| data plane | Ethernet |
| control plane | AT |

`ec20d` 只在这些字段全部匹配时把 `enX` 写入同一设备 snapshot。Vohive 客户端再次校验
`mode=ecm`、`data_plane=ethernet`、`managed_by=macos.apple_user_ecm` 和接口名格式；不根据“机器上
恰好存在一个 `enX`”猜测关联。

## 出口验收

ECM 接口获得了私有 IPv4 地址和全局 IPv6 地址，link 为 active。系统默认路由在实验前后均未
指向 ECM 接口。为排除系统 HTTP 代理和 DNS 的影响，公网探测使用固定远端地址、禁用代理并将
socket 显式绑定到 ECM 接口：

| 测试 | 结果 |
|---|---|
| 绑定 ECM 的 IPv4 HTTPS | HTTP 200，通过 |
| 故意指定不存在接口 | fail closed，通过 |
| 绑定 ECM 的 IPv6 固定目标 | 超时，未通过 |
| 系统默认路由保持原值 | 通过 |

因此当前只能声明 **ECM IPv4 数据面成立**，不能声明 IPv6 已完成。网络控制器在接口不存在、
link 未运行、没有地址或绑定公网探测失败时返回错误，不会回退到 Wi-Fi/VPN。该固件的 ECM 会话
由固件和 macOS 管理，Vohive 的 `Disconnect` 与 `RotateIP` 明确返回“不支持”，不会伪报成功。

## Vohive Web 与热插拔验收

真实 Vohive 前端完成登录后，仪表盘和设备详情页显示：

- 一台 EC20 在线；
- 动态 `enX` 已关联；
- LTE、中国联通、已注册（漫游）；
- 浏览器控制台没有 error 或 warning。

随后通过前端“重启模组”调用 Vohive 现有 reboot API。恢复过程的关键状态为：

1. `ec20d` 在 USB detach 后发布新的空 snapshot revision；
2. Darwin watcher 观察 revision 变化并触发 Vohive 重新扫描；
3. 旧 Manager 停止，旧 PTY attachment 不会透明转接到新设备；
4. USB reattach 产生新的 generation 和新的 PTY 路径；
5. ECM 稍后重新出现，snapshot 再次关联同一个 `enX`；
6. Vohive 自动重建 Worker，重新识别 SIM、LTE 漫游注册和 ECM 网络；
7. 前端无需手工刷新，恢复为在线；恢复后绑定 IPv4 HTTPS 再次返回 HTTP 200。

早期实现曾允许 macOS 立即复用同一个 PTY 名称，使旧 Worker 有机会打开新 attachment。当前
`ec20d` 会暂时保留一个不再发布的 retirement PTY，把旧名称钉住，直到新 attachment 已获得不同
PTY 后再释放；Vohive 仍以 attachment key 和 generation 判定是否重建，而不以路径字符串为身份。

## HTTP 与 SOCKS5 代理出口

通过真实 Web 的“代理管理 → 本地出站代理”创建两个仅监听 loopback 的实例：SOCKS5 和 HTTP。
两个实例都绑定同一 EC20 设备，并在页面显示运行中。固定公网 IPv4 目标的 HTTPS 请求分别通过
两种代理返回 HTTP 200。

为避免把“代理能返回 200”误判为蜂窝出口成立，验收期间同时采集 Vohive 进程连接：

- 客户端到代理的连接为 `127.0.0.1` loopback；
- Vohive 对公网目标的子连接源地址属于 ECM，interface 明确为 `en11`；
- 系统默认路由仍指向原 VPN 接口，没有改写为 ECM；
- 两个代理监听地址均为 `127.0.0.1`，未暴露到局域网。

Darwin `netbind` 使用 `IP_BOUND_IF`/`IPV6_BOUND_IF`。代理层新增不存在接口的 fail-closed 回归，
接口解析或 `setsockopt` 失败会让 `DialContext` 返回错误，不会使用系统默认路由重试。

## 自动测试证据

- CMake build 通过；
- `ec20d-self-test`、mock、PTY mock、Vohive serial 和 Manager 五项定向 CTest 通过；
- ec20d client、Darwin provider、Darwin watcher 和 ECM controller Go 测试通过；
- ECM live test 同时覆盖真实接口成功与不存在接口 fail-closed；
- `internal/device` 完整包测试通过；
- `cmd/vohive-darwin-probe` 通过。
- `GOWORK=off go test ./...` 在 Darwin 全量通过。

这些结果证明单模块重启恢复，不等于 P2 的 20 次重连、10 次拔插/重启长稳门槛已经完成。

## 恢复与限制

恢复到实验前 USB 网络模式需要先停止 Vohive 和 `ec20d`，通过独立 AT 恢复通道执行：

```text
AT+QCFG="usbnet",0
AT+CFUN=1,1
```

重启后应确认 interface 2 的 `AT` 仍返回 `OK`，并确认 ECM `enX` 消失。不要在没有 UART、
Linux/Windows 或其他可靠 AT 恢复通道时自动切换 USB profile。

当前未完成项：

- ECM IPv6 出口；
- 代理域名解析策略与 DNS 泄漏门禁（固定 IP 的 HTTP/SOCKS5 出口已通过）；
- 20 次重连、10 次重启/拔插以及睡眠唤醒；
- 多模块并发；
- 连续 USB reader 和产品化 `/dev/cu.*` 串口；
- `.app`、launchd、Developer ID、公证与 DriverKit entitlement。
