#import <Foundation/Foundation.h>

#import "EC20IPCProtocol.h"
#import "EC20PTYBridge.h"
#import "EC20USBATTransport.h"

#import <IOKit/IOReturn.h>

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static NSString * const kEC20DServerVersion = @"0.1.0";
static const NSUInteger kATMaximumCommandBytes = 4096;
static const NSUInteger kATTransportMaximumResponseBytes = 64 * 1024;
static const NSUInteger kATTransportTimeoutMilliseconds = 3000;

static volatile sig_atomic_t gTerminationRequested = 0;

static void HandleTerminationSignal(int signalNumber)
{
    (void)signalNumber;
    gTerminationRequested = 1;
}

static void PrintUsage(FILE *stream, const char *program)
{
    fprintf(stream,
            "Usage: %s [--socket PATH] [--mock] [--max-requests N] [--pty]\n"
            "          [--pty-location-id ID]\n"
            "          [--allow-arbitrary-at] [--self-test]\n"
            "\n"
            "  --socket PATH          Unix socket path (default: $TMPDIR/ec20d.sock)\n"
            "  --mock                 Do not access USB; expose one deterministic modem\n"
            "  --max-requests N       Exit after N records (0 means unlimited)\n"
            "  --pty                  Publish the selected AT interface through a PTY\n"
            "  --pty-location-id ID   Select PTY modem by USB location ID (for example 0x03120000)\n"
            "  --allow-arbitrary-at   Disable the read-only AT command policy\n"
            "  --self-test            Run deterministic checks without accessing USB\n",
            program);
}

static BOOL ParseUnsignedArgument(const char *text, uint64_t *value)
{
    if (text == NULL || text[0] == '\0' || text[0] == '-') {
        return NO;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0') {
        return NO;
    }
    if (value != NULL) {
        *value = (uint64_t)parsed;
    }
    return YES;
}

static BOOL ParseLocationID(const char *text, uint32_t *value)
{
    if (text == NULL || text[0] == '\0' || text[0] == '-') {
        return NO;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text, &end, 0);
    if (errno == ERANGE || end == text || end == NULL || *end != '\0' ||
        parsed > UINT32_MAX) {
        return NO;
    }
    if (value != NULL) {
        *value = (uint32_t)parsed;
    }
    return YES;
}

static BOOL IsJSONBoolean(id value)
{
    return value != nil &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSString *StringParameter(NSDictionary<NSString *, id> *params,
                                 NSString *name)
{
    id value = params[name];
    return [value isKindOfClass:[NSString class]] && [value length] > 0
        ? value
        : nil;
}

static BOOL UnsignedIntegerParameter(NSDictionary<NSString *, id> *params,
                                     NSString *name,
                                     uint64_t *value)
{
    id object = params[name];
    if (![object isKindOfClass:[NSNumber class]] || IsJSONBoolean(object)) {
        return NO;
    }
    double number = [object doubleValue];
    // JSON numbers above 2^53 cannot be represented as exact integers by
    // NSNumber's double bridge. Protocol counters in this release are tiny;
    // reject ambiguous values instead of allowing an overflow/wraparound.
    if (!isfinite(number) || number < 0 || floor(number) != number ||
        number > 9007199254740991.0) {
        return NO;
    }
    if (value != NULL) {
        *value = [object unsignedLongLongValue];
    }
    return YES;
}

static BOOL OptionalUnsignedIntegerParameter(NSDictionary<NSString *, id> *params,
                                             NSString *name,
                                             uint64_t defaultValue,
                                             uint64_t *value)
{
    if (params[name] == nil) {
        if (value != NULL) {
            *value = defaultValue;
        }
        return YES;
    }
    return UnsignedIntegerParameter(params, name, value);
}

static BOOL IsReadOnlyATCommand(NSString *command)
{
    NSString *upper = [command uppercaseString];
    static NSSet<NSString *> *exactCommands;
    static NSRegularExpression *qcfgQuery;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactCommands = [NSSet setWithArray:@[
            @"AT",
            @"ATI",
            @"AT+GMR",
            @"AT+CGSN",
            @"AT+CSQ",
            @"AT+CPIN?",
            @"AT+COPS?",
            @"AT+QCFG?",
            @"AT+QCFG=?",
        ]];
        qcfgQuery = [NSRegularExpression
            regularExpressionWithPattern:@"^AT\\+QCFG=\\\"[A-Z0-9_.-]+\\\"$"
                                  options:0
                                    error:NULL];
    });

    if ([exactCommands containsObject:upper]) {
        return YES;
    }
    NSRange entireCommand = NSMakeRange(0, upper.length);
    return [qcfgQuery firstMatchInString:upper options:0 range:entireCommand] != nil;
}

// Keep the synthetic PTY useful to clients that parse modem identity and
// status, rather than only checking for a terminal OK. This responder is
// reachable exclusively through --mock; real USB transactions continue to
// use EC20USBATTransport below.
static NSData *MockPTYResponseForCommand(NSString *command)
{
    NSString *upper = [command uppercaseString];
    NSString *payload = nil;
    if ([upper isEqualToString:@"ATI"]) {
        payload = @"Quectel\r\nEC20F-MOCK\r\nRevision: MOCK-1";
    } else if ([upper isEqualToString:@"AT+GMR"]) {
        payload = @"MOCK-1";
    } else if ([upper isEqualToString:@"AT+CGSN"]) {
        payload = @"867530900000001";
    } else if ([upper isEqualToString:@"AT+CSQ"]) {
        payload = @"+CSQ: 20,99";
    } else if ([upper isEqualToString:@"AT+CPIN?"]) {
        payload = @"+CPIN: READY";
    } else if ([upper isEqualToString:@"AT+COPS?"]) {
        payload = @"+COPS: 0,0,\"EC20D MOCK\",7";
    } else if ([upper isEqualToString:@"AT+QCFG=\"USBNET\""]) {
        payload = @"+QCFG: \"usbnet\",0";
    }

    NSString *mockText = payload == nil
        ? [NSString stringWithFormat:@"\r\n%@\r\r\nOK\r\n", command]
        : [NSString stringWithFormat:@"\r\n%@\r\r\n%@\r\n\r\nOK\r\n",
                                     command,
                                     payload];
    return [mockText dataUsingEncoding:NSASCIIStringEncoding];
}

