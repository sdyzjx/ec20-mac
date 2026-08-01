#import "EC20USBATTransport.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/IOReturn.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>
#import <IOUSBHost/IOUSBHost.h>

#include <stdint.h>

NSErrorDomain const EC20USBATTransportErrorDomain = @"EC20USBATTransportErrorDomain";
NSString *const EC20USBATMatchedDeviceCountErrorKey = @"EC20USBATMatchedDeviceCount";
NSString *const EC20USBATIOReturnErrorKey = @"EC20USBATIOReturn";

static const uint16_t kEC20VendorID = 0x2c7c;
static const uint16_t kEC20ProductID = 0x0125;
static const uint8_t kATConfigurationValue = 1;
static const uint8_t kATInterfaceNumber = 2;
static const NSTimeInterval kReadSliceSeconds = 0.35;
static const NSTimeInterval kCommandDeadlineSeconds = 3.0;
static const NSTimeInterval kDrainQuietSeconds = 0.15;
static const NSTimeInterval kDrainDeadlineSeconds = 0.75;
static const NSUInteger kMaxResponseBytes = 64 * 1024;

@interface EC20USBEndpointInfo ()
@property(nonatomic, readwrite) uint8_t address;
@property(nonatomic, readwrite) uint8_t type;
@property(nonatomic, readwrite) uint8_t direction;
@property(nonatomic, readwrite) uint16_t maxPacketSize;
@end

@implementation EC20USBEndpointInfo
@end

@interface EC20USBATDevice ()
@property(nonatomic, readwrite) uint64_t registryID;
@property(nonatomic, readwrite) uint32_t locationID;
@property(nonatomic, copy, readwrite) NSString *registryPath;
@property(nonatomic, readwrite) uint8_t configurationValue;
@property(nonatomic, readwrite) uint8_t interfaceNumber;
@property(nonatomic, readwrite) uint8_t alternateSetting;
@property(nonatomic, readwrite) uint8_t interfaceClass;
@property(nonatomic, readwrite) uint8_t interfaceSubClass;
@property(nonatomic, readwrite) uint8_t interfaceProtocol;
@property(nonatomic, copy, readwrite) NSArray<EC20USBEndpointInfo *> *endpoints;
@end

@implementation EC20USBATDevice

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        _registryPath = @"";
        _endpoints = @[];
    }
    return self;
}

@end

@interface EC20USBATDeviceSelector ()
@property(nonatomic, strong, readwrite, nullable) NSNumber *registryID;
@property(nonatomic, strong, readwrite, nullable) NSNumber *locationID;
@end

@implementation EC20USBATDeviceSelector

+ (instancetype)anyDevice
{
    return [[self alloc] init];
}

+ (instancetype)selectorWithRegistryID:(uint64_t)registryID
{
    EC20USBATDeviceSelector *selector = [[self alloc] init];
    selector.registryID = @(registryID);
    return selector;
}

+ (instancetype)selectorWithLocationID:(uint32_t)locationID
{
    EC20USBATDeviceSelector *selector = [[self alloc] init];
    selector.locationID = @(locationID);
    return selector;
}

@end

@interface EC20USBATTransport ()
@property(nonatomic, strong, readwrite) EC20USBATDevice *device;
@property(nonatomic, readwrite) uint8_t bulkInAddress;
@property(nonatomic, readwrite) uint8_t bulkOutAddress;
@property(nonatomic, strong, nullable) IOUSBHostInterface *usbInterface;
@property(nonatomic, strong, nullable) IOUSBHostPipe *bulkIn;
@property(nonatomic, strong, nullable) IOUSBHostPipe *bulkOut;
@end

static NSError *TransportError(EC20USBATTransportErrorCode code,
                               NSString *description,
                               NSError *underlying,
                               NSDictionary *additionalInfo)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description;
    if (underlying != nil) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    if (additionalInfo != nil) {
        [info addEntriesFromDictionary:additionalInfo];
    }
    return [NSError errorWithDomain:EC20USBATTransportErrorDomain
                               code:code
                           userInfo:info];
}

