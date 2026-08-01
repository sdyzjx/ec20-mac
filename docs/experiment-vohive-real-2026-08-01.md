# Vohive Darwin 真实 EC20 接入实验（2026-08-01）

本记录验证真实 `2c7c:0125` EC20 能通过当前 macOS 用户态链路进入
Vohive 的现有 AT backend，并由 Vohive HTTP API 读取蜂窝网络状态。本文不保存
IMEI、ICCID、IMSI、socket attachment key 或动态 PTY 路径。

## 实验边界

- USB location：`0x03120000`；
- USB VID/PID：`2c7c:0125`；
- `ec20d --pty --allow-arbitrary-at` 接管 interface 2；
- Vohive Darwin 使用 `EC20DHardwareProvider` 发现设备；
- 通过 `POST /api/devices` 启动真实 AT Worker；
- 通过 `GET /api/devices/:id/operator_selection` 和
  `POST /api/devices/:id/actions/at` 取得本文中的状态；
- 没有修改 `usbnet=0`，没有打开 interface 4，没有创建 macOS 数据网卡。

## 结果

Vohive 设备列表报告 Worker `running=true`、`healthy=true`、
`control_online=true`、`radio_registered=true`，生命周期为 `online`。

| 查询 | 结果 |
|---|---|
| Vohive operator selection | `automatic` |
| `AT+COPS?` | PLMN `46001`，LTE/E-UTRAN |
| `AT+QSPN` | `CHN-UNICOM` / `UNICOM` |
| `AT+CREG?` | `stat=5`，已注册（漫游） |
| `AT+CGREG?` | `stat=5`，已注册（漫游） |
| `AT+CEREG?` | `stat=5`，已注册（漫游） |
| `AT+CGATT?` | `1`，PS attached |
| `AT+CNUM` | 空，SIM 未提供可读 MSISDN |

因此当前访问网为中国联通 `46001`，当前 SIM 以漫游状态注册。
`AT+CNUM` 返回空值不表示没有号码，只表示 SIM 中没有写入或运营商没有
向终端暴露 MSISDN；不能从 IMSI/ICCID 可靠推导手机号。

## 出站短信验收

真实发送使用 Vohive 原有 `POST /api/sms/send` 接口，数据经过
`Vohive Manager -> PTY -> ec20d -> IOUSBHost interface 2 -> EC20`。实现没有绕过 Vohive
直接提交短信。目标号码和短信正文不写入仓库。

首次 LTE 漫游实验在 `IMS=0` 时得到 `+CMS ERROR: 350`；把短信承载偏好设为分组域
优先并按模块能力启用 IMS、重启后，状态收敛为：

| 查询 | 验收值 |
|---|---|
| `AT+QCFG="ims"` | `1,1`，IMS 已启用且已注册 |
| `AT+CGSMS?` | `2`，PS 优先、CS 回退 |
| `AT+CEREG?` | `stat=5`，LTE 漫游注册 |
| `AT+CGATT?` | `1` |
| IMS PDP | 已取得地址（地址已脱敏） |

随后同一 Vohive API 请求在约 1.58 秒内返回 HTTP 200、`status=ok` 和
`delivery_state=acked`；Manager 日志记录 PDU 提交成功，Vohive 数据库生成状态为已发送的
出站记录。这证明模块和访问网已接受 SMS-SUBMIT；最终送达收件终端仍应以收件方或运营商的
状态报告为准。

本次实机状态变更及恢复值：

- `AT+QCFG="ims",1` 后执行 `AT+CFUN=1,1`；实验前值为 `0`，如需恢复，设置为 `0` 后重启；
- `AT+CGSMS=2`；实验前值为 `1`，如需恢复可执行 `AT+CGSMS=1`；
- `usbnet` 保持 `0`，interface 4 始终未打开。

自动回归证据：CMake/CTest 13/13 通过，其中 Web 集成测试会从 `/api/sms/send` 穿过完整
mock prompt/Ctrl-Z 事务；Vohive SMS 相关 Go 包定向测试通过。上游 `go test ./...` 仍有与本次
功能无关的既存测试桩/数据库初始化失败，不能据此宣称全仓 Go 测试已清零。

## 已发现的边界

- `AT+CGATT?` 的实时结果为 `1`，但同一时刻 overview 缓存仍显示
  `ps_attached=false`；需修正 AT runtime refresh 的字段同步。
- `network_enabled=false`、`data_connected=false`是预期结果：当前只完成蜂窝注册和
  PS attach，尚无 ECM/MBIM/QMI 的 macOS IP 数据面。
- `AT+CCHC=1..4` 在该固件上返回 `ERROR`，但不阻断 Manager 初始化、SIM READY
  或蜂窝注册。
- 出站 SMS 已验收；入站 `+CMTI`、读取/删除、USSD、来电和热插拔仍未实机闭环。