static NSString *ATCommandPolicyFailure(NSString *command,
                                        BOOL allowArbitraryAT,
                                        BOOL *deniedByAllowlist)
{
    if (deniedByAllowlist != NULL) {
        *deniedByAllowlist = NO;
    }
    NSData *commandBytes = [command dataUsingEncoding:NSASCIIStringEncoding];
    if (command == nil || commandBytes == nil ||
        commandBytes.length != command.length ||
        commandBytes.length == 0 ||
        commandBytes.length > kATMaximumCommandBytes) {
        return @"command must be 1..4096 bytes of printable ASCII.";
    }
    const uint8_t *rawCommand = commandBytes.bytes;
    for (NSUInteger index = 0; index < commandBytes.length; index++) {
        if (rawCommand[index] < 0x20 || rawCommand[index] == 0x7f) {
            return @"command must be 1..4096 bytes of printable ASCII.";
        }
    }
    BOOL hasATPrefix = command.length >= 2 &&
        [[command substringToIndex:2] caseInsensitiveCompare:@"AT"] == NSOrderedSame;
    if (!hasATPrefix) {
        return @"command must begin with AT.";
    }
    if (!allowArbitraryAT && !IsReadOnlyATCommand(command)) {
        if (deniedByAllowlist != NULL) {
            *deniedByAllowlist = YES;
        }
        return @"The command is not in the read-only AT allowlist.";
    }
    return nil;
}

static NSString *InstanceIdentifierForLocation(uint32_t locationID)
{
    return [NSString stringWithFormat:@"usb-%08x-1", locationID];
}

static NSString *TerminalStateName(EC20USBATTerminalState state)
{
    switch (state) {
        case EC20USBATTerminalOK:
            return @"ok";
        case EC20USBATTerminalError:
            return @"error";
        case EC20USBATTerminalPending:
            return @"pending";
    }
    return @"pending";
}

static NSDictionary<NSString *, id> *DeviceObject(uint32_t locationID,
                                                   uint64_t registryID,
                                                   BOOL mock,
                                                   NSString *ptyPath)
{
    NSString *instanceID = InstanceIdentifierForLocation(locationID);
    NSString *location = [NSString stringWithFormat:@"%08x", locationID];
    return @{
        @"instance_id": instanceID,
        @"generation": @1,
        @"stable_id": [NSNull null],
        @"identity": @{
            @"imei": [NSNull null],
            @"usb_serial_number": [NSNull null],
            @"usb_location_id": location,
            @"vendor_id": @0x2c7c,
            @"product_id": @0x0125,
            @"vendor_id_hex": @"2c7c",
            @"product_id_hex": @"0125",
            @"manufacturer": @"Quectel",
            @"model": mock ? @"EC20F-MOCK" : [NSNull null],
            @"firmware": mock ? @"MOCK-1" : [NSNull null],
        },
        @"lifecycle": @{
            @"state": @"ready",
            @"reason": [NSNull null],
        },
        @"usb": @{
            @"configuration": @1,
            @"at_interface_number": @2,
            @"network_interface_number": @4,
            @"registry_id": registryID == 0
                ? (id)[NSNull null]
                : [NSString stringWithFormat:@"%llu", registryID],
        },
        @"at": @{
            @"transport": ptyPath != nil ? @"pty" : @"rpc",
            @"path": ptyPath != nil ? ptyPath : (id)[NSNull null],
            @"rpc_device_id": ptyPath != nil ? (id)[NSNull null] : instanceID,
            @"interface_number": @2,
            @"ownership": ptyPath != nil
                ? @"cooperative_single_client"
                : @"exclusive_client",
            @"available": @YES,
        },
        @"network": @{
            @"mode": @"unknown",
            @"data_plane": [NSNull null],
            @"control_plane": @"at",
            @"interface_name": [NSNull null],
            @"interface_index": [NSNull null],
            @"link_state": @"unknown",
            @"addresses": @[],
            @"managed_by": [NSNull null],
        },
        @"capabilities": @[
            @"management.at",
        ],
    };
}

static BOOL WriteAll(int fileDescriptor, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t written = write(fileDescriptor, bytes + offset, data.length - offset);
        if (written > 0) {
            offset += (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR && !gTerminationRequested) {
            continue;
        }
        return NO;
    }
    return YES;
}

static NSData *WireErrorResponse(NSString *identifier,
                                 NSString *code,
                                 NSString *message,
                                 BOOL retryable)
{
    NSError *encodingError = nil;
    NSData *response = EC20IPCEncodeErrorResponse(identifier,
                                                   code,
                                                   message,
                                                   retryable,
                                                   nil,
                                                   &encodingError);
    if (response == nil) {
        fprintf(stderr, "ec20d: could not encode an error response: %s\n",
                encodingError.localizedDescription.UTF8String);
    }
    return response;
}

static NSString *TransportWireCode(NSError *error, BOOL opening)
{
    if (![error.domain isEqualToString:EC20USBATTransportErrorDomain]) {
        return EC20IPCErrorCodeTransportError;
    }

    switch ((EC20USBATTransportErrorCode)error.code) {
        case EC20USBATTransportErrorDeviceSelection: {
            NSNumber *count = error.userInfo[EC20USBATMatchedDeviceCountErrorKey];
            return count != nil && count.unsignedIntegerValue == 0
                ? (opening ? EC20IPCErrorCodeNotFound
                           : EC20IPCErrorCodeDeviceRemoved)
                : EC20IPCErrorCodeBusy;
        }
        case EC20USBATTransportErrorInterfaceOpen:
            return opening ? EC20IPCErrorCodeBusy
                           : EC20IPCErrorCodeDeviceRemoved;
        case EC20USBATTransportErrorUSBRead:
            if ([error.localizedDescription localizedCaseInsensitiveContainsString:@"timeout"] ||
                [error.localizedDescription containsString:@"超时"]) {
                return EC20IPCErrorCodeTimeout;
            }
            return EC20IPCErrorCodeTransportError;
        case EC20USBATTransportErrorInvalidCommand:
            return EC20IPCErrorCodeInvalidRequest;
        case EC20USBATTransportErrorEnumeration:
        case EC20USBATTransportErrorEndpointLayout:
        case EC20USBATTransportErrorUSBWrite:
        case EC20USBATTransportErrorModem:
            return EC20IPCErrorCodeTransportError;
    }
    return EC20IPCErrorCodeTransportError;
}

