# EC20 macOS 第一阶段实验：用户态 AT 探针

这不是 Linux `option.c`/`GobiNet` 的直接移植，也还不是 DriverKit 驱动。它先用 macOS 的
`IOUSBHost.framework` 在普通用户态独占打开 EC20 的 **USB 接口 2**，验证 macOS 到模块的
AT bulk 通道是否真实可用，并只执行不会改变模块状态的查询命令。

当前目标固定为：

- USB VID/PID：`2c7c:0125`
- configuration：`1`
- AT interface：`2`
- 网络 interface：`4`，本程序永远不会匹配或打开它

## 安全边界

第一版使用硬编码 allowlist，只接受：

- `AT`
- `ATI`
- `AT+GMR`
- `AT+QCFG="usbnet"`

因此 `AT+QCFG="usbnet",1`、`AT+CFUN=1,1`、复位、拨号、短信及任意自定义命令都会在
USB 写入前被拒绝。程序不使用 USB device capture/seize；如果接口已经有 owner，它会退出，
不会强制抢占。

## 使用 data 硬盘上的 Xcode 构建

```sh
export DEVELOPER_DIR=/Volumes/data/Applications/Xcode-26.5.0.app/Contents/Developer
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

cmake --fresh -S . -B build -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_OSX_SYSROOT="$MACOS_SDK"
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

显式给出 sysroot 是必要的：CMake 直接调用 `/usr/bin/clang` 时，仅设置 `DEVELOPER_DIR` 仍可能
捡到 `/Library/Developer/CommandLineTools` 的 SDK。上述方式无需修改全局 `xcode-select`。

## 运行

先只查看接口和 endpoint：

```sh
./build/ec20-at-probe --list
```

`--list` 为读取 endpoint 描述符会短暂取得 interface 2 的独占权并立即释放；如果它已经有
owner，命令会返回失败，不会 seize。

执行完整的只读实验（两次 `AT`，然后读取型号、固件和当前 `usbnet` 值）：

```sh
./build/ec20-at-probe --experiment
```

也可以只执行一条 allowlist 内的查询：

```sh
./build/ec20-at-probe --command 'AT+QCFG="usbnet"'
```

每条命令发送前先读取到 150 ms 的静默边界，陈旧数据以 `STALE` 标记；随后同时打印响应的
原始十六进制数据和解码文本。成功必须收到独立的 `OK` 行；`ERROR`、`+CME ERROR:`、
`+CMS ERROR:` 会判为模块错误，三秒内没有终止行或单条响应超过 64 KiB 则终止。

## 这一阶段的判定

- 两次 `AT` 都返回 `OK`：接口 2 的用户态 USB AT 链路成立。
- `ATI`/`AT+GMR` 返回有效信息：命令与多段 bulk 响应组装成立。
- `AT+QCFG="usbnet"` 返回值：据此决定下一步是否做 ECM 切换实验。
- 如果打开失败：先检查 macOS USB accessory 授权或是否出现了 interface owner；不要改成 seize。

即使查到支持 ECM，本阶段也不会切换配置或重启模块。切换需要单独确认，并预先准备掉线后的
恢复通道。
