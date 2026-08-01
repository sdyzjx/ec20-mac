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

## 已发现的边界

- `AT+CGATT?` 的实时结果为 `1`，但同一时刻 overview 缓存仍显示
  `ps_attached=false`；需修正 AT runtime refresh 的字段同步。
- `network_enabled=false`、`data_connected=false`是预期结果：当前只完成蜂窝注册和
  PS attach，尚无 ECM/MBIM/QMI 的 macOS IP 数据面。
- `AT+CCHC=1..4` 在该固件上返回 `ERROR`，但不阻断 Manager 初始化、SIM READY
  或蜂窝注册。