@interface EC20DConnectionSession : NSObject

@property(nonatomic, copy, nullable) NSString *leaseID;
@property(nonatomic, copy, nullable) NSString *instanceID;
@property(nonatomic) uint64_t generation;
@property(nonatomic, strong, nullable) EC20USBATTransport *transport;

- (void)releaseLease;

@end

@implementation EC20DConnectionSession

- (void)releaseLease
{
    [self.transport close];
    self.transport = nil;
    self.leaseID = nil;
    self.instanceID = nil;
    self.generation = 0;
}

- (void)dealloc
{
    [self releaseLease];
}

@end

@interface EC20Daemon : NSObject

@property(nonatomic, copy) NSString *socketPath;
@property(nonatomic) BOOL mock;
@property(nonatomic) BOOL allowArbitraryAT;
@property(nonatomic) BOOL ptyEnabled;
@property(nonatomic, strong, nullable) NSNumber *ptyLocationID;
@property(nonatomic, strong, nullable) EC20PTYBridge *ptyBridge;
@property(nonatomic) uint32_t selectedPTYLocationID;
@property(nonatomic) uint64_t selectedPTYRegistryID;
@property(nonatomic) uint64_t maximumRequests;
@property(nonatomic) uint64_t requestCount;
@property(nonatomic, copy) NSString *daemonInstanceID;
@property(nonatomic) int listenFileDescriptor;
@property(nonatomic) BOOL ownsSocketPath;
@property(nonatomic) dev_t socketDevice;
@property(nonatomic) ino_t socketInode;

- (BOOL)runWithError:(NSError **)error;

@end


static NSError *DaemonError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:@"EC20DaemonErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL SocketPathIsActive(const struct sockaddr_un *address,
                               socklen_t addressLength)
{
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe < 0) {
        return YES;
    }
    int result = connect(probe, (const struct sockaddr *)address, addressLength);
    int savedErrno = errno;
    close(probe);
    if (result == 0) {
        return YES;
    }
    return savedErrno != ECONNREFUSED && savedErrno != ENOENT;
}

static void RemoveSocketIfIdentityMatches(const char *path,
                                          const struct stat *expected)
{
    struct stat current;
    if (path != NULL && expected != NULL && lstat(path, &current) == 0 &&
        S_ISSOCK(current.st_mode) && current.st_uid == geteuid() &&
        current.st_dev == expected->st_dev && current.st_ino == expected->st_ino) {
        (void)unlink(path);
    }
}

@implementation EC20Daemon

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        _daemonInstanceID = NSUUID.UUID.UUIDString;
        _listenFileDescriptor = -1;
    }
    return self;
}

- (NSArray<EC20USBATDevice *> *)transportDevicesWithError:(NSError **)error
{
    if (self.mock) {
        return @[];
    }
    return [EC20USBATTransport enumerateDevicesWithError:error];
}

