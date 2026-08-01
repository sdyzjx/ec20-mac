#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const EC20USBATTransportErrorDomain;
FOUNDATION_EXPORT NSString *const EC20USBATMatchedDeviceCountErrorKey;
FOUNDATION_EXPORT NSString *const EC20USBATIOReturnErrorKey;

typedef NS_ERROR_ENUM(EC20USBATTransportErrorDomain, EC20USBATTransportErrorCode) {
    EC20USBATTransportErrorEnumeration = 1,
    EC20USBATTransportErrorDeviceSelection,
    EC20USBATTransportErrorInterfaceOpen,
    EC20USBATTransportErrorEndpointLayout,
    EC20USBATTransportErrorUSBWrite,
    EC20USBATTransportErrorUSBRead,
    EC20USBATTransportErrorModem,
    EC20USBATTransportErrorInvalidCommand,
};

typedef NS_ENUM(NSUInteger, EC20USBATTerminalState) {
    EC20USBATTerminalPending,
    EC20USBATTerminalOK,
    EC20USBATTerminalError,
};

typedef NS_ENUM(NSUInteger, EC20USBATTraceKind) {
    EC20USBATTraceStaleInput,
    EC20USBATTraceCommandReady,
    EC20USBATTraceResponse,
};

typedef void (^EC20USBATTraceHandler)(EC20USBATTraceKind kind, NSData *data);

@interface EC20USBEndpointInfo : NSObject

@property(nonatomic, readonly) uint8_t address;
@property(nonatomic, readonly) uint8_t type;
@property(nonatomic, readonly) uint8_t direction;
@property(nonatomic, readonly) uint16_t maxPacketSize;

@end

@interface EC20USBATDevice : NSObject

@property(nonatomic, readonly) uint64_t registryID;
@property(nonatomic, readonly) uint32_t locationID;
@property(nonatomic, copy, readonly) NSString *registryPath;

// These fields are populated after the interface has been opened and its
// descriptors have passed the fixed interface-2 safety checks.
@property(nonatomic, readonly) uint8_t configurationValue;
@property(nonatomic, readonly) uint8_t interfaceNumber;
@property(nonatomic, readonly) uint8_t alternateSetting;
@property(nonatomic, readonly) uint8_t interfaceClass;
@property(nonatomic, readonly) uint8_t interfaceSubClass;
@property(nonatomic, readonly) uint8_t interfaceProtocol;
@property(nonatomic, copy, readonly) NSArray<EC20USBEndpointInfo *> *endpoints;

@end

@interface EC20USBATDeviceSelector : NSObject

@property(nonatomic, strong, readonly, nullable) NSNumber *registryID;
@property(nonatomic, strong, readonly, nullable) NSNumber *locationID;

+ (instancetype)anyDevice;
+ (instancetype)selectorWithRegistryID:(uint64_t)registryID;
+ (instancetype)selectorWithLocationID:(uint32_t)locationID;

@end

@interface EC20USBATTransport : NSObject

@property(nonatomic, strong, readonly) EC20USBATDevice *device;
@property(nonatomic, readonly) uint8_t bulkInAddress;
@property(nonatomic, readonly) uint8_t bulkOutAddress;

// Enumeration is deliberately restricted to Quectel 2c7c:0125,
// configuration 1, interface 2. Interface 4 is never included.
+ (nullable NSArray<EC20USBATDevice *> *)enumerateDevicesWithError:(NSError **)error;

// With an "any" selector, opening succeeds only when exactly one interface 2
// exists. A concrete selector permits deterministic multi-modem operation.
// The implementation never uses capture/seize options.
+ (nullable instancetype)openWithSelector:(EC20USBATDeviceSelector *)selector
                                    error:(NSError **)error;

+ (NSString *)decodeResponseData:(NSData *)data;
+ (EC20USBATTerminalState)terminalStateForResponseData:(NSData *)data;

// Commands must be printable ASCII without CR/LF. Policy allowlists belong to
// the caller. The transport appends exactly one carriage return, drains stale
// input, and reads until an exact terminal line or the fixed deadline.
- (BOOL)executeCommand:(NSString *)command
              response:(NSData * _Nullable * _Nullable)response
          terminalState:(EC20USBATTerminalState * _Nullable)terminalState
           traceHandler:(nullable EC20USBATTraceHandler)traceHandler
                  error:(NSError **)error;

/// Executes a prompt-driven AT transaction. `followUp` excludes Ctrl-Z; the
/// transport waits for the modem's '>' prompt, writes the payload plus Ctrl-Z,
/// and then waits for the final OK/ERROR. The returned response contains only
/// bytes received after the prompt so the PTY facade does not emit it twice.
- (BOOL)executeInteractiveCommand:(NSString *)command
                          followUp:(NSData *)followUp
                          response:(NSData * _Nullable * _Nullable)response
                      terminalState:(EC20USBATTerminalState * _Nullable)terminalState
                       traceHandler:(nullable EC20USBATTraceHandler)traceHandler
                              error:(NSError **)error;

/// Sends a raw ESC byte to cancel a modem input transaction. This is a
/// recovery primitive only; it never targets interface 4.
- (BOOL)cancelInteractiveInputWithResponse:(NSData * _Nullable * _Nullable)response
                               traceHandler:(nullable EC20USBATTraceHandler)traceHandler
                                      error:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