static BOOL IsTimeoutError(NSError *error)
{
    return error != nil &&
           [error.domain isEqualToString:IOUSBHostErrorDomain] &&
           (uint32_t)error.code == (uint32_t)kIOReturnTimeout;
}

static CFMutableDictionaryRef CreateInterfaceMatchingDictionary(void)
{
    // IOServiceGetMatchingServices consumes this caller-owned dictionary.
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBHostInterfaceClassName);
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
                         (__bridge CFNumberRef)@(kATConfigurationValue));
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
    return IOServiceGetMatchingServices(kIOMainPortDefault, matching, iterator);
}

static EC20USBATDevice *DeviceFromService(io_service_t service)
{
    EC20USBATDevice *device = [[EC20USBATDevice alloc] init];

    uint64_t registryID = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &registryID) == kIOReturnSuccess) {
        device.registryID = registryID;
    }

    io_string_t path = {0};
    if (IORegistryEntryGetPath(service, kIOServicePlane, path) == kIOReturnSuccess) {
        NSString *registryPath = [NSString stringWithUTF8String:path];
        if (registryPath != nil) {
            device.registryPath = registryPath;
        }
    }

    CFTypeRef locationProperty = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        CFSTR("locationID"),
        kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    id location = CFBridgingRelease(locationProperty);
    if ([location isKindOfClass:[NSNumber class]]) {
        device.locationID = [location unsignedIntValue];
    }

    return device;
}

static BOOL SelectorMatchesDevice(EC20USBATDeviceSelector *selector,
                                  EC20USBATDevice *device)
{
    if (selector.registryID != nil &&
        selector.registryID.unsignedLongLongValue != device.registryID) {
        return NO;
    }
    if (selector.locationID != nil &&
        selector.locationID.unsignedIntValue != device.locationID) {
        return NO;
    }
    return YES;
}