- (NSArray<NSDictionary<NSString *, id> *> *)deviceObjectsWithError:(NSError **)error
{
    if (self.mock) {
        return @[DeviceObject(0x03120000,
                              0,
                              YES,
                              self.ptyBridge.slavePath)];
    }

    if (self.ptyBridge != nil) {
        return @[DeviceObject(self.selectedPTYLocationID,
                              self.selectedPTYRegistryID,
                              NO,
                              self.ptyBridge.slavePath)];
    }

    NSArray<EC20USBATDevice *> *devices = [self transportDevicesWithError:error];
    if (devices == nil) {
        return nil;
    }
    devices = [devices sortedArrayUsingComparator:
        ^NSComparisonResult(EC20USBATDevice *left, EC20USBATDevice *right) {
            if (left.locationID < right.locationID) {
                return NSOrderedAscending;
            }
            if (left.locationID > right.locationID) {
                return NSOrderedDescending;
            }
            if (left.registryID < right.registryID) {
                return NSOrderedAscending;
            }
            if (left.registryID > right.registryID) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];

    NSMutableArray<NSDictionary<NSString *, id> *> *objects = [NSMutableArray array];
    for (EC20USBATDevice *device in devices) {
        [objects addObject:DeviceObject(device.locationID,
                                        device.registryID,
                                        NO,
                                        nil)];
    }
    return objects;
}

- (EC20USBATDevice *)deviceMatchingInstanceID:(NSString *)instanceID
                                         error:(NSError **)error
{
    NSArray<EC20USBATDevice *> *devices = [self transportDevicesWithError:error];
    if (devices == nil) {
        return nil;
    }
    for (EC20USBATDevice *device in devices) {
        if ([InstanceIdentifierForLocation(device.locationID) isEqualToString:instanceID]) {
            return device;
        }
    }
    return nil;
}

- (NSData *)responseForPTYCommand:(NSString *)command
{
    if (ATCommandPolicyFailure(command, self.allowArbitraryAT, NULL) != nil) {
        return nil;
    }

    if (self.mock) {
        return MockPTYResponseForCommand(command);
    }

    NSError *openError = nil;
    EC20USBATTransport *transport =
        [EC20USBATTransport openWithSelector:
            [EC20USBATDeviceSelector
                selectorWithRegistryID:self.selectedPTYRegistryID]
                                     error:&openError];
    if (transport == nil) {
        (void)openError;
        return nil;
    }

    NSMutableData *staleInput = [NSMutableData data];
    __block BOOL staleInputOverflow = NO;
    NSData *response = nil;
    EC20USBATTerminalState terminalState = EC20USBATTerminalPending;
    NSError *transportError = nil;
    BOOL succeeded = NO;
    @try {
        succeeded = [transport executeCommand:command
                                      response:&response
                                 terminalState:&terminalState
                                  traceHandler:^(EC20USBATTraceKind kind, NSData *data) {
            if (kind == EC20USBATTraceStaleInput &&
                staleInput.length + data.length <= kATTransportMaximumResponseBytes) {
                [staleInput appendData:data];
            } else if (kind == EC20USBATTraceStaleInput) {
                staleInputOverflow = YES;
            }
        }
                                         error:&transportError];
    } @finally {
        // The PTY is only a framing facade. Every transaction opens and closes
        // configuration 1, interface 2 through the fixed transport selector;
        // it never retains USB ownership and can never select interface 4.
        [transport close];
    }

    BOOL terminalError = !succeeded &&
                         terminalState == EC20USBATTerminalError &&
                         [transportError.domain isEqualToString:EC20USBATTransportErrorDomain] &&
                         transportError.code == EC20USBATTransportErrorModem;
    if ((!succeeded && !terminalError) || staleInputOverflow) {
        return nil;
    }
    if (response == nil) {
        response = [NSData data];
    }
    if (staleInput.length + response.length > kATTransportMaximumResponseBytes) {
        return nil;
    }

    NSMutableData *combined = [staleInput mutableCopy];
    [combined appendData:response];
    return combined;
}

- (BOOL)preparePTYWithError:(NSError **)error
{
    if (!self.ptyEnabled) {
        return YES;
    }
    if (self.ptyBridge != nil) {
        return YES;
    }

    uint32_t locationID = 0;
    uint64_t registryID = 0;
    if (self.mock) {
        locationID = 0x03120000;
        if (self.ptyLocationID != nil &&
            self.ptyLocationID.unsignedIntValue != locationID) {
            if (error != NULL) {
                *error = DaemonError(13,
                    @"The requested PTY location ID does not match the mock modem.");
            }
            return NO;
        }
    } else {
        NSError *enumerationError = nil;
        NSArray<EC20USBATDevice *> *devices =
            [self transportDevicesWithError:&enumerationError];
        if (devices == nil) {
            if (error != NULL) {
                *error = enumerationError != nil
                    ? enumerationError
                    : DaemonError(14, @"Could not enumerate a modem for PTY mode.");
            }
            return NO;
        }

        NSMutableArray<EC20USBATDevice *> *matches = [NSMutableArray array];
        for (EC20USBATDevice *device in devices) {
            if (self.ptyLocationID == nil ||
                device.locationID == self.ptyLocationID.unsignedIntValue) {
                [matches addObject:device];
            }
        }
        if (matches.count != 1) {
            if (error != NULL) {
                *error = DaemonError(
                    15,
                    self.ptyLocationID == nil
                        ? @"PTY mode requires exactly one EC20; use --pty-location-id when multiple modems are attached."
                        : @"The requested PTY location ID did not select exactly one EC20.");
            }
            return NO;
        }
        EC20USBATDevice *selectedDevice = matches.firstObject;
        if (selectedDevice.registryID == 0) {
            if (error != NULL) {
                *error = DaemonError(
                    17,
                    @"PTY mode could not pin the selected EC20 to an IORegistry attach identity.");
            }
            return NO;
        }
        locationID = selectedDevice.locationID;
        registryID = selectedDevice.registryID;
    }

    self.selectedPTYLocationID = locationID;
    self.selectedPTYRegistryID = registryID;
    __weak EC20Daemon *weakSelf = self;
    NSError *bridgeError = nil;
    EC20PTYBridge *bridge = [EC20PTYBridge
        startWithCommandHandler:^NSData * _Nullable(NSString *command) {
            EC20Daemon *strongSelf = weakSelf;
            return [strongSelf responseForPTYCommand:command];
        }
        error:&bridgeError];
    if (bridge == nil) {
        self.selectedPTYLocationID = 0;
        self.selectedPTYRegistryID = 0;
        if (error != NULL) {
            *error = bridgeError != nil
                ? bridgeError
                : DaemonError(16, @"Could not start the EC20 PTY bridge.");
        }
        return NO;
    }
    self.ptyBridge = bridge;
    return YES;
}

- (void)cleanupPTY
{
    [self.ptyBridge stop];
    self.ptyBridge = nil;
    self.selectedPTYLocationID = 0;
    self.selectedPTYRegistryID = 0;
}

- (void)setFailureCode:(NSString **)code
                message:(NSString **)message
              retryable:(BOOL *)retryable
                   code:(NSString *)wireCode
                message:(NSString *)wireMessage
              retryable:(BOOL)canRetry
{
    if (code != NULL) {
        *code = wireCode;
    }
    if (message != NULL) {
        *message = wireMessage;
    }
    if (retryable != NULL) {
        *retryable = canRetry;
    }
}

- (id)handleAcquire:(EC20IPCRequest *)request
            session:(EC20DConnectionSession *)session
          errorCode:(NSString **)errorCode
       errorMessage:(NSString **)errorMessage
          retryable:(BOOL *)retryable
{
    NSString *instanceID = StringParameter(request.params, @"instance_id");
    uint64_t generation = 0;
    if (instanceID == nil ||
        !UnsignedIntegerParameter(request.params, @"generation", &generation)) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeInvalidRequest
                     message:@"at.acquire requires string instance_id and integer generation."
                   retryable:NO];
        return nil;
    }
    if (generation != 1) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeDeviceRemoved
                     message:@"The requested device generation is no longer present."
                   retryable:YES];
        return nil;
    }
    if (self.ptyBridge != nil) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeBusy
                     message:@"The AT interface is owned by the PTY bridge."
                   retryable:NO];
        return nil;
    }
    if (session.leaseID != nil) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeBusy
                     message:@"This connection already owns an AT lease."
                   retryable:NO];
        return nil;
    }

    if (self.mock) {
        if (![instanceID isEqualToString:@"usb-03120000-1"]) {
            [self setFailureCode:errorCode message:errorMessage retryable:retryable
                            code:EC20IPCErrorCodeNotFound
                         message:@"The requested modem was not found."
                       retryable:YES];
            return nil;
        }
        session.leaseID = @"mock-lease-1";
    } else {
        NSError *enumerationError = nil;
        EC20USBATDevice *device = [self deviceMatchingInstanceID:instanceID
                                                           error:&enumerationError];
        if (device == nil) {
            if (enumerationError != nil) {
                [self setFailureCode:errorCode message:errorMessage retryable:retryable
                                code:TransportWireCode(enumerationError, YES)
                             message:@"Could not enumerate the requested modem."
                           retryable:YES];
            } else {
                [self setFailureCode:errorCode message:errorMessage retryable:retryable
                                code:EC20IPCErrorCodeNotFound
                             message:@"The requested modem was not found."
                           retryable:YES];
            }
            return nil;
        }

        NSError *openError = nil;
        EC20USBATTransport *transport =
            [EC20USBATTransport openWithSelector:
                [EC20USBATDeviceSelector selectorWithLocationID:device.locationID]
                                             error:&openError];
        if (transport == nil) {
            NSString *wireCode = TransportWireCode(openError, YES);
            [self setFailureCode:errorCode message:errorMessage retryable:retryable
                            code:wireCode
                         message:@"Could not acquire the modem AT interface."
                       retryable:[wireCode isEqualToString:EC20IPCErrorCodeBusy] ||
                                 [wireCode isEqualToString:EC20IPCErrorCodeNotFound]];
            return nil;
        }
        session.transport = transport;
        session.leaseID = NSUUID.UUID.UUIDString;
    }

    session.instanceID = instanceID;
    session.generation = generation;
    return @{
        @"lease_id": session.leaseID,
        @"instance_id": instanceID,
        @"generation": @(generation),
    };
}

