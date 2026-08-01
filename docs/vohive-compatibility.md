# EC20 macOS 与 Vohive 兼容契约

状态：设计基线  
契约版本：`ec20.vohive/1.0`  
Vohive 基线：[`1239t/vohive@0965af3`](https://github.com/1239t/vohive/tree/0965af3d3c59bf51ef09ebd7edcafc06f516321f)

## 1. 目标与边界

本文定义 EC20 macOS 驱动、用户态伴随服务 `ec20d` 与 Vohive Darwin provider 之间的稳定边界。
目标是让 Vohive 在 macOS 上获得与 Linux 版等价的用户功能，同时避免伪造 Linux 的 `/sys`、
`udev`、`ttyUSB*` 或 `/dev/cdc-wdm*`。

兼容目标分为两层：

- **功能兼容**：设备发现、AT 管理、短信、SIM/eSIM、联网、代理和多模块隔离在 macOS 上可用；
- **源码兼容**：Vohive 的业务层继续使用现有 backend、worker 和 proxy 抽象，只增加 Darwin
  provider、ECM/QMI controller 及平台 socket binding。

本契约不要求 Linux 与 macOS 使用相同的内核或设备节点。DriverKit 和 `ec20d` 只提供传输、
设备拓扑与状态，不承载短信、eSIM、代理池等 Vohive 业务逻辑。

## 2. 参考架构

```text
EC20 interface 2
    ├─ 实验阶段：IOUSBHost -> ec20d -> AT RPC
    └─ 成品阶段：EC20Serial.dext -> /dev/cu.ec20-<instance>-at
                                              |
                                      Vohive AT backend

EC20 network function
    ├─ ECM：AppleUserECM.dext -> enX -> Vohive ECMNetworkController
    └─ QMI：EC20Network.dext/ec20d -> enX + QMI RPC -> Vohive QMINetworkController

IORegistry/ec20d -> 设备清单、AT 与 enX 关联、热插拔事件 -> Darwin provider
Vohive proxy/netprobe -> IP_BOUND_IF/IPV6_BOUND_IF -> 对应 enX
```

第一阶段以 **AT + ECM** 达到大部分用户功能。需要 QMI WDS/NAS/DMS/UIM/WMS 原生语义时，
再增加 QMI transport；不把完整 QMI 作为串口驱动的前置条件。

Vohive 当前已有可复用的边界：

- AT transport 通过 `go.bug.st/serial` 打开路径，适合标准 macOS `/dev/cu.*`：
  [`internal/modem/serial_at.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/modem/serial_at.go)；
- 业务 backend 已将 AT、QMI、MBIM 分层：
  [`internal/backend/backend.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/backend/backend.go)、
  [`internal/backend/factory.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/backend/factory.go)；
- 数据连接通过 `NetworkController` 抽象：
  [`internal/device/network_controller.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/device/network_controller.go)。

## 3. 契约版本与兼容规则

### 3.1 版本标识

所有 `ec20d` 请求、响应、事件和持久化快照必须包含：

```json
{
  "schema": "ec20.vohive/1",
  "api_version": "1.0"
}
```

- `schema` 最后一段是主版本；未知主版本必须拒绝并提示升级；
- `api_version` 使用 `主版本.次版本`；同一主版本内只能增加可选字段、方法或 capability；
- 客户端必须忽略未知 JSON 字段，服务端不得改变已有字段的含义或枚举值；
- 功能是否可用以 `capabilities` 为准，不能只根据版本号猜测；
- 删除字段、改变默认行为或改变设备身份算法必须升级主版本。

### 3.2 握手

Vohive 连接后首先调用 `system.hello`：

```json
{"schema":"ec20.vohive/1","api_version":"1.0","id":"1","method":"system.hello","params":{"client":"vohive","client_version":"<version>"}}
```

成功响应：

```json
{
  "schema": "ec20.vohive/1",
  "api_version": "1.0",
  "id": "1",
  "ok": true,
  "result": {
    "server": "ec20d",
    "server_version": "<version>",
    "daemon_instance_id": "5A75B4E0-9D73-4EC4-9CF0-C7CA75019688",
    "capabilities": ["devices.list", "devices.watch", "at.rpc"]
  }
}
```

错误响应统一使用：

```json
{
  "schema": "ec20.vohive/1",
  "api_version": "1.0",
  "id": "1",
  "ok": false,
  "error": {
    "code": "unsupported_api",
    "message": "ec20.vohive/2 is not supported",
    "retryable": false
  }
}
```

首版稳定错误码为 `unsupported_api`、`invalid_request`、`not_found`、`not_ready`、
`busy`、`permission_denied`、`timeout`、`device_removed`、`transport_error` 和
`resync_required`。

## 4. 本地 IPC

### 4.1 Transport

- 成品默认使用 Unix domain socket：`/var/run/ec20d.sock`；
- 开发环境可用 `EC20D_SOCKET` 覆盖路径；
- framing 为 UTF-8 NDJSON，一行一个完整 JSON 对象，单条消息上限 1 MiB；
- socket 只允许本机访问，生产权限为 `0660`，owner/group 由安装程序设置；
- 服务端使用 `getpeereid(3)` 校验调用者，不开放 TCP 监听；
- IMEI、ICCID、短信正文、APDU 和完整 AT 命令默认不得写入普通日志。

Vohive 的最终 AT 数据面优先直接使用 `/dev/cu.*`。IPC 主要用于设备关联与热插拔；只有实验期
IOUSBHost 后端或未来原始 QMI 控制面才通过 IPC 传输数据。

### 4.2 首版方法

| 方法 | 用途 | 必需条件 |
|---|---|---|
| `system.hello` | 协商版本与服务能力 | 始终必需 |
| `devices.list` | 返回一致性设备快照及 `revision` | 始终必需 |
| `devices.get` | 按 `instance_id` 读取最新状态 | 始终必需 |
| `devices.watch` | 从指定 revision 开始推送事件 | 始终必需 |
| `at.acquire` | RPC 模式下取得 AT 独占租约 | `at.rpc` |
| `at.execute` | 在租约内执行一条 AT 命令 | `at.rpc` |
| `at.release` | 主动释放 AT 租约 | `at.rpc` |
| `qmi.open`/`qmi.request`/`qmi.close` | 传输 QMUX/QMI 消息 | `qmi.rpc`，后续阶段 |

网络 socket 不通过 `ec20d` 转发。Darwin provider 从设备快照取得 `interface_name` 和
`interface_index`，Vohive 在自身 dialer 中完成绑定。

## 5. 设备对象

`devices.list` 返回的设备对象示例：

```json
{
  "schema": "ec20.vohive/1",
  "api_version": "1.0",
  "revision": 42,
  "devices": [
    {
      "instance_id": "usb-03120000-7",
      "generation": 7,
      "stable_id": "imei-860000000000001",
      "identity": {
        "imei": "860000000000001",
        "usb_serial_number": null,
        "usb_location_id": "03120000",
        "vendor_id": 11388,
        "product_id": 293,
        "vendor_id_hex": "2c7c",
        "product_id_hex": "0125",
        "manufacturer": "Quectel",
        "model": "EC20F",
        "firmware": "EC20CEFDGR06A08M4G"
      },
      "lifecycle": {
        "state": "ready",
        "reason": null
      },
      "usb": {
        "configuration": 1,
        "at_interface_number": 2,
        "network_interface_number": 4
      },
      "at": {
        "transport": "serial",
        "path": "/dev/cu.ec20-03120000-at",
        "rpc_device_id": null,
        "interface_number": 2,
        "ownership": "exclusive_client",
        "available": true
      },
      "network": {
        "mode": "ecm",
        "data_plane": "ethernet",
        "control_plane": "at",
        "interface_name": "en7",
        "interface_index": 18,
        "link_state": "up",
        "addresses": ["10.10.10.23/24", "fe80::1234%en7"],
        "managed_by": "apple_cdc_ecm"
      },
      "capabilities": [
        "management.at",
        "sms.at",
        "ussd.at",
        "sim.at",
        "esim.apdu.at",
        "network.ecm",
        "network.connect.at",
        "network.ipv4",
        "proxy.interface_binding"
      ]
    }
  ]
}
```

字段规则：

- `path`、`interface_name` 和 `interface_index` 都是本次枚举的易失值，禁止持久化为设备身份；
- `instance_id` 在一次 attach 生命周期内不变，重新枚举后必须变化；
- `generation` 对同一个物理 attach slot 单调递增，用于拒绝陈旧操作；
- `stable_id` 在读到 IMEI 前允许为 `null`，读到后发布 `device.updated`；
- `network.mode` 初始允许为 `unknown`，确认后只能是 `ecm`、`qmi`、`mbim`、`ncm`、
  `rndis` 或 `none`；
- `addresses` 是观察值，不授权 Vohive 修改系统全局默认路由；
- `network` 不可用时字段仍存在，`interface_name`/`interface_index` 为 `null`，并通过
  capabilities 表达缺失能力。

Vohive 的 `CompatibleModem` 已有 IMEI、USBPath、ATPort、NetInterface、Mode 等映射字段：
[`internal/config/config.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/config/config.go)。
Darwin provider 应把上述对象映射到该结构，但运行时路径仍不得进入持久配置。

## 6. 身份、关联与热插拔

### 6.1 身份层级

设备身份分三层：

1. `instance_id`：由 IORegistry entry、USB location ID 和 attach generation 生成，只表示当前实例；
2. `stable_id`：优先使用经校验的 IMEI，其次才使用真实且唯一的 USB serial number；
3. `usb_location_id`：仅用于把同一次枚举中的串口和网卡关联起来，换 Hub/端口后会改变，不能
   代替 IMEI。

`enX`、`/dev/cu.*`、BSD unit number、IORegistry entry ID 均不得作为长期身份。两个模块报告相同
或无效 IMEI 时必须保留不同 `instance_id`，并把设备状态标为 `degraded`；不得把它们合并。

### 6.2 关联规则

`ec20d` 应从 IORegistry 的父子关系和 USB location ID 关联：

- VID/PID `2c7c:0125` 的 interface 2 对应 AT；
- interface 4 保留给网络，绝不注册或报告为 AT 串口；
- SerialDriverKit 节点和 ECM `enX` 必须回溯到同一个 USB device service；
- 仅在父设备一致时组成一个 device object，不依赖创建顺序或 BSD 名称相邻性。

### 6.3 快照与事件

客户端先调用 `devices.list` 得到快照和 `revision`，再调用
`devices.watch({"after_revision":42})`。服务端按 revision 严格递增发送：

```json
{
  "schema": "ec20.vohive/1",
  "api_version": "1.0",
  "event": "device.updated",
  "revision": 43,
  "device": {
    "instance_id": "usb-03120000-7",
    "generation": 7,
    "lifecycle": {"state": "ready", "reason": null}
  },
  "changed": ["network.interface_name", "network.interface_index"]
}
```

稳定事件名为：

- `device.added`：看到 USB device，状态通常为 `discovered` 或 `initializing`；
- `device.updated`：串口、IMEI、网络接口、地址、能力或状态发生变化；
- `device.removing`：停止接受新操作并撤销租约；
- `device.removed`：设备资源已经释放；
- `at.urc`：仅在 `at.rpc` 模式下向当前租约 owner 推送 URC；
- `daemon.resync`：事件缓存不足，客户端必须重新执行 `devices.list`。

同一次 USB 模式切换可能表现为旧实例 `removed` 后新实例 `added`。provider 可在短暂宽限期内用
IMEI 或 location ID 保持 UI 连续，但所有 I/O 必须使用新 `instance_id` 和 `generation`。不得把旧
file descriptor、AT lease、`enX` 或 socket 复用于新实例。

Vohive 当前 Linux discovery 扫描 `/sys/bus/usb/devices`，watcher 使用 netlink uevent；Darwin
实现应替换这两层，不在 macOS 构造兼容目录：
[`internal/device/discovery_compat.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/device/discovery_compat.go)、
[`internal/device/udev.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/device/udev.go)。

## 7. AT 通道所有权

同一物理 AT interface 在任意时刻只能有一个 raw transport owner。

### 7.1 成品 `serial` 模式

- `EC20Serial.dext` 生成 `/dev/cu.ec20-<instance>-at`；
- Vohive 打开串口后成为唯一命令调度者；
- `ec20d` 只观察 IORegistry，不得为健康检查、读 IMEI或探测模式再次打开该串口；
- Vohive 现有的 manager 必须继续串行化 AT 命令并从命令响应中分离 URC；
- 其他进程打开失败时应得到明确的 busy/EBUSY，而不是共享交错的数据流。

### 7.2 实验 `rpc` 模式

- `ec20d` 独占 IOUSBHost interface 2，设备对象设置 `at.transport="rpc"`；
- Vohive 通过 `at.acquire` 取得租约，不能同时使用 PTY、RPC 和直接 USB；
- `at.execute` 必须携带 `instance_id`、`generation`、`lease_id`、命令、超时和响应上限；
- 默认单命令超时 3 秒、响应上限 64 KiB；长耗时命令必须由 Vohive 显式提高限制；
- 响应以独立 `OK`、`ERROR`、`+CME ERROR:` 或 `+CMS ERROR:` 行结束；
- 未归属于当前 transaction 的行作为 `at.urc` 事件有序转发；
- client 断开、租约超时、USB 拔出或 generation 改变时，服务端立即撤销租约；
- `at.execute` 不得自动重试可能改变状态的命令。

### 7.3 P1 `pty` 兼容模式

- `ec20d --pty` 创建 mode `0600` 的动态 `/dev/ttys*`，设备对象设置
  `at.transport="pty"`、`at.ownership="cooperative_single_client"`；
- Vohive 必须从 `devices.list` 取得路径并显式打开，不能依赖 `GetPortsList`，也不能持久化该路径；
- daemon 启动时记录目标 interface 2 的 IORegistry entry ID，之后每条命令按该 attach 身份重新
  打开；模块拔出后旧 PTY 不得转接到同一物理 USB 端口上的新模块；
- macOS PTY 允许同 UID 进程重复打开，P1 无法提供真实串口的系统级独占。Host App 必须保证只有
  一个 Vohive 实例使用它；多开会产生混帧或响应被错误 reader 消费；
- P1 每条普通命令临时打开、执行并关闭 USB interface 2，没有连续 reader，因此不能承诺实时
  入站 URC 或完整短信/USSD 状态机；`AT+CMGS=<length>` 已有独立的 prompt/PDU/Ctrl-Z 事务，
  Vohive 出站 PDU SMS 已通过实机验收；
- 默认只读 allowlist 仍在 PTY 写入 USB 前生效。`--allow-arbitrary-at` 仅供明确的开发实验，不能
  作为成品应用获得短信、eSIM 或复位权限的授权模型；
- `system.hello` 在此模式发布 `at.pty` 而不发布 `at.rpc`，RPC acquire 必须返回 busy。

PTY 是把 Vohive 现有串口 transport 接到普通用户态 USB 实验的过渡层，不改变成品
`USBSerialDriverKit` 串口需要满足的独占、热插拔和连续读语义。

示例：

```json
{"schema":"ec20.vohive/1","api_version":"1.0","id":"7","method":"at.execute","params":{"instance_id":"usb-03120000-7","generation":7,"lease_id":"A2F7","command":"AT+CSQ","timeout_ms":3000,"max_response_bytes":65536}}
```

DriverKit、`ec20d` 和 Darwin provider 不解释短信或 eSIM 业务，只保证有序、无交错的 AT
transaction。改变 USB mode、复位、固件升级等高风险操作应由 Vohive 的显式用户动作触发；
探测和后台刷新不得发送状态变更命令。

## 8. ECM、QMI 与 capability 模型

### 8.1 Capability 命名

capability 使用小写分段名称，首版包括：

| Capability | 含义 |
|---|---|
| `management.at` | 可通过 AT 读取型号、IMEI、信号和注册状态 |
| `sms.at` / `ussd.at` | AT 短信或 USSD 可用 |
| `sim.at` / `esim.apdu.at` | SIM 管理或 APDU 路径可用 |
| `network.ecm` | 存在标准 ECM Ethernet data plane |
| `network.qmi` | QMI data/control plane 可用 |
| `network.connect.at` | 可用固件已验证的 AT 流程连接/断开 |
| `network.connect.qmi` | 可用 QMI WDS 连接/断开 |
| `network.rotate_ip` | 当前模式已经验证可重拨并获得新会话 |
| `network.ipv4` / `network.ipv6` | 对应地址族已配置 |
| `qmi.rpc` | 可通过本地 IPC 发送原始 QMI 请求 |
| `proxy.interface_binding` | 有可用于 per-interface binding 的 BSD 接口 |

capability 必须反映当前设备和固件的实测状态。例如只有 `enX` 不代表能够主动
connect/disconnect；未验证重拨时不得发布 `network.rotate_ip`。

### 8.2 ECM

ECM 模式的约定为：

- Apple CDC-ECM 驱动创建 `enX`，`network.data_plane="ethernet"`；
- Vohive `ECMNetworkController` 负责 APN/连接状态的 AT 流程及等待地址就绪；
- DHCP、IPv4/IPv6 地址和 DNS 优先交给 macOS 网络栈，Vohive 不清空系统地址或全局路由；
- 信号、注册、短信、SIM/eSIM 使用 AT backend；
- QMI 专属通知缺失时使用 AT URC 或有界轮询，不虚报 QMI capability。

Vohive 的 mode resolver 已能识别 ECM，但当前 discovery 的 `NetworkCapable` 语义偏向 QMI/MBIM。
Darwin 适配应把“存在 data plane”和“存在 QMI/MBIM control plane”拆成不同 capability：
[`internal/device/identity_resolver.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/device/identity_resolver.go)、
[`internal/device/qmi_static_discovery.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/device/qmi_static_discovery.go)。

### 8.3 QMI

需要完整 QMI 时，`ec20d`/DriverKit 接管 interface 4 的 QMUX transport，并通过 `qmi.rpc`
提供版本化请求通道。Vohive 的 QMI backend 通过新 Darwin transport 使用 WDS/DMS/NAS/UIM/WMS，
而不是查找 `/dev/cdc-wdm*`。

要求：

- QMI client ID、transaction ID 和 indication 由单一 QMI session manager 管理；
- QMI request 与异步 indication 分流，拔出时取消全部 pending request；
- raw-ip 与 Ethernet 的封装只在网络 driver/data-plane 层完成；
- IPC 不向非授权进程暴露任意 QMI 写入；
- 同一 device 可同时报告 AT management 和 QMI network capability，但不得有两个 QMI owner。

## 9. macOS socket interface binding

Vohive Linux 版直接使用 `SO_BINDTODEVICE`：
[`internal/proxy/server/server.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/proxy/server/server.go)、
[`internal/netprobe/netprobe.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/netprobe/netprobe.go)。
Darwin provider 必须提供统一的 `netbind` 实现：

- 由 `net.InterfaceByName` 验证 `interface_name` 并取得最新 ifindex；
- IPv4 socket 使用 `IP_BOUND_IF`，IPv6 socket 使用 `IPV6_BOUND_IF`；
- 在 `connect(2)` 或首个 UDP packet 之前绑定；
- 接口不存在、ifindex 与设备 generation 不符或 setsockopt 失败时 **fail closed**，不得回退 Wi-Fi；
- DNS 查询也必须使用同一接口，不能先通过系统默认接口解析后只绑定业务连接；
- IPv6 link-local 地址必须保留 zone/interface index；
- `device.updated` 改变 `enX`/ifindex 或 `device.removed` 时，停止新连接并重建对应 dialer；
- 已建立连接可有界排空，但不得被重新归属到另一个 modem。

`ec20d` 只报告接口映射；代理 HTTP/SOCKS5 connection、网络探测和公网 IP 查询都应在 Vohive
进程中复用同一个 platform binder。这样可以避免三个位置产生不一致的出口选择。

## 10. Vohive Darwin provider 映射

建议新增平台边界：

```go
type HardwareProvider interface {
    Snapshot(ctx context.Context) (revision uint64, devices []CompatibleModem, err error)
    Watch(ctx context.Context, after uint64, onEvent func(DeviceEvent)) error
}

type InterfaceBinder interface {
    Control(network, address, interfaceName string, c syscall.RawConn) error
}
```

并用 Go build tags 分离：

```text
hardware_linux.go       hardware_darwin.go
hotplug_linux.go        hotplug_darwin.go
netbind_linux.go        netbind_darwin.go
```

Darwin provider 的最低职责：

1. 将契约 device object 映射成 `CompatibleModem`；
2. 按 `stable_id`/IMEI 恢复 Vohive 配置，按 `instance_id` 管理运行时 worker；
3. 为 `serial` 和 `rpc` 创建统一 AT transport；
4. 按 capability 选择 `ECMNetworkController` 或 QMI controller；
5. 把 interface name/index 交给统一 binder；
6. 在 removed、generation 变化或 resync 时完整关闭旧 worker 和 fd；
7. UI/API 只显示真实 capability，不把未实现功能显示为成功。

现有 AT backend 可继续承载 IMEI、信号、短信、SIM 和 APDU 等管理功能：
[`internal/backend/at_backend.go`](https://github.com/1239t/vohive/blob/0965af3d3c59bf51ef09ebd7edcafc06f516321f/internal/backend/at_backend.go)。

## 11. 功能矩阵

| Vohive 功能 | 用户态 AT + ECM 原型 | SerialDriverKit + ECM 成品 | QMI 扩展成品 | 说明 |
|---|---:|---:|---:|---|
| 设备发现与热插拔 | 是 | 是 | 是 | IORegistry/ec20d provider |
| IMEI、型号、固件、信号、注册 | 是 | 是 | 是 | AT；QMI 可增强事件 |
| AT 终端 | 是（RPC） | 是（`/dev/cu.*`） | 是 | 单一 owner |
| SMS、USSD、SIM PIN | 是 | 是 | 是 | 优先复用 AT backend |
| eSIM/APDU | 条件支持 | 条件支持 | 条件支持 | 取决于模块/固件与现有 Vohive 流程 |
| ECM 建链和地址观察 | 是 | 是 | 可选 | 必须完成固件实测 |
| HTTP/SOCKS5 代理 | 是 | 是 | 是 | 使用 Darwin binder |
| 多模块出口隔离 | 是 | 是 | 是 | 包含 interface-bound DNS |
| 主动断开/重连 | 条件支持 | 条件支持 | 是 | ECM 需验证 AT 流程 |
| Rotate IP | 条件支持 | 条件支持 | 是 | 未验证前不发布 capability |
| QMI WDS/DMS/NAS/UIM/WMS | 否 | 否 | 是 | 通过 `qmi.rpc`，不模拟 cdc-wdm |
| MBIM 专属功能 | 否 | 否 | 否/后续 | 独立 transport，不属于首版 |
| Linux VoWiFi/IPsec 实现 | 否 | 否 | 否 | 需独立 Darwin 网络扩展，不属于 EC20 驱动契约 |

这里的“条件支持”必须在具体 EC20 固件上验证后才能转为正式 capability，不能用 AT 命令存在
推断功能完整。Vohive 的 Linux 专用 VoWiFi 依赖也必须通过 build tags 隔离；驱动兼容不等于
Linux IPsec 实现可直接移植。

## 12. 验收用例

### A. 契约与升级

1. Darwin provider 能与 `ec20.vohive/1.0` 完成 hello、snapshot、watch；
2. 未知可选字段不影响运行，未知主版本被明确拒绝；
3. 事件缓存断档返回 `resync_required`，重新 snapshot 后不重复创建 worker；
4. 所有失败均返回稳定 error code，不用解析日志文本判断。

### B. 枚举与身份

1. 对实机 `2c7c:0125`，interface 2 映射成唯一 AT transport；
2. interface 4 只映射为 network function，任何情况下都不出现为 AT port；
3. 同一模块的 `/dev/cu.*` 与 `enX` 关联到同一个 device object；
4. 更换 USB 端口导致 location ID、BSD 名称变化后，Vohive 仍通过 IMEI 恢复配置；
5. 两个 EC20 同时连接时拥有不同 `instance_id`、worker 和出口；
6. 无 IMEI、重复 IMEI 和暂时读不到 IMEI 时不误合并设备。

### C. 热插拔与恢复

1. 连续完成至少 20 次插拔，无崩溃、泄漏、僵尸 worker 或陈旧设备；
2. 任意初始化阶段拔出都依次终止 pending AT/network 操作；
3. ECM/QMI 模式切换的 remove/add 产生新 generation，旧 fd 和 lease 不可复用；
4. `enX` 晚于串口出现或先于串口消失时，设备状态能从 initializing/ready/degraded 正确转换；
5. `ec20d` 重启后 daemon instance 改变，Vohive 自动 resync。

### D. AT 所有权与协议

1. `serial` 模式下 `ec20d` 不打开 AT port，Vohive 独占成功；
2. `rpc` 模式下第二个 client 获得 `busy`，不会与第一客户端交错；
3. 并发业务请求经调度后顺序执行，响应与 URC 可正确分离；
4. 超时、64 KiB 上限、`ERROR`/CME/CMS error、拔出都返回可判定错误；
5. client 崩溃后租约自动释放，重连可以恢复；
6. 探测、健康检查和热插拔流程不会发送配置写入、复位或拨号命令。

### E. ECM 数据面

1. 切换到经批准的 ECM 模式后 macOS 产生可关联的 `enX`；
2. 等待 link/address 的过程有超时，不会修改 Wi-Fi 或系统全局默认路由；
3. AT 状态、macOS link 和实际网络探测三者不一致时报告 degraded，而非虚报 connected；
4. 断开、重连和 rotate IP 只有在目标固件实测通过后才公布 capability；
5. IPv4、IPv6及 DNS 状态变化能触发 `device.updated`。

### F. 代理与出口隔离

1. Wi-Fi 和一个 EC20 同时在线时，Vohive proxy 公网 IP 必须属于 EC20；
2. 两个 EC20 同时在线时，各自 proxy 显示各自蜂窝公网出口；
3. TCP、UDP、IPv4、IPv6 和 DNS 均使用目标接口；
4. 目标 `enX` 下线或 binding 失败时请求明确失败，不能从 Wi-Fi 泄漏；
5. 接口重命名/ifindex 改变后旧 dialer 被销毁，新连接使用新映射。

### G. Vohive 用户功能

1. Darwin 构建可以完成设备详情、信号刷新、AT 终端、短信收发、USSD 和 SIM 状态流程；
2. 支持的固件上完成 eSIM/APDU 流程，敏感数据不进入普通日志；
3. ECM controller 能启动/停止 worker 并向现有 proxy/server 提供正确接口；
4. 不可用的 QMI/MBIM/VoWiFi 功能在 API/UI 中明确标为 unsupported；
5. Linux build 和既有 Linux discovery/QMI 行为不因 Darwin build tags 回归。

### H. QMI 扩展

1. 每个 modem 的 QMI client/transaction 隔离，两个模块不会串包；
2. WDS 建链、NAS 注册、DMS 信息、UIM/SMS 所需服务与 indication 正常；
3. 拔出或 daemon 重启时 pending request 全部取消且 client ID 被清理；
4. Raw-IP/Ethernet 转换通过不同包长、IPv4/IPv6、MTU 和压力测试；
5. 未授权进程不能连接 QMI RPC 或发送任意控制消息。

## 13. 完成定义

“兼容 Vohive 完整功能的 macOS 应用”至少需要满足：

- Darwin 原生构建、安装、启动和卸载流程；
- 标准串口或等价 RPC AT transport，且 AT 只有一个 owner；
- ECM 或 QMI data plane，可稳定关联到同一模块；
- 热插拔、多模块、休眠唤醒和模块重枚举可恢复；
- 代理和 DNS fail-closed 地绑定到指定蜂窝接口；
- capability 驱动 UI/API，未支持项不会被伪装为成功；
- 本文 A–G 验收通过；若声明 QMI 完整兼容，还必须通过 H；
- Linux 平台行为不回归，并持续保留跨平台测试。

本契约应随实现迭代，但 `ec20.vohive/1` 发布后必须遵守第 3 节的向后兼容规则。
