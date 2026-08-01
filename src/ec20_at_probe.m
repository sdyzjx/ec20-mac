#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOReturn.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>
#import <IOUSBHost/IOUSBHost.h>

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const uint16_t kEC20VendorID = 0x2c7c;
static const uint16_t kEC20ProductID = 0x0125;
static const uint8_t kATInterfaceNumber = 2;
static const NSTimeInterval kReadSliceSeconds = 0.35;
static const NSTimeInterval kCommandDeadlineSeconds = 3.0;
static const NSTimeInterval kDrainQuietSeconds = 0.15;
static const NSTimeInterval kDrainDeadlineSeconds = 0.75;
static const NSUInteger kMaxResponseBytes = 64 * 1024;

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

typedef NS_ENUM(NSUInteger, TerminalState) {
    TerminalPending,
    TerminalOK,
    TerminalError,
};

typedef struct {
    BOOL hasBulkIn;
    BOOL hasBulkOut;
    uint8_t bulkInAddress;
    uint8_t bulkOutAddress;
    uint16_t bulkInMaxPacketSize;
    uint16_t bulkOutMaxPacketSize;
    NSUInteger endpointCount;
    NSUInteger bulkInCount;
    NSUInteger bulkOutCount;
} EndpointLayout;

static void PrintUsage(const char *program)
{
    fprintf(stderr,
            "用法:\n"
            "  %s --list\n"
            "  %s --experiment\n"
            "  %s --command 'AT+QCFG=\"usbnet\"'\n"
            "  %s --self-test\n\n"
            "第一版仅允许: AT, ATI, AT+GMR, AT+QCFG=\"usbnet\"。\n"
            "它只接管 2c7c:0125 的 USB 接口 2，绝不打开接口 4。\n",
            program, program, program, program);
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
}

static BOOL IsTimeoutError(NSError *error)
{
    return error != nil &&
           [error.domain isEqualToString:IOUSBHostErrorDomain] &&
           (uint32_t)error.code == (uint32_t)kIOReturnTimeout;
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

static NSString *DecodeResponse(NSData *data)
{
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text != nil ? text : @"";
}

static TerminalState TerminalStateForResponse(NSData *data)
{
    NSString *text = DecodeResponse(data);
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:trimSet];
        if ([line isEqualToString:@"OK"]) {
            return TerminalOK;
        }
        if ([line isEqualToString:@"ERROR"] ||
            [line hasPrefix:@"+CME ERROR:"] ||
            [line hasPrefix:@"+CMS ERROR:"]) {
            return TerminalError;
        }
    }
    return TerminalPending;
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

static CFMutableDictionaryRef CreateInterfaceMatchingDictionary(void)
{
    // IOServiceMatching has an accurate CF_RETURNS_RETAINED annotation. The
    // similar IOUSBHostInterface Objective-C helper is caller-owned too, but its
    // Xcode 26.5 declaration omits that annotation and confuses clang --analyze.
    CFMutableDictionaryRef matching =
        IOServiceMatching(kIOUSBHostInterfaceClassName);
    if (matching == NULL) {
        return NULL;
    }

    CFDictionarySetValue(matching,
                         CFSTR(kUSBHostMatchingPropertyVendorID),
                         (__bridge CFNumberRef)@(kEC20VendorID));
    CFDictionarySetValue(matching,
                         CFSTR(kUSBHostMatchingPropertyProductID),
                         (__bridge CFNumberRef)@(kEC20ProductID));
    CFDictionarySetValue(matching,
                         CFSTR(kUSBHostMatchingPropertyConfigurationValue),
                         (__bridge CFNumberRef)@(1));
    CFDictionarySetValue(matching,
                         CFSTR(kUSBHostMatchingPropertyInterfaceNumber),
                         (__bridge CFNumberRef)@(kATInterfaceNumber));
    return matching;
}

static kern_return_t CreateInterfaceIterator(io_iterator_t *iterator)
{
    CFMutableDictionaryRef matching = CreateInterfaceMatchingDictionary();
    if (matching == NULL) {
        return kIOReturnNoMemory;
    }

    // IOServiceGetMatchingServices consumes the matching dictionary reference.
    return IOServiceGetMatchingServices(kIOMainPortDefault, matching, iterator);
}