static io_service_t CopySelectedService(EC20USBATDeviceSelector *selector,
                                        EC20USBATDevice **selectedDevice,
                                        NSError **error)
{
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = CreateInterfaceIterator(&iterator);
    if (kr != kIOReturnSuccess) {
        if (error != NULL) {
            *error = TransportError(
                EC20USBATTransportErrorEnumeration,
                [NSString stringWithFormat:@"枚举 USB 接口失败: 0x%08x", kr],
                nil,
                @{EC20USBATIOReturnErrorKey: @((uint32_t)kr)});
        }
        return IO_OBJECT_NULL;
    }

    io_service_t selected = IO_OBJECT_NULL;
    EC20USBATDevice *identity = nil;
    NSUInteger count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        EC20USBATDevice *candidate = DeviceFromService(service);
        if (SelectorMatchesDevice(selector, candidate)) {
            count++;
            if (selected == IO_OBJECT_NULL) {
                selected = service;
                identity = candidate;
                continue;
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    if (count != 1) {
        if (selected != IO_OBJECT_NULL) {
            IOObjectRelease(selected);
        }
        if (error != NULL) {
            NSString *description;
            if (selector.registryID != nil) {
                description = [NSString stringWithFormat:
                    @"registry-id=0x%llx 匹配到 %lu 个接口 2",
                    selector.registryID.unsignedLongLongValue,
                    (unsigned long)count];
            } else if (selector.locationID != nil) {
                description = [NSString stringWithFormat:
                    @"location-id=0x%08x 匹配到 %lu 个接口 2",
                    selector.locationID.unsignedIntValue,
                    (unsigned long)count];
            } else {
                description = [NSString stringWithFormat:
                    @"需要且仅允许一个匹配接口；当前找到 %lu 个",
                    (unsigned long)count];
            }
            *error = TransportError(
                EC20USBATTransportErrorDeviceSelection,
                description,
                nil,
                @{EC20USBATMatchedDeviceCountErrorKey: @(count)});
        }
        return IO_OBJECT_NULL;
    }

    if (selectedDevice != NULL) {
        *selectedDevice = identity;
    }
    return selected;
}

static BOOL PopulateAndValidateEndpoints(IOUSBHostInterface *usbInterface,
                                         EC20USBATDevice *device,
                                         uint8_t *bulkInAddress,
                                         uint8_t *bulkOutAddress,
                                         NSError **error)
{
    const IOUSBConfigurationDescriptor *configuration =
        usbInterface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *interfaceDescriptor =
        usbInterface.interfaceDescriptor;
    if (configuration == NULL || interfaceDescriptor == NULL) {
        if (error != NULL) {
            *error = TransportError(EC20USBATTransportErrorEndpointLayout,
                                    @"接口没有可用的配置/接口描述符",
                                    nil,
                                    nil);
        }
        return NO;
    }

    device.configurationValue = configuration->bConfigurationValue;
    device.interfaceNumber = interfaceDescriptor->bInterfaceNumber;
    device.alternateSetting = interfaceDescriptor->bAlternateSetting;
    device.interfaceClass = interfaceDescriptor->bInterfaceClass;
    device.interfaceSubClass = interfaceDescriptor->bInterfaceSubClass;
    device.interfaceProtocol = interfaceDescriptor->bInterfaceProtocol;

    BOOL descriptorValid =
        device.configurationValue == kATConfigurationValue &&
        device.interfaceNumber == kATInterfaceNumber &&
        device.alternateSetting == 0 &&
        device.interfaceClass == 0xff &&
        device.interfaceSubClass == 0x00 &&
        device.interfaceProtocol == 0x00 &&
        interfaceDescriptor->bNumEndpoints == 3;

    NSMutableArray<EC20USBEndpointInfo *> *endpoints = [NSMutableArray array];
    NSUInteger bulkInCount = 0;
    NSUInteger bulkOutCount = 0;
    BOOL endpointMetadataValid = YES;
    uint8_t foundBulkIn = 0;
    uint8_t foundBulkOut = 0;

    const IOUSBDescriptorHeader *cursor = NULL;
    const IOUSBEndpointDescriptor *endpoint;
    while ((endpoint = IOUSBGetNextEndpointDescriptor(
                configuration, interfaceDescriptor, cursor)) != NULL) {
        cursor = (const IOUSBDescriptorHeader *)endpoint;

        EC20USBEndpointInfo *info = [[EC20USBEndpointInfo alloc] init];
        info.address = IOUSBGetEndpointAddress(endpoint);
        info.direction = IOUSBGetEndpointDirection(endpoint);
        info.type = IOUSBGetEndpointType(endpoint);
        info.maxPacketSize = USBToHost16(endpoint->wMaxPacketSize) &
                             kIOUSBEndpointDescriptorPacketSize;
        [endpoints addObject:info];

        if (IOUSBGetEndpointNumber(endpoint) == 0 ||
            info.maxPacketSize == 0 || info.maxPacketSize > 1024) {
            endpointMetadataValid = NO;
        }

        if (info.type != kIOUSBEndpointTypeBulk) {
            continue;
        }
        if (info.direction == kIOUSBEndpointDirectionIn) {
            bulkInCount++;
            foundBulkIn = info.address;
        } else {
            bulkOutCount++;
            foundBulkOut = info.address;
        }
    }
    device.endpoints = endpoints;

    BOOL valid = descriptorValid && endpointMetadataValid &&
                 endpoints.count == interfaceDescriptor->bNumEndpoints &&
                 bulkInCount == 1 && bulkOutCount == 1;
    if (!valid) {
        if (error != NULL) {
            *error = TransportError(
                EC20USBATTransportErrorEndpointLayout,
                @"接口 2 描述符不符合安全断言 "
                 "(config=1, if=2, alt=0, ff/00/00, 3 endpoints, "
                 "exactly one bulk IN/OUT)",
                nil,
                nil);
        }
        return NO;
    }

    if (bulkInAddress != NULL) {
        *bulkInAddress = foundBulkIn;
    }
    if (bulkOutAddress != NULL) {
        *bulkOutAddress = foundBulkOut;
    }
    return YES;
}

@implementation EC20USBATTransport

+ (NSArray<EC20USBATDevice *> *)enumerateDevicesWithError:(NSError **)error
{
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = CreateInterfaceIterator(&iterator);
    if (kr != kIOReturnSuccess) {
        if (error != NULL) {
            *error = TransportError(
                EC20USBATTransportErrorEnumeration,
                [NSString stringWithFormat:@"枚举 USB 接口失败: 0x%08x", kr],
                nil,
                @{EC20USBATIOReturnErrorKey: @((uint32_t)kr)});
        }
        return nil;
    }

    NSMutableArray<EC20USBATDevice *> *devices = [NSMutableArray array];
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        [devices addObject:DeviceFromService(service)];
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return devices;
}

+ (instancetype)openWithSelector:(EC20USBATDeviceSelector *)selector
                            error:(NSError **)error
{
    if (selector == nil) {
        selector = [EC20USBATDeviceSelector anyDevice];
    }

    EC20USBATDevice *device = nil;
    NSError *selectionError = nil;
    io_service_t service = CopySelectedService(selector, &device, &selectionError);
    if (service == IO_OBJECT_NULL) {
        if (error != NULL) {
            *error = selectionError;
        }
        return nil;
    }

    // IOUSBHostObjectInitOptionsNone is intentional: never capture or seize a
    // device/interface from another owner.
    NSError *openError = nil;
    IOUSBHostInterface *usbInterface = [[IOUSBHostInterface alloc]
        initWithIOService:service
                  options:IOUSBHostObjectInitOptionsNone
                    queue:nil
                    error:&openError
          interestHandler:nil];
    IOObjectRelease(service);
    if (usbInterface == nil) {
        if (error != NULL) {
            *error = TransportError(EC20USBATTransportErrorInterfaceOpen,
                                    @"无法独占打开接口 2",
                                    openError,
                                    nil);
        }
        return nil;
    }

    uint8_t bulkInAddress = 0;
    uint8_t bulkOutAddress = 0;
    NSError *layoutError = nil;
    if (!PopulateAndValidateEndpoints(usbInterface,
                                      device,
                                      &bulkInAddress,
                                      &bulkOutAddress,
                                      &layoutError)) {
        [usbInterface destroy];
        if (error != NULL) {
            *error = layoutError;
        }
        return nil;
    }

    NSError *pipeError = nil;
    IOUSBHostPipe *bulkIn = [usbInterface copyPipeWithAddress:bulkInAddress
                                                       error:&pipeError];
    if (bulkIn == nil) {
        [usbInterface destroy];
        if (error != NULL) {
            *error = TransportError(EC20USBATTransportErrorEndpointLayout,
                                    @"创建 bulk IN pipe 失败",
                                    pipeError,
                                    nil);
        }
        return nil;
    }

    pipeError = nil;
    IOUSBHostPipe *bulkOut = [usbInterface copyPipeWithAddress:bulkOutAddress
                                                        error:&pipeError];
    if (bulkOut == nil) {
        bulkIn = nil;
        [usbInterface destroy];
        if (error != NULL) {
            *error = TransportError(EC20USBATTransportErrorEndpointLayout,
                                    @"创建 bulk OUT pipe 失败",
                                    pipeError,
                                    nil);
        }
        return nil;
    }

    EC20USBATTransport *transport = [[self alloc] init];
    transport.device = device;
    transport.bulkInAddress = bulkInAddress;
    transport.bulkOutAddress = bulkOutAddress;
    transport.usbInterface = usbInterface;
    transport.bulkIn = bulkIn;
    transport.bulkOut = bulkOut;
    return transport;
}

+ (NSString *)decodeResponseData:(NSData *)data
{
    NSString *text = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    if (text == nil) {
        text = [[NSString alloc] initWithData:data
                                     encoding:NSISOLatin1StringEncoding];
    }
    return text != nil ? text : @"";
}

+ (EC20USBATTerminalState)terminalStateForResponseData:(NSData *)data
{
    NSString *text = [self decodeResponseData:data];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:trimSet];
        if ([line isEqualToString:@"OK"]) {
            return EC20USBATTerminalOK;
        }
        if ([line isEqualToString:@"ERROR"] ||
            [line hasPrefix:@"+CME ERROR:"] ||
            [line hasPrefix:@"+CMS ERROR:"]) {
            return EC20USBATTerminalError;
        }
    }
    return EC20USBATTerminalPending;
}