- (BOOL)validateLeaseParameters:(EC20IPCRequest *)request
                         session:(EC20DConnectionSession *)session
                       errorCode:(NSString **)errorCode
                    errorMessage:(NSString **)errorMessage
                       retryable:(BOOL *)retryable
{
    NSString *instanceID = StringParameter(request.params, @"instance_id");
    NSString *leaseID = StringParameter(request.params, @"lease_id");
    uint64_t generation = 0;
    if (instanceID == nil || leaseID == nil ||
        !UnsignedIntegerParameter(request.params, @"generation", &generation)) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeInvalidRequest
                     message:@"AT lease operation requires instance_id, generation, and lease_id."
                   retryable:NO];
        return NO;
    }
    if (session.leaseID == nil) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeNotReady
                     message:@"This connection does not own an AT lease."
                   retryable:NO];
        return NO;
    }
    if (![session.leaseID isEqualToString:leaseID] ||
        ![session.instanceID isEqualToString:instanceID] ||
        session.generation != generation) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodePermissionDenied
                     message:@"The AT lease does not belong to this request."
                   retryable:NO];
        return NO;
    }
    return YES;
}

- (id)handleExecute:(EC20IPCRequest *)request
             session:(EC20DConnectionSession *)session
           errorCode:(NSString **)errorCode
        errorMessage:(NSString **)errorMessage
           retryable:(BOOL *)retryable
{
    if (![self validateLeaseParameters:request
                                session:session
                              errorCode:errorCode
                           errorMessage:errorMessage
                              retryable:retryable]) {
        return nil;
    }

    NSString *command = StringParameter(request.params, @"command");
    BOOL deniedByAllowlist = NO;
    NSString *policyFailure = ATCommandPolicyFailure(command,
                                                      self.allowArbitraryAT,
                                                      &deniedByAllowlist);
    if (policyFailure != nil) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:deniedByAllowlist
                            ? EC20IPCErrorCodePermissionDenied
                            : EC20IPCErrorCodeInvalidRequest
                     message:policyFailure
                   retryable:NO];
        return nil;
    }

    uint64_t timeout = 0;
    uint64_t maximumResponseBytes = 0;
    if (!OptionalUnsignedIntegerParameter(request.params,
                                          @"timeout_ms",
                                          kATTransportTimeoutMilliseconds,
                                          &timeout) ||
        !OptionalUnsignedIntegerParameter(request.params,
                                          @"max_response_bytes",
                                          kATTransportMaximumResponseBytes,
                                          &maximumResponseBytes) ||
        timeout != kATTransportTimeoutMilliseconds ||
        maximumResponseBytes == 0 ||
        maximumResponseBytes > kATTransportMaximumResponseBytes) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeInvalidRequest
                     message:@"timeout_ms must be 3000 and max_response_bytes must be 1..65536 in this release."
                   retryable:NO];
        return nil;
    }

    NSData *response = nil;
    EC20USBATTerminalState terminalState = EC20USBATTerminalPending;
    NSError *transportError = nil;
    BOOL succeeded = NO;
    if (self.mock) {
        NSString *mockText = [NSString stringWithFormat:@"\r\n%@\r\r\nOK\r\n", command];
        response = [mockText dataUsingEncoding:NSASCIIStringEncoding];
        terminalState = EC20USBATTerminalOK;
        succeeded = YES;
    } else {
        succeeded = [session.transport executeCommand:command
                                              response:&response
                                         terminalState:&terminalState
                                          traceHandler:nil
                                                 error:&transportError];
    }

    if (response == nil) {
        response = [NSData data];
    }
    if (response.length > maximumResponseBytes) {
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:EC20IPCErrorCodeTransportError
                     message:@"The AT response exceeded max_response_bytes."
                   retryable:NO];
        return nil;
    }

    // A modem terminal ERROR is a completed transaction, not a broken IPC or
    // USB transport. Preserve the exact response and terminal state for Vohive.
    BOOL terminalError = !succeeded &&
                         terminalState == EC20USBATTerminalError &&
                         [transportError.domain isEqualToString:EC20USBATTransportErrorDomain] &&
                         transportError.code == EC20USBATTransportErrorModem;
    if (!succeeded && !terminalError) {
        NSString *wireCode = TransportWireCode(transportError, NO);
        [self setFailureCode:errorCode message:errorMessage retryable:retryable
                        code:wireCode
                     message:@"The AT transaction failed."
                   retryable:[wireCode isEqualToString:EC20IPCErrorCodeTimeout] ||
                             [wireCode isEqualToString:EC20IPCErrorCodeDeviceRemoved]];
        return nil;
    }

    return @{
        @"response": [EC20USBATTransport decodeResponseData:response],
        @"response_base64": [response base64EncodedStringWithOptions:0],
        @"terminal": TerminalStateName(terminalState),
    };
}

- (id)handleRelease:(EC20IPCRequest *)request
             session:(EC20DConnectionSession *)session
           errorCode:(NSString **)errorCode
        errorMessage:(NSString **)errorMessage
           retryable:(BOOL *)retryable
{
    if (![self validateLeaseParameters:request
                                session:session
                              errorCode:errorCode
                           errorMessage:errorMessage
                              retryable:retryable]) {
        return nil;
    }
    [session releaseLease];
    return @{ @"released": @YES };
}