static void PrintServiceIdentity(io_service_t service, NSUInteger ordinal)
{
    uint64_t registryID = 0;
    io_string_t path = {0};
    IORegistryEntryGetRegistryEntryID(service, &registryID);
    IORegistryEntryGetPath(service, kIOServicePlane, path);

    CFTypeRef locationProperty = IORegistryEntryCreateCFProperty(
        service, CFSTR("locationID"), kCFAllocatorDefault, 0);
    NSNumber *location = CFBridgingRelease(locationProperty);

    fprintf(stdout,
            "设备 %lu: registry-id=0x%llx, location-id=0x%08x\n"
            "  path: %s\n",
            (unsigned long)ordinal,
            (unsigned long long)registryID,
            location != nil ? location.unsignedIntValue : 0,
            path[0] != '\0' ? path : "<未知>");
}

static io_service_t CopyExactlyOneMatchedService(NSUInteger *matchCount,
                                                  kern_return_t *result)
{
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = CreateInterfaceIterator(&iterator);
    if (result != NULL) {
        *result = kr;
    }
    if (kr != kIOReturnSuccess) {
        if (matchCount != NULL) {
            *matchCount = 0;
        }
        return IO_OBJECT_NULL;
    }

    io_service_t selected = IO_OBJECT_NULL;
    NSUInteger count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        count++;
        if (count == 1) {
            selected = service;
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);

    if (matchCount != NULL) {
        *matchCount = count;
    }
    if (count != 1 && selected != IO_OBJECT_NULL) {
        IOObjectRelease(selected);
        selected = IO_OBJECT_NULL;
    }
    return selected;
}

static IOUSBHostInterface *OpenInterface(io_service_t service, NSError **error)
{
    return [[IOUSBHostInterface alloc]
        initWithIOService:service
                  options:IOUSBHostObjectInitOptionsNone
                    queue:nil
                    error:error
          interestHandler:nil];
}

static BOOL DiscoverEndpoints(IOUSBHostInterface *interface,
                              EndpointLayout *layout,
                              BOOL printAll)
{
    memset(layout, 0, sizeof(*layout));

    const IOUSBConfigurationDescriptor *configuration = interface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *interfaceDescriptor = interface.interfaceDescriptor;
    if (configuration == NULL || interfaceDescriptor == NULL) {
        fprintf(stderr, "接口没有可用的配置/接口描述符\n");
        return NO;
    }

    BOOL descriptorValid =
        configuration->bConfigurationValue == 1 &&
        interfaceDescriptor->bInterfaceNumber == kATInterfaceNumber &&
        interfaceDescriptor->bAlternateSetting == 0 &&
        interfaceDescriptor->bInterfaceClass == 0xff &&
        interfaceDescriptor->bInterfaceSubClass == 0x00 &&
        interfaceDescriptor->bInterfaceProtocol == 0x00 &&
        interfaceDescriptor->bNumEndpoints == 3;

    if (printAll) {
        fprintf(stdout,
                "  interface=%u alt=%u class=%02x/%02x/%02x endpoints=%u\n",
                interfaceDescriptor->bInterfaceNumber,
                interfaceDescriptor->bAlternateSetting,
                interfaceDescriptor->bInterfaceClass,
                interfaceDescriptor->bInterfaceSubClass,
                interfaceDescriptor->bInterfaceProtocol,
                interfaceDescriptor->bNumEndpoints);
    }

    const IOUSBDescriptorHeader *cursor = NULL;
    const IOUSBEndpointDescriptor *endpoint;
    BOOL endpointMetadataValid = YES;
    while ((endpoint = IOUSBGetNextEndpointDescriptor(
                configuration, interfaceDescriptor, cursor)) != NULL) {
        cursor = (const IOUSBDescriptorHeader *)endpoint;
        layout->endpointCount++;

        uint8_t address = IOUSBGetEndpointAddress(endpoint);
        uint8_t direction = IOUSBGetEndpointDirection(endpoint);
        uint8_t type = IOUSBGetEndpointType(endpoint);
        uint16_t maxPacketSize = USBToHost16(endpoint->wMaxPacketSize) &
                                 kIOUSBEndpointDescriptorPacketSize;

        if (IOUSBGetEndpointNumber(endpoint) == 0 ||
            maxPacketSize == 0 || maxPacketSize > 1024) {
            endpointMetadataValid = NO;
        }

        if (printAll) {
            const char *typeName = type == kIOUSBEndpointTypeBulk ? "bulk" :
                                   type == kIOUSBEndpointTypeInterrupt ? "interrupt" :
                                   type == kIOUSBEndpointTypeIsochronous ? "isochronous" :
                                   "control";
            const char *directionName = direction == kIOUSBEndpointDirectionIn ? "IN" : "OUT";
            fprintf(stdout,
                    "    endpoint=0x%02x type=%s direction=%s max-packet=%u\n",
                    address, typeName, directionName, maxPacketSize);
        }

        if (type != kIOUSBEndpointTypeBulk) {
            continue;
        }
        if (direction == kIOUSBEndpointDirectionIn) {
            layout->hasBulkIn = YES;
            layout->bulkInAddress = address;
            layout->bulkInMaxPacketSize = maxPacketSize;
            layout->bulkInCount++;
        } else {
            layout->hasBulkOut = YES;
            layout->bulkOutAddress = address;
            layout->bulkOutMaxPacketSize = maxPacketSize;
            layout->bulkOutCount++;
        }
    }

    BOOL endpointCountValid =
        layout->endpointCount == interfaceDescriptor->bNumEndpoints;
    if (!descriptorValid || !endpointMetadataValid || !endpointCountValid) {
        fprintf(stderr,
                "接口 2 描述符不符合安全断言 "
                "(config=1, if=2, alt=0, ff/00/00, 3 endpoints)\n");
    }

    return descriptorValid && endpointMetadataValid && endpointCountValid &&
           layout->hasBulkIn && layout->hasBulkOut &&
           layout->bulkInCount == 1 && layout->bulkOutCount == 1;
}

