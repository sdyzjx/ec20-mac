# Vohive Darwin 浏览器直连运行

macOS 版不要求原生前端容器。当前交付形态是两个本地用户态进程：`ec20d` 负责 EC20 USB/PTY
与 ECM snapshot，Vohive 提供 API 和内嵌 Web；用户直接用浏览器访问 loopback URL。

## 构建

```sh
export DEVELOPER_DIR=/Volumes/data/Applications/Xcode-26.5.0.app/Contents/Developer

cmake --build build --parallel
./tools/build-vohive-darwin.sh --arch arm64
```

构建结果仍是开发版 Mach-O，不需要 `.app`。Vohive 二进制已经包含 `web/dist`，运行时不需要
Node.js 或单独的前端开发服务器。

## 配置与启动

复制模板并把占位密码替换为只在本机使用的强密码：

```sh
cp config/vohive-darwin.example.yaml config/vohive-darwin.local.yaml
chmod 0600 config/vohive-darwin.local.yaml
# 编辑 web.password，不能保留 CHANGE_ME_BEFORE_START

./tools/run-vohive-darwin.sh \
  --config config/vohive-darwin.local.yaml
```

脚本会：

1. 拒绝符号链接配置、占位密码、非法端口和已被占用的监听端口；
2. 创建权限为 `0700` 的临时 runtime 目录和 `ec20d` Unix socket；
3. 启动 `ec20d --pty --allow-arbitrary-at`；
4. 强制 Vohive 只监听 `127.0.0.1`，不受 YAML 中旧监听值影响；
5. Web 就绪后打印 `http://127.0.0.1:17575/`；
6. `Ctrl-C` 或任一子进程退出时停止另一进程并清理临时 socket。

Vohive 的 Worker 与 ECM interface 是异步收敛的。启动阶段会按有界退避重试恢复数据库中已启用的
本地代理；不需要在每次进程重启后从网页手工启用。实机冷启动验收中，已保存的 HTTP 与 SOCKS5
实例均在 ECM interface 就绪后恢复为“运行中”，并分别完成固定 HTTPS 目标的 HTTP 200 请求。

“卡策略 → 开启网络”成功后会异步探测并缓存 ECM 的公网 IP。Darwin ECM 的 PDP 连接仍由固件管理；
该开关表达 Vohive 是否使用数据面，并负责触发公网地址探测，而不是接管 macOS 默认路由。

如果机器连接多个模块，可用 `--location-id 0x...` 固定本次 PTY 选择。该值仅用于运行选择，不能
作为持久设备身份。端口可用 `--port 17576` 修改。

## 首次网页操作

1. 打开脚本打印的 URL，用 YAML 中的 `web.username`/`web.password` 登录；
2. 进入“设备管理”，点击“重新扫描”；
3. 确认发现项显示 `ec20d-pty`、`mode=ecm` 和动态 `enX`；
4. 添加设备后等待 SIM、LTE 注册和 ECM 网络状态收敛；
5. 本地代理只监听 `127.0.0.1`，不要使用默认的 `0.0.0.0`。

Vohive 会把业务数据库放在 `third_party/vohive/data/`（已被 Git 忽略）。真实 IMEI、ICCID、IMSI、
短信、电话号码和动态网络地址不得进入提交、示例配置或公开日志。

## 当前限制

- 这是用户态开发运行器，不是 launchd 服务；注销或重启后需要再次启动；
- PTY 仍没有产品串口的连续 USB reader 与系统级独占语义；
- ECM IPv4、HTTP/SOCKS5 固定公网目标已通过；IPv6 和代理 DNS 泄漏门禁仍待完成；
- 只允许本机浏览器访问；若未来需要局域网访问，必须先增加 TLS、CSRF/会话与访问控制审计，不能
  简单改成 `0.0.0.0`。