- (NSData *)responseForRequest:(EC20IPCRequest *)request
                        session:(EC20DConnectionSession *)session
{
    NSString *wireCode = nil;
    NSString *message = nil;
    BOOL retryable = NO;
    id result = nil;

    if ([request.method isEqualToString:EC20IPCMethodSystemHello]) {
        result = @{
            @"server": @"ec20d",
            @"server_version": kEC20DServerVersion,
            @"daemon_instance_id": self.daemonInstanceID,
            @"capabilities": self.ptyBridge != nil
                ? @[@"devices.list", @"at.pty"]
                : @[@"devices.list", @"at.rpc"],
        };
    } else if ([request.method isEqualToString:EC20IPCMethodDevicesList]) {
        NSError *listError = nil;
        NSArray<NSDictionary<NSString *, id> *> *devices =
            [self deviceObjectsWithError:&listError];
        if (devices == nil) {
            wireCode = TransportWireCode(listError, YES);
            message = @"Could not enumerate EC20 devices.";
            retryable = YES;
        } else {
            result = @{
                @"revision": @1,
                @"devices": devices,
            };
        }
    } else if ([request.method isEqualToString:EC20IPCMethodATAcquire]) {
        result = [self handleAcquire:request
                             session:session
                           errorCode:&wireCode
                        errorMessage:&message
                           retryable:&retryable];
    } else if ([request.method isEqualToString:EC20IPCMethodATExecute]) {
        result = [self handleExecute:request
                              session:session
                            errorCode:&wireCode
                         errorMessage:&message
                            retryable:&retryable];
    } else if ([request.method isEqualToString:EC20IPCMethodATRelease]) {
        result = [self handleRelease:request
                              session:session
                            errorCode:&wireCode
                         errorMessage:&message
                            retryable:&retryable];
    } else {
        wireCode = EC20IPCErrorCodeInvalidRequest;
        message = @"The requested method is not implemented by this ec20d release.";
    }

    NSError *encodingError = nil;
    NSData *response = wireCode == nil
        ? EC20IPCEncodeSuccessResponse(request.identifier, result, &encodingError)
        : EC20IPCEncodeErrorResponse(request.identifier,
                                     wireCode,
                                     message,
                                     retryable,
                                     nil,
                                     &encodingError);
    if (response == nil) {
        fprintf(stderr, "ec20d: response encoding failed: %s\n",
                encodingError.localizedDescription.UTF8String);
    }
    return response;
}

- (BOOL)requestLimitReached
{
    return self.maximumRequests != 0 &&
           self.requestCount >= self.maximumRequests;
}

- (BOOL)handleCompleteRecord:(NSData *)record
              fileDescriptor:(int)fileDescriptor
                     session:(EC20DConnectionSession *)session
{
    self.requestCount++;

    NSError *parseError = nil;
    EC20IPCRequest *request = EC20IPCRequestFromNDJSONLine(record, &parseError);
    NSData *response = nil;
    if (request == nil) {
        NSError *encodingError = nil;
        response = EC20IPCEncodeProtocolErrorResponse(nil,
                                                       parseError,
                                                       &encodingError);
        if (response == nil) {
            fprintf(stderr, "ec20d: protocol error encoding failed: %s\n",
                    encodingError.localizedDescription.UTF8String);
        }
    } else {
        response = [self responseForRequest:request session:session];
    }
    if (response == nil || !WriteAll(fileDescriptor, response)) {
        return NO;
    }
    return ![self requestLimitReached] && !gTerminationRequested;
}

- (BOOL)serveConnection:(int)fileDescriptor stopServer:(BOOL *)stopServer
{
    uid_t peerUID = (uid_t)-1;
    gid_t peerGID = (gid_t)-1;
    if (getpeereid(fileDescriptor, &peerUID, &peerGID) != 0 ||
        peerUID != geteuid()) {
        NSData *denied = WireErrorResponse(nil,
                                           EC20IPCErrorCodePermissionDenied,
                                           @"The local peer is not authorized to use ec20d.",
                                           NO);
        if (denied != nil) {
            (void)WriteAll(fileDescriptor, denied);
        }
        return YES;
    }
    (void)peerGID;

    int noSignal = 1;
    (void)setsockopt(fileDescriptor,
                     SOL_SOCKET,
                     SO_NOSIGPIPE,
                     &noSignal,
                     sizeof(noSignal));

    EC20DConnectionSession *session = [[EC20DConnectionSession alloc] init];
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[8192];

    while (!gTerminationRequested && ![self requestLimitReached]) {
        ssize_t bytesRead = read(fileDescriptor, chunk, sizeof(chunk));
        if (bytesRead == 0) {
            break;
        }
        if (bytesRead < 0) {
            if (errno == EINTR && !gTerminationRequested) {
                continue;
            }
            break;
        }
        [buffer appendBytes:chunk length:(NSUInteger)bytesRead];

        while (buffer.length > 0) {
            const uint8_t *bytes = buffer.bytes;
            const uint8_t *newline = memchr(bytes, '\n', buffer.length);
            if (newline == NULL) {
                if (buffer.length >= EC20IPCMaximumMessageBytes) {
                    self.requestCount++;
                    NSData *tooLarge = WireErrorResponse(nil,
                                                         EC20IPCErrorCodeInvalidRequest,
                                                         @"IPC message exceeds the 1 MiB limit.",
                                                         NO);
                    if (tooLarge != nil) {
                        (void)WriteAll(fileDescriptor, tooLarge);
                    }
                    if (stopServer != NULL) {
                        *stopServer = [self requestLimitReached];
                    }
                    return YES;
                }
                break;
            }

            NSUInteger recordLength = (NSUInteger)(newline - bytes) + 1;
            if (recordLength > EC20IPCMaximumMessageBytes) {
                self.requestCount++;
                NSData *tooLarge = WireErrorResponse(nil,
                                                     EC20IPCErrorCodeInvalidRequest,
                                                     @"IPC message exceeds the 1 MiB limit.",
                                                     NO);
                if (tooLarge != nil) {
                    (void)WriteAll(fileDescriptor, tooLarge);
                }
                if (stopServer != NULL) {
                    *stopServer = [self requestLimitReached];
                }
                return YES;
            }

            NSData *record = [buffer subdataWithRange:NSMakeRange(0, recordLength)];
            [buffer replaceBytesInRange:NSMakeRange(0, recordLength)
                              withBytes:NULL
                                 length:0];
            BOOL continueServing = [self handleCompleteRecord:record
                                               fileDescriptor:fileDescriptor
                                                      session:session];
            if (!continueServing) {
                if (stopServer != NULL) {
                    *stopServer = [self requestLimitReached] || gTerminationRequested;
                }
                return YES;
            }
        }
    }

    if (stopServer != NULL) {
        *stopServer = [self requestLimitReached] || gTerminationRequested;
    }
    return YES;
}

