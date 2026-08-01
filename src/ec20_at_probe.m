#import <Foundation/Foundation.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>
#import <IOUSBHost/IOUSBHost.h>

#import "EC20USBATTransport.h"

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef NS_ENUM(int, ExitCode) {
    ExitOK = 0,
    ExitUsage = 1,
    ExitDeviceSelection = 2,
    ExitInterfaceOpen = 3,
    ExitEndpointLayout = 4,
    ExitUSBWrite = 5,
    ExitUSBRead = 6,
    ExitModemError = 7,
    ExitUnsafeCommand = 8,
    ExitSelfTest = 9,
};

static void PrintUsage(const char *program)
{
    fprintf(stderr,
            "用法:\n"
            "  %s --list\n"
            "  %s --experiment [--registry-id ID | --location-id ID]\n"
            "  %s --command 'AT+QCFG=\"usbnet\"' "
            "[--registry-id ID | --location-id ID]\n"
            "  %s --recover-interactive [--registry-id ID | --location-id ID]\n"
            "  %s --self-test\n\n"
            "ID 可使用十进制或 0x 前缀十六进制。\n"
            "第一版仅允许: AT, ATI, AT+GMR, AT+QCFG=\"usbnet\"。\n"
            "它只接管 2c7c:0125 的 USB 接口 2，绝不打开接口 4。\n",
            program, program, program, program, program);
}

static const char *CString(NSString *string)
{
    const char *value = string.UTF8String;
    return value != NULL ? value : "<无法编码>";
}

static void PrintNSError(const char *context, NSError *error)
{
    if (error == nil) {
        fprintf(stderr, "%s: 未提供详细错误\n", context);
        return;
    }

    fprintf(stderr, "%s: %s (domain=%s, code=%lld / 0x%08x)\n",
            context,
            CString(error.localizedDescription),
            CString(error.domain),
            (long long)error.code,
            (uint32_t)error.code);

    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying != nil) {
        fprintf(stderr, "  underlying: %s (domain=%s, code=%lld / 0x%08x)\n",
                CString(underlying.localizedDescription),
                CString(underlying.domain),
                (long long)underlying.code,
                (uint32_t)underlying.code);
    }
}

static NSSet<NSString *> *AllowedCommands(void)
{
    static NSSet<NSString *> *commands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        commands = [NSSet setWithArray:@[
            @"AT",
            @"ATI",
            @"AT+GMR",
            @"AT+QCFG=\"usbnet\"",
        ]];
    });
    return commands;
}

static BOOL IsAllowedCommand(NSString *command)
{
    if (command == nil || ![AllowedCommands() containsObject:command]) {
        return NO;
    }

    NSData *bytes = [command dataUsingEncoding:NSASCIIStringEncoding];
    if (bytes == nil || bytes.length != command.length) {
        return NO;
    }

    const uint8_t *raw = bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
        if (raw[index] < 0x20 || raw[index] == 0x7f) {
            return NO;
        }
    }
    return YES;
}