- (BOOL)drainStaleInputWithTraceHandler:(EC20USBATTraceHandler)traceHandler
                                  error:(NSError **)error
{
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime +
                              kDrainDeadlineSeconds;
    NSUInteger totalBytes = 0;

    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining < kDrainQuietSeconds) {
            break;
        }

        NSMutableData *rx = [NSMutableData dataWithLength:4096];
        NSUInteger bytesTransferred = 0;
        NSError *readError = nil;
        BOOL read = [self.bulkIn sendIORequestWithData:rx
                                      bytesTransferred:&bytesTransferred
                                     completionTimeout:kDrainQuietSeconds
                                                 error:&readError];
        if (!read) {
            if (IsTimeoutError(readError)) {
                return YES;
            }
            if (error != NULL) {
                *error = TransportError(EC20USBATTransportErrorUSBRead,
                                        @"排空 bulk IN 失败",
                                        readError,
                                        nil);
            }
            return NO;
        }
        if (bytesTransferred > rx.length) {
            if (error != NULL) {
                *error = TransportError(
                    EC20USBATTransportErrorUSBRead,
                    [NSString stringWithFormat:@"排空读取返回越界长度: %lu > %lu",
                        (unsigned long)bytesTransferred,
                        (unsigned long)rx.length],
                    nil,
                    nil);
            }
            return NO;
        }
        if (bytesTransferred == 0) {
            continue;
        }
        if (totalBytes > kMaxResponseBytes - bytesTransferred) {
            if (error != NULL) {
                *error = TransportError(
                    EC20USBATTransportErrorUSBRead,
                    [NSString stringWithFormat:
                        @"排空数据超过 %lu bytes，拒绝发送新命令",
                        (unsigned long)kMaxResponseBytes],
                    nil,
                    nil);
            }
            return NO;
        }

        totalBytes += bytesTransferred;
        if (traceHandler != nil) {
            traceHandler(EC20USBATTraceStaleInput,
                         [NSData dataWithBytes:rx.bytes length:bytesTransferred]);
        }
    }

    if (error != NULL) {
        *error = TransportError(
            EC20USBATTransportErrorUSBRead,
            [NSString stringWithFormat:
                @"bulk IN 在 %.2f 秒内没有出现静默窗口，拒绝发送新命令",
                kDrainDeadlineSeconds],
            nil,
            nil);
    }
    return NO;
}