static int DrainStaleInput(IOUSBHostPipe *bulkIn)
{
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime +
                              kDrainDeadlineSeconds;
    NSUInteger totalBytes = 0;

    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining < kDrainQuietSeconds) {
            break; // There is not enough budget to prove a full quiet slice.
        }
        NSTimeInterval timeout = kDrainQuietSeconds;

        NSMutableData *rx = [NSMutableData dataWithLength:4096];
        NSUInteger bytesTransferred = 0;
        NSError *error = nil;
        BOOL read = [bulkIn sendIORequestWithData:rx
                                 bytesTransferred:&bytesTransferred
                                completionTimeout:timeout
                                            error:&error];
        if (!read) {
            if (IsTimeoutError(error)) {
                return ExitOK; // A full quiet slice establishes the boundary.
            }
            PrintNSError("排空 bulk IN 失败", error);
            return ExitUSBRead;
        }
        if (bytesTransferred > rx.length) {
            fprintf(stderr, "排空读取返回越界长度: %lu > %lu\n",
                    (unsigned long)bytesTransferred, (unsigned long)rx.length);
            return ExitUSBRead;
        }
        if (bytesTransferred == 0) {
            continue;
        }
        if (totalBytes > kMaxResponseBytes - bytesTransferred) {
            fprintf(stderr, "排空数据超过 %lu bytes，拒绝发送新命令\n",
                    (unsigned long)kMaxResponseBytes);
            return ExitUSBRead;
        }

        totalBytes += bytesTransferred;
        NSData *chunk = [NSData dataWithBytes:rx.bytes length:bytesTransferred];
        PrintChunk("STALE", chunk);
    }

    fprintf(stderr, "bulk IN 在 %.2f 秒内没有出现静默窗口，拒绝发送新命令\n",
            kDrainDeadlineSeconds);
    return ExitUSBRead;
}