static void PrintChunk(const char *label, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    fprintf(stdout, "    %-5s %4lu bytes  ", label, (unsigned long)data.length);
    for (NSUInteger index = 0; index < data.length; index++) {
        fprintf(stdout, "%02x ", bytes[index]);
    }
    fprintf(stdout, " | ");
    for (NSUInteger index = 0; index < data.length; index++) {
        fputc(isprint(bytes[index]) ? bytes[index] : '.', stdout);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

static void PrintDeviceIdentity(EC20USBATDevice *device, NSUInteger ordinal)
{
    fprintf(stdout,
            "设备 %lu: registry-id=0x%llx, location-id=0x%08x\n"
            "  path: %s\n",
            (unsigned long)ordinal,
            (unsigned long long)device.registryID,
            device.locationID,
            device.registryPath.length != 0 ? CString(device.registryPath) : "<未知>");
}

static const char *EndpointTypeName(uint8_t type)
{
    switch (type) {
        case kIOUSBEndpointTypeBulk:
            return "bulk";
        case kIOUSBEndpointTypeInterrupt:
            return "interrupt";
        case kIOUSBEndpointTypeIsochronous:
            return "isochronous";
        default:
            return "control";
    }
}

static void PrintEndpointLayout(EC20USBATDevice *device)
{
    fprintf(stdout,
            "  interface=%u alt=%u class=%02x/%02x/%02x endpoints=%lu\n",
            device.interfaceNumber,
            device.alternateSetting,
            device.interfaceClass,
            device.interfaceSubClass,
            device.interfaceProtocol,
            (unsigned long)device.endpoints.count);

    for (EC20USBEndpointInfo *endpoint in device.endpoints) {
        const char *directionName =
            endpoint.direction == kIOUSBEndpointDirectionIn ? "IN" : "OUT";
        fprintf(stdout,
                "    endpoint=0x%02x type=%s direction=%s max-packet=%u\n",
                endpoint.address,
                EndpointTypeName(endpoint.type),
                directionName,
                endpoint.maxPacketSize);
    }
}

static int ExitCodeForTransportError(NSError *error)
{
    if (![error.domain isEqualToString:EC20USBATTransportErrorDomain]) {
        return ExitUSBRead;
    }

    switch ((EC20USBATTransportErrorCode)error.code) {
        case EC20USBATTransportErrorEnumeration:
        case EC20USBATTransportErrorDeviceSelection:
            return ExitDeviceSelection;
        case EC20USBATTransportErrorInterfaceOpen:
            return ExitInterfaceOpen;
        case EC20USBATTransportErrorEndpointLayout:
            return ExitEndpointLayout;
        case EC20USBATTransportErrorUSBWrite:
            return ExitUSBWrite;
        case EC20USBATTransportErrorUSBRead:
            return ExitUSBRead;
        case EC20USBATTransportErrorModem:
            return ExitModemError;
        case EC20USBATTransportErrorInvalidCommand:
            return ExitUnsafeCommand;
    }
}

static BOOL ParseUnsignedID(const char *text, uint64_t maximum, uint64_t *value)
{
    if (text == NULL || text[0] == '\0' || text[0] == '-') {
        return NO;
    }

    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno == ERANGE || end == text || end == NULL || *end != '\0' ||
        parsed > maximum) {
        return NO;
    }
    *value = (uint64_t)parsed;
    return YES;
}

static EC20USBATDeviceSelector *ParseSelector(int argc,
                                              const char *argv[],
                                              int firstArgument,
                                              BOOL *valid)
{
    EC20USBATDeviceSelector *selector = [EC20USBATDeviceSelector anyDevice];
    BOOL hasSelector = NO;
    *valid = YES;

    for (int index = firstArgument; index < argc; index++) {
        BOOL isRegistry = strcmp(argv[index], "--registry-id") == 0;
        BOOL isLocation = strcmp(argv[index], "--location-id") == 0;
        if ((!isRegistry && !isLocation) || hasSelector || index + 1 >= argc) {
            *valid = NO;
            return selector;
        }

        uint64_t value = 0;
        uint64_t maximum = isRegistry ? UINT64_MAX : UINT32_MAX;
        if (!ParseUnsignedID(argv[++index], maximum, &value)) {
            *valid = NO;
            return selector;
        }
        selector = isRegistry
            ? [EC20USBATDeviceSelector selectorWithRegistryID:value]
            : [EC20USBATDeviceSelector selectorWithLocationID:(uint32_t)value];
        hasSelector = YES;
    }
    return selector;
}

static int RunList(void)
{
    NSError *error = nil;
    NSArray<EC20USBATDevice *> *devices =
        [EC20USBATTransport enumerateDevicesWithError:&error];
    if (devices == nil) {
        PrintNSError("枚举 USB 接口失败", error);
        return ExitDeviceSelection;
    }
    if (devices.count == 0) {
        fprintf(stderr, "未找到 2c7c:0125 configuration 1 interface 2\n");
        return ExitDeviceSelection;
    }

    __block BOOL hadOpenFailure = NO;
    __block BOOL hadLayoutFailure = NO;
    [devices enumerateObjectsUsingBlock:
        ^(EC20USBATDevice *device, NSUInteger index, BOOL *stop) {
            (void)stop;
            PrintDeviceIdentity(device, index + 1);

            NSError *openError = nil;
            EC20USBATTransport *transport = [EC20USBATTransport
                openWithSelector:[EC20USBATDeviceSelector
                    selectorWithRegistryID:device.registryID]
                error:&openError];
            if (transport == nil) {
                PrintNSError("打开接口 2 失败", openError);
                int exitCode = ExitCodeForTransportError(openError);
                hadOpenFailure |= exitCode == ExitInterfaceOpen ||
                                  exitCode == ExitDeviceSelection;
                hadLayoutFailure |= exitCode == ExitEndpointLayout;
                return;
            }

            PrintEndpointLayout(transport.device);
            fprintf(stdout, "  AT bulk 布局: 有效\n");
            [transport close];
        }];

    fprintf(stdout, "共找到 %lu 个匹配的接口 2\n", (unsigned long)devices.count);
    if (hadOpenFailure) {
        return ExitInterfaceOpen;
    }
    if (hadLayoutFailure) {
        return ExitEndpointLayout;
    }
    return ExitOK;
}

static int RunCommands(NSArray<NSString *> *commands,
                       EC20USBATDeviceSelector *selector)
{
    for (NSString *command in commands) {
        if (!IsAllowedCommand(command)) {
            fprintf(stderr, "安全策略拒绝命令: %s\n", CString(command));
            return ExitUnsafeCommand;
        }
    }

    NSError *error = nil;
    EC20USBATTransport *transport =
        [EC20USBATTransport openWithSelector:selector error:&error];
    if (transport == nil) {
        PrintNSError("打开 EC20 AT 传输失败", error);
        int exitCode = ExitCodeForTransportError(error);
        if (exitCode == ExitInterfaceOpen) {
            fprintf(stderr, "未使用 capture/seize，不会踢掉现有 owner。\n");
        } else if (exitCode == ExitEndpointLayout) {
            fprintf(stderr,
                    "接口 2 必须恰好有一个 bulk IN 和一个 bulk OUT；拒绝继续。\n");
        }
        return exitCode;
    }

    PrintDeviceIdentity(transport.device, 1);
    PrintEndpointLayout(transport.device);
    fprintf(stdout,
            "已打开 interface 2: bulk OUT=0x%02x, bulk IN=0x%02x\n",
            transport.bulkOutAddress,
            transport.bulkInAddress);

    int exitCode = ExitOK;
    for (NSString *command in commands) {
        __block BOOL printedCommand = NO;
        EC20USBATTraceHandler traceHandler =
            ^(EC20USBATTraceKind kind, NSData *data) {
                if (kind == EC20USBATTraceStaleInput) {
                    PrintChunk("STALE", data);
                } else if (kind == EC20USBATTraceCommandReady) {
                    fprintf(stdout, "\n>>> %s\\r\n", CString(command));
                    fflush(stdout);
                    printedCommand = YES;
                } else {
                    PrintChunk("RX", data);
                }
            };

        NSData *response = nil;
        EC20USBATTerminalState state = EC20USBATTerminalPending;
        error = nil;
        BOOL succeeded = [transport executeCommand:command
                                          response:&response
                                      terminalState:&state
                                       traceHandler:traceHandler
                                              error:&error];
        if (!printedCommand && error.code == EC20USBATTransportErrorUSBWrite) {
            fprintf(stdout, "\n>>> %s\\r\n", CString(command));
        }

        if (response.length != 0 || printedCommand) {
            NSString *decoded = [EC20USBATTransport decodeResponseData:response];
            fprintf(stdout, "--- response ---\n%s\n----------------\n", CString(decoded));
        }

        if (!succeeded) {
            PrintNSError("AT 命令失败", error);
            exitCode = ExitCodeForTransportError(error);
            break;
        }
        if (state != EC20USBATTerminalOK) {
            fprintf(stderr, "AT 命令未返回 OK\n");
            exitCode = ExitUSBRead;
            break;
        }
    }

    [transport close];
    return exitCode;
}

static int RunSelfTest(void)
{
    NSArray<NSDictionary *> *cases = @[
        @{@"bytes": [@"\r\nOK\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(EC20USBATTerminalOK)},
        @{@"bytes": [@"AT\r\r\nOK\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(EC20USBATTerminalOK)},
        @{@"bytes": [@"\r\n+CME ERROR: 10\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(EC20USBATTerminalError)},
        @{@"bytes": [@"\r\n+QCFG: \"usbnet\",1\r\n"
                       dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(EC20USBATTerminalPending)},
        @{@"bytes": [@"\r\n+CPIN: READY\r\n\r\n+QIND: PB DONE\r\nAT\r\r\nOK\r\n"
                       dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(EC20USBATTerminalOK)},
    ];

    for (NSDictionary *testCase in cases) {
        EC20USBATTerminalState got =
            [EC20USBATTransport terminalStateForResponseData:testCase[@"bytes"]];
        EC20USBATTerminalState want = [testCase[@"want"] unsignedIntegerValue];
        if (got != want) {
            fprintf(stderr, "终止行解析自测失败: got=%lu want=%lu\n",
                    (unsigned long)got, (unsigned long)want);
            return ExitSelfTest;
        }
    }

    if (!IsAllowedCommand(@"AT") ||
        !IsAllowedCommand(@"AT+QCFG=\"usbnet\"") ||
        IsAllowedCommand(@"AT+QCFG=\"usbnet\",1") ||
        IsAllowedCommand(@"AT+CFUN=1,1")) {
        fprintf(stderr, "命令 allowlist 自测失败\n");
        return ExitSelfTest;
    }

    uint64_t parsed = 0;
    if (!ParseUnsignedID("0x1234", UINT64_MAX, &parsed) || parsed != 0x1234 ||
        ParseUnsignedID("0x12z", UINT64_MAX, &parsed) ||
        ParseUnsignedID("4294967296", UINT32_MAX, &parsed)) {
        fprintf(stderr, "设备选择 ID 解析自测失败\n");
        return ExitSelfTest;
    }

    fprintf(stdout, "self-test: PASS\n");
    return ExitOK;
}

static int RunInteractiveRecovery(EC20USBATDeviceSelector *selector)
{
    NSError *error = nil;
    EC20USBATTransport *transport =
        [EC20USBATTransport openWithSelector:selector error:&error];
    if (transport == nil) {
        PrintNSError("打开 EC20 AT 传输失败", error);
        return ExitCodeForTransportError(error);
    }
    EC20USBATTraceHandler traceHandler =
        ^(EC20USBATTraceKind kind, NSData *data) {
        if (kind == EC20USBATTraceStaleInput) {
            PrintChunk("STALE", data);
        } else if (kind == EC20USBATTraceCommandReady) {
            PrintChunk("TX", data);
        } else {
            PrintChunk("RX", data);
        }
    };
    NSData *response = nil;
    BOOL succeeded = [transport cancelInteractiveInputWithResponse:&response
                                                       traceHandler:traceHandler
                                                              error:&error];
    [transport close];
    if (!succeeded) {
        PrintNSError("交互恢复失败", error);
        return ExitCodeForTransportError(error);
    }
    fprintf(stdout, "已发送 ESC；必须继续用 AT/OK 验证模块恢复。\n");
    return ExitOK;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--list") == 0) {
            return RunList();
        }
        if (argc >= 2 && strcmp(argv[1], "--experiment") == 0) {
            BOOL valid = NO;
            EC20USBATDeviceSelector *selector =
                ParseSelector(argc, argv, 2, &valid);
            if (!valid) {
                PrintUsage(argv[0]);
                return ExitUsage;
            }
            // Repeat AT/OK once to verify that the link remains stable.
            return RunCommands(@[
                @"AT",
                @"AT",
                @"ATI",
                @"AT+GMR",
                @"AT+QCFG=\"usbnet\"",
            ], selector);
        }
        if (argc >= 3 && strcmp(argv[1], "--command") == 0) {
            BOOL valid = NO;
            EC20USBATDeviceSelector *selector =
                ParseSelector(argc, argv, 3, &valid);
            if (!valid) {
                PrintUsage(argv[0]);
                return ExitUsage;
            }
            NSString *command = [NSString stringWithUTF8String:argv[2]];
            return RunCommands(@[command != nil ? command : @""], selector);
        }
        if (argc >= 2 && strcmp(argv[1], "--recover-interactive") == 0) {
            BOOL valid = NO;
            EC20USBATDeviceSelector *selector =
                ParseSelector(argc, argv, 2, &valid);
            if (!valid) {
                PrintUsage(argv[0]);
                return ExitUsage;
            }
            return RunInteractiveRecovery(selector);
        }
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        PrintUsage(argv[0]);
        return ExitUsage;
    }
}