static BOOL IsValidWireCommand(NSString *command)
{
    if (command.length == 0) {
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

- (BOOL)executeCommand:(NSString *)command
              response:(NSData **)response
          terminalState:(EC20USBATTerminalState *)terminalState
           traceHandler:(EC20USBATTraceHandler)traceHandler
                  error:(NSError **)error
{
    if (response != NULL) {
        *response = [NSData data];
    }
    if (terminalState != NULL) {
        *terminalState = EC20USBATTerminalPending;
    }
    if (!IsValidWireCommand(command)) {
        if (error != NULL) {
            *error = TransportError(
                EC20USBATTransportErrorInvalidCommand,
                @"AT 命令必须是非空、无控制字符的可打印 ASCII",
                nil,
                nil);
        }
        return NO;
    }
    if (self.usbInterface == nil || self.bulkIn == nil || self.bulkOut == nil) {
        if (error != NULL) {
            *error = TransportError(EC20USBATTransportErrorInterfaceOpen,
                                    @"接口 2 未打开或已经关闭",
                                    nil,
                                    nil);
        }
        return NO;
    }

    NSError *drainError = nil;
    if (![self drainStaleInputWithTraceHandler:traceHandler error:&drainError]) {
        if (error != NULL) {
            *error = drainError;
        }
        return NO;
    }

    NSString *wireCommand = [command stringByAppendingString:@"\r"];
    NSMutableData *tx = [[wireCommand dataUsingEncoding:NSASCIIStringEncoding]
                         mutableCopy];
    if (traceHandler != nil) {
        traceHandler(EC20USBATTraceCommandReady,
                     [command dataUsingEncoding:NSASCIIStringEncoding]);
    }
    NSUInteger bytesTransferred = 0;
    NSError *writeError = nil;
    BOOL wrote = [self.bulkOut sendIORequestWithData:tx
                                    bytesTransferred:&bytesTransferred
                                   completionTimeout:1.0
                                               error:&writeError];
    if (!wrote || bytesTransferred != tx.length) {
        if (error != NULL) {
            NSString *description = !wrote
                ? @"bulk OUT 失败"
                : [NSString stringWithFormat:@"bulk OUT 短写: %lu/%lu bytes",
                    (unsigned long)bytesTransferred, (unsigned long)tx.length];
            *error = TransportError(EC20USBATTransportErrorUSBWrite,
                                    description,
                                    writeError,
                                    nil);
        }
        return NO;
    }

    NSMutableData *received = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime +
                              kCommandDeadlineSeconds;
    EC20USBATTerminalState state = EC20USBATTerminalPending;

    while (NSProcessInfo.processInfo.systemUptime < deadline &&
           state == EC20USBATTerminalPending) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        NSTimeInterval timeout = remaining > 0.001 ? remaining : 0.001;
        if (timeout > kReadSliceSeconds) {
            timeout = kReadSliceSeconds;
        }

        NSMutableData *rx = [NSMutableData dataWithLength:4096];
        bytesTransferred = 0;
        NSError *readError = nil;
        BOOL read = [self.bulkIn sendIORequestWithData:rx
                                      bytesTransferred:&bytesTransferred
                                     completionTimeout:timeout
                                                 error:&readError];
        if (!read) {
            if (IsTimeoutError(readError)) {
                continue;
            }
            if (response != NULL) {
                *response = [received copy];
            }
            if (error != NULL) {
                *error = TransportError(EC20USBATTransportErrorUSBRead,
                                        @"bulk IN 失败",
                                        readError,
                                        nil);
            }
            return NO;
        }
        if (bytesTransferred == 0) {
            continue;
        }
        if (bytesTransferred > rx.length) {
            if (response != NULL) {
                *response = [received copy];
            }
            if (error != NULL) {
                *error = TransportError(
                    EC20USBATTransportErrorUSBRead,
                    [NSString stringWithFormat:@"bulk IN 返回越界长度: %lu > %lu",
                        (unsigned long)bytesTransferred,
                        (unsigned long)rx.length],
                    nil,
                    nil);
            }
            return NO;
        }
        if (received.length > kMaxResponseBytes - bytesTransferred) {
            if (response != NULL) {
                *response = [received copy];
            }
            if (error != NULL) {
                *error = TransportError(
                    EC20USBATTransportErrorUSBRead,
                    [NSString stringWithFormat:
                        @"单条 AT 响应超过 %lu bytes，终止读取",
                        (unsigned long)kMaxResponseBytes],
                    nil,
                    nil);
            }
            return NO;
        }

        NSData *chunk = [NSData dataWithBytes:rx.bytes length:bytesTransferred];
        if (traceHandler != nil) {
            traceHandler(EC20USBATTraceResponse, chunk);
        }
        [received appendData:chunk];
        state = [[self class] terminalStateForResponseData:received];
    }

    if (response != NULL) {
        *response = [received copy];
    }
    if (terminalState != NULL) {
        *terminalState = state;
    }
    if (state == EC20USBATTerminalOK) {
        return YES;
    }

    if (error != NULL) {
        if (state == EC20USBATTerminalError) {
            *error = TransportError(EC20USBATTransportErrorModem,
                                    @"模块返回显式 ERROR",
                                    nil,
                                    nil);
        } else {
            *error = TransportError(
                EC20USBATTransportErrorUSBRead,
                [NSString stringWithFormat:
                    @"等待终止行超时（%.1f 秒，已收到 %lu bytes）",
                    kCommandDeadlineSeconds, (unsigned long)received.length],
                nil,
                nil);
        }
    }
    return NO;
}

- (void)close
{
    self.bulkIn = nil;
    self.bulkOut = nil;
    if (self.usbInterface != nil) {
        [self.usbInterface destroy];
        self.usbInterface = nil;
    }
}

- (void)dealloc
{
    [self close];
}

@end
