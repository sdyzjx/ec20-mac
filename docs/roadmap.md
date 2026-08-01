# EC20 macOS × Vohive 产品路线图

更新日期：2026-08-01

## 1. 产品目标与边界

目标是交付一个原生 macOS 应用，使 Quectel EC20 在 macOS 上完成设备管理、蜂窝联网，
并运行 Vohive 可适用于该模块和固件的完整功能。实现不复制 Linux 内核驱动，也不在 macOS
上伪造 `/sys`、udev、`ttyUSB*` 或 `/dev/cdc-wdm*`；驱动层输出标准 macOS 串口和网卡，
Vohive 通过 Darwin 平台后端使用它们。

“兼容 Vohive 完整功能”按功能矩阵验收，而不是承诺所有 EC20 固件都具备同一能力：

- AT 管理：身份、信号、运营商、SIM、短信、USSD、AT 终端和设备重启；
- 数据连接：APN、IPv4/IPv6、DNS、断开/重连、出口验证和换 IP；
- Vohive 服务：设备池、热插拔、HTTP/SOCKS5 代理和按蜂窝接口绑定出口；
- 高级能力：eSIM/APDU、QMI WDS/DMS/NAS/UIM/WMS 及 Vohive 暴露的其他能力；
- 多模块、睡眠唤醒、拔插恢复、安装升级和卸载。

硬件、SIM、运营商或固件不支持的功能必须在能力矩阵和 UI 中明确显示为“不支持”，不能静默
回退到 Wi-Fi 或报告伪成功。完整 QMI 功能是 P5 目标；P2–P4 的 ECM 版本是可独立使用、可回退
的正式中间产物。

建议的最终组件边界：

| 组件 | 职责 | 不负责 |
|---|---|---|
| macOS Host App | 安装系统扩展、配置、状态、诊断、升级和卸载 | USB/QMI 数据面 |
| `EC20Serial.dext` | 将 EC20 AT 接口发布为标准 `/dev/cu.*` | AT 业务、短信解析、网络路由 |
| `ec20d` | 用户态设备发现、身份映射、事件、受控操作；实验期还提供 AT 桥 | Vohive UI 和长期业务状态 |
| Vohive Darwin 后端 | AT/SMS/eSIM、设备池、代理、ECM/QMI 控制和能力呈现 | 直接依赖 Linux sysfs/udev |
| QMI/Network DriverKit 组件 | P5 的 interface 4、QMI 和标准 `enX` 数据面 | Vohive 业务逻辑 |

设备关联使用 USB `locationID`/IORegistry 路径作为本次插入身份，IMEI 作为长期身份。`enX`、
`/dev/cu.*` 和伪终端名称均可能在重枚举后变化，不能单独作为数据库主键。

## 2. 全局工程与 Git 规则

1. `main` 始终保持可构建、可测试；每个阶段使用 `feature/pN-*` 分支，经阶段验收后合并。
2. 提交保持原子性：协议/接口、实现、测试、文档可以审阅和回退；不要把多个阶段压成一个提交。
3. 每个对外行为变化必须同步更新文档；修复缺陷必须先补回归测试或在提交说明中解释为何无法自动化。
4. 建议使用 Conventional Commits，例如：
   - `feat(ec20d): add versioned unix socket protocol`
   - `test(ecm): verify bound cellular egress`
   - `docs(p2): record ecm recovery procedure`
5. 在发送会改变模块持久配置的 AT 命令前，先提交当前代码和恢复文档，记录设备、固件、原值和
   恢复入口；实验结果另作提交，避免与实现混在一起。
6. 每个阶段通过后创建带注释标签 `p0-baseline`、`p1-bridge`……；正式发布使用语义化版本标签。
7. 不提交签名证书、私钥、provisioning profile、Apple 账号信息、SIM/APN 密码、IMEI 全值、
   短信内容或实机日志中的个人数据。构建产物和 DerivedData 不进入 Git。
8. 外部 Vohive 代码使用固定上游提交和独立分支/仓库管理，保留来源及许可证通知；对上游的
   Darwin 改动尽量保持平台隔离，便于持续 rebase 和审计。

每个阶段统一维护以下证据：构建命令、自动测试结果、实机记录、已知限制、恢复步骤、功能矩阵
变化以及对应提交/标签。