static int RunOneCommand(IOUSBHostPipe *bulkIn,
                         IOUSBHostPipe *bulkOut,
                         NSString *command)
{
    if (!IsAllowedCommand(command)) {
        fprintf(stderr, "安全策略拒绝命令: %s\n", CString(command));
        return ExitUnsafeCommand;
    }

    int drainResult = DrainStaleInput(bulkIn);
    if (drainResult != ExitOK) {
        return drainResult;
    }

    NSString *wireCommand = [command stringByAppendingString:@"\r"];
    NSMutableData *tx = [[wireCommand dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    NSUInteger bytesTransferred = 0;
    NSError *error = nil;

    fprintf(stdout, "\n>>> %s\\r\n", CString(command));
    BOOL wrote = [bulkOut sendIORequestWithData:tx
                               bytesTransferred:&bytesTransferred
                              completionTimeout:1.0
                                          error:&error];
    if (!wrote || bytesTransferred != tx.length) {
        if (!wrote) {
            PrintNSError("bulk OUT 失败", error);
        } else {
            fprintf(stderr, "bulk OUT 短写: %lu/%lu bytes\n",
                    (unsigned long)bytesTransferred, (unsigned long)tx.length);
        }
        return ExitUSBWrite;
    }

    NSMutableData *response = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime +
                              kCommandDeadlineSeconds;
    TerminalState state = TerminalPending;

    while (NSProcessInfo.processInfo.systemUptime < deadline &&
           state == TerminalPending) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        NSTimeInterval timeout = remaining > 0.001 ? remaining : 0.001;
        if (timeout > kReadSliceSeconds) {
            timeout = kReadSliceSeconds;
        }
        NSMutableData *rx = [NSMutableData dataWithLength:4096];
        bytesTransferred = 0;
        error = nil;

        BOOL read = [bulkIn sendIORequestWithData:rx
                                 bytesTransferred:&bytesTransferred
                                completionTimeout:timeout
                                            error:&error];
        if (!read) {
            if (IsTimeoutError(error)) {
                continue;
            }
            PrintNSError("bulk IN 失败", error);
            return ExitUSBRead;
        }
        if (bytesTransferred == 0) {
            continue;
        }

        if (bytesTransferred > rx.length) {
            fprintf(stderr, "bulk IN 返回越界长度: %lu > %lu\n",
                    (unsigned long)bytesTransferred, (unsigned long)rx.length);
            return ExitUSBRead;
        }
        if (response.length > kMaxResponseBytes - bytesTransferred) {
            fprintf(stderr, "单条 AT 响应超过 %lu bytes，终止读取\n",
                    (unsigned long)kMaxResponseBytes);
            return ExitUSBRead;
        }

        NSData *chunk = [NSData dataWithBytes:rx.bytes length:bytesTransferred];
        PrintChunk("RX", chunk);
        [response appendData:chunk];
        state = TerminalStateForResponse(response);
    }

    NSString *decoded = DecodeResponse(response);
    fprintf(stdout, "--- response ---\n%s\n----------------\n", CString(decoded));

    if (state == TerminalOK) {
        return ExitOK;
    }
    if (state == TerminalError) {
        fprintf(stderr, "模块返回显式 ERROR\n");
        return ExitModemError;
    }

    fprintf(stderr, "等待终止行超时（%.1f 秒，已收到 %lu bytes）\n",
            kCommandDeadlineSeconds, (unsigned long)response.length);
    return ExitUSBRead;
}

static int RunList(void)
{
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = CreateInterfaceIterator(&iterator);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "枚举 USB 接口失败: 0x%08x\n", kr);
        return ExitDeviceSelection;
    }

    NSUInteger count = 0;
    BOOL hadOpenFailure = NO;
    BOOL hadLayoutFailure = NO;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        count++;
        PrintServiceIdentity(service, count);

        NSError *error = nil;
        IOUSBHostInterface *interface = OpenInterface(service, &error);
        if (interface == nil) {
            PrintNSError("打开接口 2 失败", error);
            hadOpenFailure = YES;
        } else {
            EndpointLayout layout;
            BOOL valid = DiscoverEndpoints(interface, &layout, YES);
            fprintf(stdout, "  AT bulk 布局: %s\n", valid ? "有效" : "无效");
            hadLayoutFailure |= !valid;
            [interface destroy];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (count == 0) {
        fprintf(stderr, "未找到 2c7c:0125 configuration 1 interface 2\n");
        return ExitDeviceSelection;
    }
    fprintf(stdout, "共找到 %lu 个匹配的接口 2\n", (unsigned long)count);
    if (hadOpenFailure) {
        return ExitInterfaceOpen;
    }
    if (hadLayoutFailure) {
        return ExitEndpointLayout;
    }
    return ExitOK;
}