- (BOOL)prepareSocketWithError:(NSError **)error
{
    const char *path = self.socketPath.fileSystemRepresentation;
    if (path == NULL || path[0] == '\0') {
        if (error != NULL) {
            *error = DaemonError(1, @"The Unix socket path is empty or invalid.");
        }
        return NO;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    size_t pathLength = strlen(path);
    if (pathLength >= sizeof(address.sun_path)) {
        if (error != NULL) {
            *error = DaemonError(2, @"The Unix socket path is too long.");
        }
        return NO;
    }
    memcpy(address.sun_path, path, pathLength + 1);
    socklen_t addressLength = (socklen_t)(offsetof(struct sockaddr_un, sun_path) +
                                          pathLength + 1);

    struct stat existing;
    if (lstat(path, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != geteuid()) {
            if (error != NULL) {
                *error = DaemonError(
                    3,
                    @"Refusing to replace a non-socket or differently-owned socket path.");
            }
            return NO;
        }
        if (SocketPathIsActive(&address, addressLength)) {
            if (error != NULL) {
                *error = DaemonError(4, @"Another ec20d process is already listening.");
            }
            return NO;
        }
        if (unlink(path) != 0 && errno != ENOENT) {
            if (error != NULL) {
                *error = DaemonError(5, @"Could not remove the stale Unix socket.");
            }
            return NO;
        }
    } else if (errno != ENOENT) {
        if (error != NULL) {
            *error = DaemonError(6, @"Could not inspect the Unix socket path.");
        }
        return NO;
    }

    int fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fileDescriptor < 0) {
        if (error != NULL) {
            *error = DaemonError(7, @"Could not create the Unix socket.");
        }
        return NO;
    }

    mode_t previousMask = umask(0177);
    int bindResult = bind(fileDescriptor,
                          (const struct sockaddr *)&address,
                          addressLength);
    int bindErrno = errno;
    umask(previousMask);
    if (bindResult != 0) {
        close(fileDescriptor);
        if (error != NULL) {
            *error = DaemonError(
                8,
                [NSString stringWithFormat:@"Could not bind the Unix socket: %s",
                                           strerror(bindErrno)]);
        }
        return NO;
    }

    struct stat created;
    BOOL createdIdentityKnown = lstat(path, &created) == 0;
    if (!createdIdentityKnown || !S_ISSOCK(created.st_mode) ||
        created.st_uid != geteuid() || (created.st_mode & 0777) != 0600) {
        close(fileDescriptor);
        if (createdIdentityKnown) {
            RemoveSocketIfIdentityMatches(path, &created);
        }
        if (error != NULL) {
            *error = DaemonError(10, @"The created Unix socket did not pass ownership checks.");
        }
        return NO;
    }

    if (listen(fileDescriptor, 4) != 0) {
        int listenErrno = errno;
        close(fileDescriptor);
        RemoveSocketIfIdentityMatches(path, &created);
        if (error != NULL) {
            *error = DaemonError(
                11,
                [NSString stringWithFormat:@"Could not listen on the Unix socket: %s",
                                           strerror(listenErrno)]);
        }
        return NO;
    }

    self.listenFileDescriptor = fileDescriptor;
    self.ownsSocketPath = YES;
    self.socketDevice = created.st_dev;
    self.socketInode = created.st_ino;
    return YES;
}

- (void)cleanupSocket
{
    if (self.listenFileDescriptor >= 0) {
        close(self.listenFileDescriptor);
        self.listenFileDescriptor = -1;
    }
    if (!self.ownsSocketPath) {
        return;
    }

    struct stat expected;
    memset(&expected, 0, sizeof(expected));
    expected.st_dev = self.socketDevice;
    expected.st_ino = self.socketInode;
    RemoveSocketIfIdentityMatches(self.socketPath.fileSystemRepresentation, &expected);
    self.ownsSocketPath = NO;
}

- (BOOL)runWithError:(NSError **)error
{
    if (![self preparePTYWithError:error]) {
        return NO;
    }
    if (![self prepareSocketWithError:error]) {
        [self cleanupPTY];
        return NO;
    }

    fprintf(stderr, "ec20d: listening on %s%s%s\n",
            self.socketPath.fileSystemRepresentation,
            self.mock ? " (mock)" : "",
            self.ptyBridge != nil ? " (PTY)" : "");

    BOOL succeeded = YES;
    while (!gTerminationRequested && ![self requestLimitReached]) {
        int connection = accept(self.listenFileDescriptor, NULL, NULL);
        if (connection < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (!gTerminationRequested) {
                if (error != NULL) {
                    *error = DaemonError(12, @"Could not accept a local IPC connection.");
                }
                succeeded = NO;
            }
            break;
        }

        BOOL stopServer = NO;
        (void)[self serveConnection:connection stopServer:&stopServer];
        close(connection);
        if (stopServer) {
            break;
        }
    }

    [self cleanupSocket];
    [self cleanupPTY];
    return succeeded;
}

- (void)dealloc
{
    [self cleanupSocket];
    [self cleanupPTY];
}

@end

static BOOL SelfTestAssert(BOOL condition, NSString *message, NSError **error)
{
    if (condition) {
        return YES;
    }
    if (error != NULL) {
        *error = DaemonError(100, message);
    }
    return NO;
}