## 3. P0：冻结安全基线

### 目标与交付物

- 固化现有 `IOUSBHost` 只读 AT 探针和安全 allowlist；
- 记录 Xcode/SDK、macOS、USB VID/PID、configuration、interface/endpoint、模块型号、固件和
  `usbnet` 当前值；
- 增加可重复的 Debug 构建、单元测试和实机测试说明；
- 固定首个 Vohive 上游提交，建立“上游功能—macOS 状态—测试用例”矩阵；
- 写明敏感信息脱敏规则、日志级别和硬件配置变更审批边界。

当前已知基线为 EC20F、`2c7c:0125`、interface 2 AT bulk 通道和 `usbnet=0`；P0 不发送配置、
复位、拨号或短信命令，也不打开 interface 4。

### 验收

- 使用 data 硬盘上的 Xcode 从干净工作区构建并通过全部测试；
- `--list` 能验证 interface 2 的 bulk IN/OUT，`AT`、`ATI`、`AT+GMR` 和
  `AT+QCFG="usbnet"` 得到预期终止行；
- 非 allowlist 命令在打开 USB 前被拒绝；进程退出后 interface 2 可再次打开；
- README、实机记录和功能矩阵可由另一位开发者复现实验。

### 风险与回退

- 风险：USB 权限、接口已有 owner、描述符/固件差异导致错误匹配。
- 控制：严格匹配 VID/PID、configuration 和 interface，不 capture/seize，不用模糊 endpoint。
- 回退：P0 不改变设备状态；结束进程并重新插拔即可恢复。

### Git 与门槛

- 建议拆成 `chore: establish build baseline`、`test: cover command allowlist`、
  `docs: record p0 hardware baseline`，验收后标记 `p0-baseline`。
- 无 Apple DriverKit entitlement 门槛；需要在 P0 完成 Vohive PolyForm Noncommercial 许可证
  初审。若产品计划商业销售，必须把取得 Vohive 商业授权列为发布阻塞项。

## 4. P1：`ec20d`、Unix Socket 与 PTY 实验桥

### 目标与交付物

- 将探针中的设备匹配、endpoint 发现和 USB 收发提取为可测试库；
- 实现长期运行的 `ec20d`，支持拔插重连、请求超时、响应上限、日志脱敏和优雅退出；
- 定义带版本号和消息长度限制的本地 Unix Socket 协议，至少包含：
  `ListDevices`、`OpenSession`、`ExecuteAT`、`SubscribeURC`、`CloseSession` 和设备事件；
- AT 调度器保证同一模块命令串行、响应与 URC 可区分，不允许多个客户端交错写 USB；
- 提供可选 PTY 适配器，让 Vohive 的 `go.bug.st/serial` 在 DriverKit 完成前打开临时
  `/dev/ttys*`；Unix Socket 是正式控制协议，PTY 仅是兼容实验层；
- 只允许当前登录用户或明确授权的本地进程访问 socket，默认仍保留只读命令策略；
- 编写协议、状态机、错误码、并发模型、PTY 限制和故障排查文档。

### 验收

- 连续执行至少 1,000 次无副作用 `AT` 请求，无串包、死锁、内存无界增长或未归属响应；
- Vohive 派生的最小 Go 串口测试可以通过 PTY 查询型号、IMEI 和信号；
- 插拔、客户端崩溃、daemon 重启、超时和半包均能恢复，下一客户端可重新取得会话；
- 两个客户端并发时只有一个受控 AT 执行队列，URC 订阅者均收到有序事件；
- 停止 `ec20d` 后接口被释放，P0 探针仍能重新打开设备。

### 风险与回退

- 风险：PTY 的 termios 语义与真实串口不同；AT echo、URC 和响应边界混淆；daemon 独占接口
  后其他工具无法访问；本地 socket 被未授权进程滥用。
- 控制：协议包含 request ID、超时和大小限制；状态机保留原始帧测试；权限使用最小化原则；
  任意持久配置命令继续要求显式能力和确认。
- 回退：停止 daemon、删除其运行时 socket/PTY 链接并使用 P0 探针；不修改模块 USB 模式。

### Git 与门槛

- 推荐顺序：USB 库重构 → 协议定义/测试 → daemon → URC/并发 → PTY → 文档；每项独立提交，
  通过后标记 `p1-bridge`。