static int RunCommands(NSArray<NSString *> *commands)
{
    for (NSString *command in commands) {
        if (!IsAllowedCommand(command)) {
            fprintf(stderr, "安全策略拒绝命令: %s\n", CString(command));
            return ExitUnsafeCommand;
        }
    }

    NSUInteger count = 0;
    kern_return_t kr = kIOReturnSuccess;
    io_service_t service = CopyExactlyOneMatchedService(&count, &kr);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "枚举 USB 接口失败: 0x%08x\n", kr);
        return ExitDeviceSelection;
    }
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "需要且仅允许一个匹配接口；当前找到 %lu 个\n",
                (unsigned long)count);
        return ExitDeviceSelection;
    }

    PrintServiceIdentity(service, 1);
    NSError *error = nil;
    IOUSBHostInterface *interface = OpenInterface(service, &error);
    IOObjectRelease(service);
    if (interface == nil) {
        PrintNSError("无法独占打开接口 2", error);
        fprintf(stderr, "未使用 capture/seize，不会踢掉现有 owner。\n");
        return ExitInterfaceOpen;
    }

    int exitCode = ExitEndpointLayout;
    @autoreleasepool {
        EndpointLayout layout;
        if (!DiscoverEndpoints(interface, &layout, YES)) {
            fprintf(stderr,
                    "接口 2 必须恰好有一个 bulk IN 和一个 bulk OUT；拒绝继续。\n");
            goto cleanup;
        }

        error = nil;
        IOUSBHostPipe *bulkIn = [interface copyPipeWithAddress:layout.bulkInAddress
                                                         error:&error];
        if (bulkIn == nil) {
            PrintNSError("创建 bulk IN pipe 失败", error);
            goto cleanup;
        }

        error = nil;
        IOUSBHostPipe *bulkOut = [interface copyPipeWithAddress:layout.bulkOutAddress
                                                          error:&error];
        if (bulkOut == nil) {
            PrintNSError("创建 bulk OUT pipe 失败", error);
            goto cleanup;
        }

        fprintf(stdout,
                "已打开 interface 2: bulk OUT=0x%02x, bulk IN=0x%02x\n",
                layout.bulkOutAddress, layout.bulkInAddress);

        exitCode = ExitOK;
        for (NSString *command in commands) {
            exitCode = RunOneCommand(bulkIn, bulkOut, command);
            if (exitCode != ExitOK) {
                break;
            }
        }

        // ARC releases the pipe objects before the enclosing autorelease pool ends.
        bulkIn = nil;
        bulkOut = nil;
    }

cleanup:
    [interface destroy];
    return exitCode;
}

static int RunSelfTest(void)
{
    NSArray<NSDictionary *> *cases = @[
        @{@"bytes": [@"\r\nOK\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(TerminalOK)},
        @{@"bytes": [@"AT\r\r\nOK\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(TerminalOK)},
        @{@"bytes": [@"\r\n+CME ERROR: 10\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(TerminalError)},
        @{@"bytes": [@"\r\n+QCFG: \"usbnet\",1\r\n" dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(TerminalPending)},
        @{@"bytes": [@"\r\n+CPIN: READY\r\n\r\n+QIND: PB DONE\r\nAT\r\r\nOK\r\n"
                     dataUsingEncoding:NSASCIIStringEncoding],
          @"want": @(TerminalOK)},
    ];

    for (NSDictionary *testCase in cases) {
        TerminalState got = TerminalStateForResponse(testCase[@"bytes"]);
        TerminalState want = [testCase[@"want"] unsignedIntegerValue];
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

    fprintf(stdout, "self-test: PASS\n");
    return ExitOK;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--list") == 0) {
            return RunList();
        }
        if (argc == 2 && strcmp(argv[1], "--experiment") == 0) {
            // Repeat AT/OK once to verify that the link remains stable.
            return RunCommands(@[
                @"AT",
                @"AT",
                @"ATI",
                @"AT+GMR",
                @"AT+QCFG=\"usbnet\"",
            ]);
        }
        if (argc == 3 && strcmp(argv[1], "--command") == 0) {
            NSString *command = [NSString stringWithUTF8String:argv[2]];
            return RunCommands(@[command != nil ? command : @""]);
        }
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        PrintUsage(argv[0]);
        return ExitUsage;
    }
}
