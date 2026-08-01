# Vohive Darwin 出站 SMS 事务

本文记录 macOS 用户态实验桥如何兼容 Vohive 已有的 PDU SMS 接口，以及真实 EC20 的验收边界。
它不包含手机号、IMEI、ICCID、IMSI、SMSC 全值或短信正文。

## 事务路径

Vohive 的 `/api/sms/send` 继续调用原有 `modem.Manager`。Manager 编码 SMS-SUBMIT PDU 并写入
动态 PTY；`ec20d` 只把严格匹配 `AT+CMGS=<十进制长度>` 的命令识别为交互事务：

1. PTY 桥返回 `> ` prompt；
2. 收集可打印十六进制 PDU，最大 64 KiB；
3. Ctrl-Z 完成，ESC 取消；
4. `ec20d` 按启动时固定的 IORegistry attachment 打开 interface 2；
5. 等待模块真实 prompt，再写 PDU 和 Ctrl-Z；
6. 等待 `+CMGS`/`OK` 或 `+CMS ERROR`/`ERROR`，把最终响应交回 Vohive。

只有同时收到 `+CMGS: <mr>` 与最终 `OK` 才按提交成功处理；单独的 `OK` 不会被升格为短信成功。

普通 AT 命令仍走原来的命令—响应路径。交互态期间不会接收第二条命令，从而避免 PDU 与其他
AT 请求交错。PDU 必须是非空、偶数字节数的十六进制文本；控制字符、超长数据和非 SMS
交互命令都会被拒绝。

## 超时与恢复

Quectel 把 `AT+CMGS` 最长响应时间定义为 120 秒且由网络决定，因此 USB transport 使用 125 秒
最终响应上限，Vohive 使用 130 秒外层 watchdog。不能把普通 AT 的 3 秒超时用于短信提交。

如果调用方在 prompt 后崩溃或超时，先停止所有 PTY 客户端，再运行：

```sh
./build/ec20-at-probe --recover-interactive
./build/ec20-at-probe --command AT
```

第一条命令向 interface 2 发送原始 ESC，并显示排出的陈旧响应；第二条必须收到 `OK`。恢复工具
不打开 interface 4，也不会自动重发短信。没有明确失败回执时不得盲目重试，以免重复计费或重复
送达。

## 自动与实机验收

- `EC20PTYBridge` self-test 覆盖 CRLF 命令、分片 PDU、Ctrl-Z 和 `+CMGS/OK`；
- Vohive Web 集成测试覆盖登录、设备 Worker、`/api/sms/send` 和完整 mock 交互事务；
- SMS 相关 Go 单元测试覆盖 PDU 编码及 Manager/API 发送路径；
- 真实 EC20 在 LTE 漫游、IMS 已注册和 PS 附着条件下，通过同一 Vohive API 得到 HTTP 200、
  `status=ok`、`delivery_state=acked`，Manager 记录发送成功。

`acked` 表示模块/网络已接受 SMS-SUBMIT，不等同于收件手机的最终送达报告。当前尚未实现
状态报告关联；入站 `+CMTI`、读/删短信已按下节实机验收，USSD 和来电尚未实机验收。

## 真实入站短信

根据 [Red Pocket 官方余额查询说明](https://help.redpocket.com/how-can-i-check-my-account-balances)，
GSMA 线路可向 `3888` 发送 `Balance`。实验只发送一次，出站请求得到 `+CMGS/OK`；
约 6 秒后模块上报两个 `+CMTI` 索引。Vohive 的真实 Manager 完成：

1. 按 `SM` 存储区读取两个 PDU；
2. 重组两段长短信；
3. 识别发送方为 `3888` 并调用 `processSMS`；
4. 将 117 字符入站记录写入数据库（正文不入库到 Git）；
5. 在前端会话 API 中与对应出站查询同时可见。

入站短信比 SIM 身份同步更早到达时，数据库先用 `imsi:` 临时键保留记录。
`UpsertSIMCardIdentity` 现在会在同一事务内把 `sms`、`sms_contacts` 和 `sms_delivery`
在线重键到真实 ICCID，避免数据库有短信但前端按设备查询为空。

## 当前安全边界

- `ec20d` 默认只读策略仍拒绝短信；只有明确的开发实验 `--allow-arbitrary-at` 才允许提交；
- 生产应用需要把短信发送做成独立 capability 和用户授权，而不是沿用任意 AT 开关；
- 普通日志不得记录号码、PDU、正文或 SIM 身份；
- PTY 是 bring-up 兼容层，正式应用仍需要 DriverKit 串口、跨进程独占和持续 URC reader。