- 普通 `IOUSBHost` 用户态实验不要求 DriverKit entitlement；若后续使用登录项、XPC 或特权 helper，
  必须另做签名、授权和攻击面审计，不能为了方便默认以 root 运行。

## 5. P2：受控 ECM 数据连接

### 前置门槛

- 准备独立 UART、Linux/Windows 或另一条已验证 AT 恢复通道；
- 记录 `usbnet` 原值、固件、USB 描述符和恢复命令；确认断网/重枚举不会影响开发机恢复；
- 状态修改工具必须显示将发送的命令、目标设备和原值，并要求人工明确确认。

### 目标与交付物

- 实现独立的“检查—切换—重启—重新发现—验证—恢复”实验流程，将 EC20 从 `usbnet=0`
  受控切换到 ECM；
- 验证 macOS 内置 CDC-ECM 驱动是否生成 `enX`，并通过 IORegistry 把它与同一模块、AT 口关联；
- 验证 APN/数据激活方式、DHCP、IPv4/IPv6、DNS、MTU 和链路状态；具体 AT 激活命令以该固件
  实测和官方文档为准，不在验证前硬编码猜测；
- 实现 Darwin socket 出口绑定原型：IPv4 使用接口索引绑定，IPv6 分开处理；
- 提供恢复 `usbnet=0`、无 `enX`、AT 口改变、模块循环重枚举和 DHCP 失败的操作手册；
- 保存切换前后脱敏的 USB、IORegistry、网络配置和公网出口测试证据。

### 验收

- ECM 模式重启后出现可工作的 `enX`，AT 管理通道仍可发现；若接口编号变化，发现器不依赖旧编号；
- 通过绑定 socket 从 EC20 取得公网出口，IPv4/IPv6 和 DNS 测试结果均有记录；
- Wi-Fi/以太网的系统默认路由不被永久修改，绑定失败时连接必须失败，不能走其他接口；
- 至少完成 20 次断开/重连及 10 次拔插/重启，地址和设备映射能恢复；
- 按文档可恢复到 `usbnet=0`，P1 AT 功能仍正常。

如果固件未暴露标准 ECM 描述符或 macOS 内置驱动不匹配，P2 允许以“ECM 不可行”结项，但必须
保留描述符证据并直接将网络数据面升级为 P5 设计，不能靠修改全局路由伪造通过。

### 风险与回退

- 风险：模块重枚举后 AT 接口变化或消失；持久配置导致开发机无法恢复；ECM 自动拨号行为因
  固件/运营商不同；DNS 从 Wi-Fi 泄漏；错误路由影响整机网络。
- 控制：外部恢复通道是硬门槛；配置变更前创建 Git checkpoint；所有网络测试使用明确接口，
  测试前后保存并比较系统路由/DNS状态。
- 回退：通过外部 AT 通道恢复原 `usbnet=0` 并重启；应用保持 P1 bridge 模式可用。

### Git 与门槛

- 将确认 UI/CLI、设备重发现、网络探测、Darwin bind、实验记录和恢复文档分别提交；实机结果
  不与实现代码混合；通过后标记 `p2-ecm`。
- 使用 Apple 内置 ECM 时通常无需自有 NetworkingDriverKit entitlement；但不能假设所有目标
  macOS/固件组合都相同，支持范围须由实机矩阵决定。

## 6. P3：Vohive Darwin MVP

### 目标与交付物

- 固定 Vohive 上游基线并建立可持续同步策略，保留 Linux 行为不变；
- 用 Go build tags 和小型接口隔离平台代码：
  - Darwin 设备发现/热插拔使用 `ec20d` 或 IOKit，不扫描 sysfs/udev；
  - Darwin 网络控制器使用 ECM 和 macOS 网络状态，不调用 Linux netlink；
  - `netbind` 在 Linux 保留 `SO_BINDTODEVICE`，Darwin 实现 IPv4/IPv6 接口索引绑定；
  - Linux-only QMI/MBIM/VoWiFi 依赖先以能力检查隔离，不用空成功桩绕过错误；
- 增加 ECM `NetworkController`，覆盖连接、断开、状态、地址、出口检测和经验证的换 IP 行为；
- 增加能力模型，区分“有网络接口”“可由 QMI 管理”“硬件/固件不支持”和“Darwin 尚未实现”；
- 完成 arm64 原生构建、自动测试和一个开发版 macOS app/CLI 启动入口；
- 编写 Darwin 构建、上游同步、平台抽象、功能差异和排障文档。