static BOOL RunSelfTests(NSError **error)
{
    NSError *protocolError = nil;
    if (!EC20IPCProtocolRunSelfTests(&protocolError)) {
        if (error != NULL) {
            *error = protocolError;
        }
        return NO;
    }

    NSError *bridgeError = nil;
    if (![EC20PTYBridge runSelfTestsWithError:&bridgeError]) {
        if (error != NULL) {
            *error = bridgeError;
        }
        return NO;
    }

    if (!SelfTestAssert(IsReadOnlyATCommand(@"AT") &&
                        IsReadOnlyATCommand(@"ATI") &&
                        IsReadOnlyATCommand(@"AT+QCFG=\"usbnet\"") &&
                        IsReadOnlyATCommand(@"at+csq") &&
                        !IsReadOnlyATCommand(@"AT+QCFG=\"usbnet\",1") &&
                        !IsReadOnlyATCommand(@"AT+CFUN=1,1") &&
                        !IsReadOnlyATCommand(@"AT+CMGS=1"),
                        @"The read-only AT policy self-test failed.",
                        error)) {
        return NO;
    }

    if (!SelfTestAssert(ATCommandPolicyFailure(@"AT+CFUN=1,1", YES, NULL) == nil &&
                        ATCommandPolicyFailure(@"NOT-AT", YES, NULL) != nil &&
                        ATCommandPolicyFailure(@"AT+CFUN=1,1", NO, NULL) != nil,
                        @"The arbitrary-AT prefix guard self-test failed.",
                        error)) {
        return NO;
    }

    NSDictionary<NSString *, id> *device = DeviceObject(0x03120000,
                                                         0,
                                                         YES,
                                                         nil);
    if (!SelfTestAssert([device[@"instance_id"] isEqualToString:@"usb-03120000-1"] &&
                        [device[@"generation"] isEqual:@1] &&
                        [device[@"at"][@"transport"] isEqualToString:@"rpc"] &&
                        [device[@"network"][@"mode"] isEqualToString:@"unknown"],
                        @"The deterministic mock device contract self-test failed.",
                        error)) {
        return NO;
    }

    NSDictionary<NSString *, id> *ptyDevice = DeviceObject(0x03120000,
                                                            123,
                                                            NO,
                                                            @"/dev/ttys999");
    if (!SelfTestAssert([ptyDevice[@"at"][@"transport"] isEqualToString:@"pty"] &&
                        [ptyDevice[@"at"][@"path"] isEqualToString:@"/dev/ttys999"] &&
                        [ptyDevice[@"at"][@"rpc_device_id"] isEqual:[NSNull null]] &&
                        [ptyDevice[@"at"][@"ownership"]
                            isEqualToString:@"cooperative_single_client"],
                        @"The PTY device-object self-test failed.",
                        error)) {
        return NO;
    }

    NSData *mockResponse = MockPTYResponseForCommand(@"AT");
    NSData *mockIMEIResponse = MockPTYResponseForCommand(@"AT+CGSN");
    return SelfTestAssert(
        mockResponse != nil &&
        [EC20USBATTransport terminalStateForResponseData:mockResponse] ==
            EC20USBATTerminalOK &&
        mockIMEIResponse != nil &&
        [EC20USBATTransport terminalStateForResponseData:mockIMEIResponse] ==
            EC20USBATTerminalOK &&
        [mockIMEIResponse rangeOfData:
            [@"867530900000001" dataUsingEncoding:NSASCIIStringEncoding]
                           options:0
                             range:NSMakeRange(0, mockIMEIResponse.length)].location != NSNotFound,
        @"The deterministic mock AT response self-test failed.",
        error);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *socketPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"ec20d.sock"];
        BOOL mock = NO;
        BOOL allowArbitraryAT = NO;
        BOOL ptyEnabled = NO;
        NSNumber *ptyLocationID = nil;
        BOOL selfTest = NO;
        uint64_t maximumRequests = 0;

        for (int index = 1; index < argc; index++) {
            const char *argument = argv[index];
            if (strcmp(argument, "--socket") == 0) {
                if (++index >= argc) {
                    PrintUsage(stderr, argv[0]);
                    return 64;
                }
                socketPath = [NSString stringWithUTF8String:argv[index]];
                if (socketPath == nil) {
                    fprintf(stderr, "ec20d: --socket is not valid UTF-8\n");
                    return 64;
                }
            } else if (strcmp(argument, "--mock") == 0) {
                mock = YES;
            } else if (strcmp(argument, "--max-requests") == 0) {
                if (++index >= argc ||
                    !ParseUnsignedArgument(argv[index], &maximumRequests)) {
                    PrintUsage(stderr, argv[0]);
                    return 64;
                }
            } else if (strcmp(argument, "--pty") == 0) {
                ptyEnabled = YES;
            } else if (strcmp(argument, "--pty-location-id") == 0) {
                uint32_t locationID = 0;
                if (++index >= argc ||
                    ptyLocationID != nil ||
                    !ParseLocationID(argv[index], &locationID)) {
                    PrintUsage(stderr, argv[0]);
                    return 64;
                }
                ptyLocationID = @(locationID);
            } else if (strcmp(argument, "--allow-arbitrary-at") == 0) {
                allowArbitraryAT = YES;
            } else if (strcmp(argument, "--self-test") == 0) {
                selfTest = YES;
            } else if (strcmp(argument, "--help") == 0 ||
                       strcmp(argument, "-h") == 0) {
                PrintUsage(stdout, argv[0]);
                return 0;
            } else {
                fprintf(stderr, "ec20d: unknown argument: %s\n", argument);
                PrintUsage(stderr, argv[0]);
                return 64;
            }
        }

        if (ptyLocationID != nil && !ptyEnabled) {
            fprintf(stderr, "ec20d: --pty-location-id requires --pty\n");
            PrintUsage(stderr, argv[0]);
            return 64;
        }

        if (selfTest) {
            NSError *testError = nil;
            if (!RunSelfTests(&testError)) {
                fprintf(stderr, "ec20d self-test failed: %s\n",
                        testError.localizedDescription.UTF8String);
                return 1;
            }
            printf("ec20d self-test passed (USB was not accessed)\n");
            return 0;
        }

        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = HandleTerminationSignal;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0;
        (void)sigaction(SIGINT, &action, NULL);
        (void)sigaction(SIGTERM, &action, NULL);

        struct sigaction ignorePipe;
        memset(&ignorePipe, 0, sizeof(ignorePipe));
        ignorePipe.sa_handler = SIG_IGN;
        sigemptyset(&ignorePipe.sa_mask);
        (void)sigaction(SIGPIPE, &ignorePipe, NULL);

        EC20Daemon *daemon = [[EC20Daemon alloc] init];
        daemon.socketPath = [socketPath stringByStandardizingPath];
        daemon.mock = mock;
        daemon.allowArbitraryAT = allowArbitraryAT;
        daemon.ptyEnabled = ptyEnabled;
        daemon.ptyLocationID = ptyLocationID;
        daemon.maximumRequests = maximumRequests;

        NSError *runError = nil;
        if (![daemon runWithError:&runError]) {
            fprintf(stderr, "ec20d: %s\n", runError.localizedDescription.UTF8String);
            return 1;
        }
        return 0;
    }
}
