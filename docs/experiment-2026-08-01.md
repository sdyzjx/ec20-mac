# EC20 macOS 用户态 AT 探针：首轮实机结果

日期：2026-08-01（Asia/Taipei）

## 环境

- Xcode：`/Volumes/data/Applications/Xcode-26.5.0.app`
- Xcode 版本：26.5 (`17F42`)
- 编译 SDK：`MacOSX26.5.sdk`
- USB 设备：`2c7c:0125`
- location ID：`0x03120000`
- 探测范围：configuration 1、interface 2；未打开 interface 4

## 描述符验证

interface 2 为 alt 0、class `ff/00/00`，动态枚举得到：

| Endpoint | 类型 | 方向 | Max packet | 用途 |
|---|---|---|---:|---|
| `0x85` | interrupt | IN | 10 | 状态通知，本实验忽略 |
| `0x84` | bulk | IN | 512 | AT 回复与 URC |
| `0x03` | bulk | OUT | 512 | AT 命令 |

程序要求恰好一个 bulk IN 和一个 bulk OUT，否则拒绝发送。

## 只读命令结果

1. 第一次 `AT` 返回启动 URC：`+CPIN: READY`、`+QUSIM: 1`、`+QIND: SMS DONE`、
   `+QIND: PB DONE`，随后返回独立 `OK`。
2. 第二次 `AT` 返回独立 `OK`。
3. `ATI` 返回：
   - 厂商：Quectel
   - 型号：`EC20F`
   - Revision：`EC20CEFDGR06A08M4G`
4. `AT+GMR` 返回：`EC20CEFDGR06A08M4G`。
5. `AT+QCFG="usbnet"` 返回：`+QCFG: "usbnet",0`，随后返回 `OK`。

进程退出码为 `0`。实验后再次打开 interface 2 并枚举端点成功，证明本次用户态独占已正确释放。
加入命令前静默排空、描述符断言和 64 KiB 响应上限后，完整实验再次运行，结果相同且退出码仍为 `0`。

## 安全性复核

- 没有发送 `AT+QCFG="usbnet",1` 或其他配置写入。
- 没有复位、重启或重新枚举模块。
- 没有使用 USB capture/seize。
- 没有打开网络用的 interface 4。
- 对写配置命令 `AT+QCFG="usbnet",1` 的负向测试在 USB 打开前被拒绝，退出码为 `8`。

## 结论

macOS 通过 `IOUSBHost.framework` 直接访问 EC20 interface 2 的方案成立；AT 命令的 bulk
收发、多 transfer 拼接、URC 容忍和终止行判断均已在实机验证。当前 `usbnet=0`，尚未切到
ECM。下一步可以把“切换到 ECM、重启、验证 macOS 是否出现 `enX`”做成一个独立、需明确确认且
带恢复方案的实验，不应放进默认探针。