### MVP 验收

- macOS 可构建并运行 Vohive 后端，Linux CI/已有测试不回归；
- 自动发现一台 EC20，正确关联 IMEI、AT 通道和 `enX`，拔插后数据库身份不重复；
- AT 状态、短信收发、USSD、SIM 状态和 AT 终端通过实机测试；
- ECM 可连接、断开并恢复，HTTP/SOCKS5 代理的公网 IP 与该 EC20 出口一致；
- 关闭蜂窝或故意给出不存在接口时代理明确失败，证明没有 Wi-Fi/DNS 泄漏；
- UI/API 对 P5 才实现的 QMI 功能明确标为暂不可用，不能崩溃或伪成功。

### 风险与回退

- 风险：Vohive Linux 假设散布、`swu-go` 等依赖无法 Darwin 编译、DNS 不随 socket 绑定、上游
  快速变化和多模块竞态。
- 控制：平台依赖集中在窄接口；对 Linux-only 依赖使用 build tags 或可替换适配器；添加双平台 CI、
  接口绑定集成测试和固定上游 SHA。
- 回退：Darwin 功能保持独立 feature flag；P3 失败不影响 Linux 上游或 P1/P2 工具，ECM 可由
  独立诊断程序继续使用。

### Git 与门槛

- Vohive 平台接口、Darwin 编译修复、发现器、ECM controller、netbind、功能 UI 和文档分别提交；
  每次上游同步单独提交，不混入功能修改；通过后标记 `p3-vohive-darwin-mvp`。
- P3 仍可使用普通用户态桥，不以取得 DriverKit entitlement 为前提。
- Vohive 当前 PolyForm Noncommercial 约束必须保留通知；公开/分发 fork 前做依赖许可证清单，商业
  使用在取得作者书面商业许可前不得进入 P6。

## 7. P4：SerialDriverKit 原生串口与安装应用

### 前置门槛

- 加入 Apple Developer Program，确定 Team、稳定 bundle ID 和签名责任人；
- 向 Apple 申请并获批项目实际需要的 DriverKit、USB transport、Serial family entitlement，
  以 Apple Developer Portal 当前给出的 entitlement 名称和 provisioning profile 为准；
- 先用最小样例验证该 Team 可以签名、嵌入、激活和停用 dext，再投入完整实现。

### 目标与交付物

- 创建签名的 Host App 和 `EC20Serial.dext`，只匹配 `2c7c:0125` 的 AT interface；绝不把
  interface 4 注册为串口或匹配整个复合 USB 设备；
- 将 AT 接口发布为标准、可辨识的 `/dev/cu.*`，在 IORegistry 暴露角色、VID/PID、interface、
  location 和可用于设备关联的非敏感属性；
- Host App 完成安装/激活状态、用户批准指引、设备列表、日志导出、诊断、停用和卸载；
- Vohive Darwin 后端优先使用真实串口；`ec20d` 退回设备关联/受控操作角色，P1 PTY 保留为
  开发及紧急回退路径；
- 完成代码签名、Hardened Runtime、最小权限、系统扩展生命周期和崩溃恢复文档。

### 验收

- 在一台未安装开发工具的测试 Mac 上完成用户可理解的安装与系统扩展批准流程；
- 插入 EC20 后出现标准 `/dev/cu.*`，Vohive 可完成 P3 全部 AT 功能；interface 4/ECM 不受影响；
- 100 次安装后拔插、50 次睡眠唤醒、daemon/app 异常退出和系统重启后均可恢复；
- 多模块同时连接时端口与 `enX` 不串设备；占用冲突向用户返回清晰错误；
- 停用/卸载后 dext 和辅助服务不再运行，设备可由 P1 工具重新打开，用户数据按说明保留或删除。

### 风险与回退

- 风险：Apple 不批准 entitlement；USB matching 过宽抢占网络接口；系统扩展升级/卸载卡住；串口
  名称变化；睡眠/拔插时并发 I/O 引发挂起。
- 控制：entitlement 是阶段开始前的 go/no-go；按 interface descriptor 和号码双重限定；所有 I/O
  可取消；建立系统扩展状态机和真实升级测试，不要求用户关闭 SIP 作为产品方案。
