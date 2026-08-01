#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const EC20PTYBridgeErrorDomain;

typedef NS_ERROR_ENUM(EC20PTYBridgeErrorDomain, EC20PTYBridgeErrorCode) {
    EC20PTYBridgeErrorInvalidHandler = 1,
    EC20PTYBridgeErrorPTYCreation,
    EC20PTYBridgeErrorPTYConfiguration,
    EC20PTYBridgeErrorSelfTest,
};

/// Called serially on the bridge's private worker thread. `command` contains
/// printable ASCII without its CR/LF terminator. Returning nil produces the
/// standard "\r\nERROR\r\n" response. The returned bytes otherwise pass
/// through to the PTY unchanged.
typedef NSData * _Nullable (^EC20PTYCommandHandler)(NSString *command);

/// A deliberately small experimental serial facade for the ec20d RPC-era USB
/// transport. It does not enumerate or access USB by itself.
@interface EC20PTYBridge : NSObject

/// Dynamic slave path (normally /dev/ttysXXX). It is valid until `stop`.
@property(nonatomic, copy, readonly) NSString *slavePath;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Creates a raw, owner-only PTY and starts its worker before returning.
+ (nullable instancetype)startWithCommandHandler:(EC20PTYCommandHandler)handler
                                           error:(NSError **)error;

/// Wakes the worker, waits for it to finish, and closes every PTY/pipe fd.
/// Calling stop more than once is safe.
- (void)stop;

/// Exercises framing, fragmented input, batched commands, and overflow
/// recovery with an injected handler. This method never accesses USB.
+ (BOOL)runSelfTestsWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