- 回退：Host App 提供停用/卸载；保留签名的上一版本和 P1 bridge。若 entitlement 未获批，继续
  发布 P3 实验版，不声称拥有标准串口驱动。

### Git 与门槛

- Xcode 工程骨架、matching、串口 I/O、生命周期、Host App、签名配置模板、测试和文档分别提交；
  provisioning profile 与证书不提交；通过后标记 `p4-serial-driverkit`。
- 外部分发还需要 Developer ID、正确的 DriverKit provisioning、签名和 notarization；Mac App Store
  与站外分发策略应在本阶段确定，不能留到最后才验证 entitlement 是否适用于分发渠道。

## 8. P5：完整 QMI 与 NetworkingDriverKit 数据面

### 前置架构门槛

- 先确认 Apple 是否向该 Team/产品批准 USBDriverKit 与 NetworkingDriverKit 所需 entitlement；
  未获批时停止本路径，保留 P2 ECM 产品，而不是实现不可分发的驱动；
- 冻结 Quectel interface 4 描述符、QMI/Raw-IP 行为、固件范围和 Vohive QMI 功能矩阵；
- 对协议资料和可复用代码做 clean-room/许可证审计：不得复制 Linux `GobiNet`、`qmi_wwan` 或其他
  不兼容许可证代码到闭源/不同许可产品。

### 目标与交付物

- 使用 USBDriverKit 安全接管 interface 4，实现传输队列、取消、拔插、流控和错误恢复；
- 实现或复用经审计的 QMUX/QMI transport，并为 Vohive/`quectel-qmi-go` 提供 Darwin transport，
  不伪造 `/dev/cdc-wdm*`；
- 按 Vohive 功能矩阵实现并测试 QMI CTL、DMS、NAS、WDS、UIM、WMS 等所需服务、client ID 生命周期、
  indication 分发、超时和 modem reset；
- 使用 NetworkingDriverKit 发布标准 `enX`，处理 Raw-IP 与 macOS 所需链路帧表示之间的转换、MTU、
  IPv4/IPv6、校验和、背压、统计、DNS 和路由；
- 实现多 modem、多 PDP context、断线恢复、换 IP、QMI SMS/SIM/eSIM 能力以及 ECM/QMI 模式迁移；
- `ec20d`/Host App 通过带版本的 XPC 或 Unix Socket 暴露控制面，驱动内不放入 Vohive 业务逻辑。

### 完整功能验收

- Vohive 功能矩阵中所有“硬件/固件支持”的条目均有自动或实机测试证据；
- WDS 建链/断链、NAS 注册与信号、DMS 身份、UIM SIM、WMS 短信及 indication 在长时间运行中稳定；
- IPv4/IPv6、DNS、MTU、大包、小包、吞吐、丢包、断网、基站切换、SIM 异常和 modem reset 通过测试；
- 代理流量严格绑定对应 EC20，多模块并发无串流、无 Wi-Fi 回退、无 DNS 泄漏；
- 至少 24 小时压力测试、100 次拔插、100 次连接轮换、睡眠唤醒和系统重启无不可恢复状态；
- ECM 与 QMI 可按文档迁移和回退，升级失败不会使模块永久不可访问。

### 风险与回退

- 风险：QMI 文档/固件差异、Raw-IP 与 Ethernet 模型不匹配、DriverKit API/entitlement 限制、网络
  性能和功耗、睡眠竞态、错误帧导致服务失步，以及 clean-room/许可证风险。
- 控制：先做 entitlement 和最小网络 dext spike；协议解析使用 fuzz/边界测试；transport、QMI、网络
  适配和 Vohive 业务严格分层；P5 默认实验开关，不替换已验证的 ECM 路径。
- 回退：Host App 可选择 ECM，停用 QMI dext 并恢复 `usbnet=1`；若无可恢复 AT 通道则禁止自动
  切换模式。任何 QMI 失败不得破坏 P4 串口路径。

### Git 与门槛

- 按 transport → QMUX → 单个 QMI service → indication → 网络帧 → IPv4 → IPv6 → 多模块 →
  集成的顺序提交；每个协议服务与测试同批审阅，避免一个“完整 QMI”巨型提交；通过后标记
  `p5-qmi-feature-complete`。
- 必须取得 DriverKit/USB/Networking entitlement、完成第三方许可证和协议来源审计，并确认 Vohive
  商业授权状态；任一未通过都阻止进入商业发布，但不阻止在许可范围内继续非商业研究。

## 9. P6：签名、发布、维护和完整 macOS 应用

### 目标与交付物

- 统一 Host App、dext、`ec20d` 和 Vohive Darwin 后端的版本、协议协商和升级顺序；
- 完成首次安装、系统扩展批准、模块设置、SIM/APN、连接状态、代理管理、诊断和安全卸载 UX；
- 建立 arm64 和计划支持架构/系统版本的 Release 构建、代码签名、notarization、stapling、SBOM、
  第三方通知、隐私说明、崩溃/日志脱敏和更新签名；
- 编写用户手册、管理员部署、支持矩阵、恢复/降级、已知限制、许可证和安全响应流程；
- 建立上游 Vohive/Apple SDK/Quectel 固件跟踪和回归测试节奏。

### 发布验收

- 在至少两台干净、非开发环境 Mac 上通过 Gatekeeper 安装，系统扩展批准、首次连接、更新、降级和
  完整卸载均可重复；
- 包内所有可执行文件、dext 和 helper 签名链正确，notarization 成功，发布产物可由清单复核；
- P3/P4/P5 对应的功能矩阵、长稳和安全测试全部通过；声明支持的 macOS、EC20 固件、SIM/运营商
  组合与实测一致；
- 无 root 常驻进程；必须提权的动作逐次说明原因并最小授权；卸载不遗留运行服务或失效网络配置；
- 从上一稳定版本升级失败时可自动或按文档恢复，不刷写固件、不删除用户数据。

### 风险与回退

- 风险：notarization/entitlement 在分发 profile 下与开发环境不同；系统扩展升级不兼容；许可证阻止
  商业分发；自动更新破坏多组件协议；隐私日志包含 IMEI、号码或短信。
- 控制：尽早用 Release/Developer ID profile 做端到端 dry run；协议向后兼容至少一个稳定版本；
  发布门禁自动检查签名、SBOM、许可证、敏感日志和恢复路径。
- 回退：保留上一个 notarized 版本和匹配的卸载器；按组件依赖顺序降级。若商业许可或 entitlement
  未完成，只能发布明确标注的非商业源码/开发实验版，不能把开发签名产物当正式应用分发。

### Git 与发布门槛

- 使用 `release/vX.Y.Z` 分支只接收发布修复、版本、变更日志和发布文档；CI 从带注释且受保护的
  `vX.Y.Z` 标签生成可追溯产物，产物哈希、notarization 结果和 SBOM随发布保存。
- 正式发布的硬门槛：Apple 所需 entitlement 和分发签名有效、notarization 通过、Vohive 商业授权
  与全部第三方许可证允许目标用途、安全/隐私审查通过、支持和回退流程已有责任人。

## 10. 阶段决策点

| 决策点 | 继续条件 | 不满足时 |
|---|---|---|
| P0 → P1 | AT bulk 链路稳定且无状态副作用 | 修正 USB 匹配/传输，不进入 daemon |
| P1 → P2 | daemon/PTY 可恢复，已有外部 AT 恢复通道 | 保持只读桥，不切换 USB 模式 |
| P2 → P3 | ECM 可用，或已明确记录 ECM 不可用并选择 P5 | ECM 可用则做 MVP；不可用则先做 QMI entitlement spike |
| P3 → P4 | Vohive Darwin MVP 证明产品价值 | 继续用户态实验版，不投入 dext |
| P4 → P5 | QMI 功能确有需求且 NetworkingDriverKit entitlement 可获得 | 将 ECM 版作为产品终点 |
| P5 → P6 | 完整功能矩阵、稳定性、安全和回退均通过 | 保留 P5 实验开关，发布 ECM 稳定版 |
| P6 发布 | Apple、许可证、签名、公证和隐私门槛全部满足 | 仅限许可范围内的开发/非商业测试 |

实施时优先保持每个阶段都有可运行、可卸载、可回退的产物。P5 是实现 Vohive QMI 功能对等的
长期工程，但不应阻止 P3/P4 的 AT + ECM 版本先形成可用的 macOS 应用。
