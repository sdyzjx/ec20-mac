#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const EC20PTYBridgeErrorDomain;

typedef NS_ERROR_ENUM(EC20PTYBridgeErrorDomain, EC20PTYBridgeErrorCode) {
    EC20PTYBridgeErrorInvalidHandler = 1,
    EC20PTYBridgeErrorPTYCreation,
    EC20PTYBridgeErrorPTYConfiguration,
    EC20PTYBridgeErrorInvalidUnsolicitedData,
    EC20PTYBridgeErrorNotRunning,
    EC20PTYBridgeErrorWriteFailed,
    EC20PTYBridgeErrorSelfTest,
};

/// Called serially on the bridge's private worker thread. `command` contains
/// printable ASCII without its CR/LF terminator. Returning nil produces the
/// standard "\r\nERROR\r\n" response. The returned bytes otherwise pass
/// through to the PTY unchanged.
typedef NSData * _Nullable (^EC20PTYCommandHandler)(NSString *command);

/// Identifies commands that require a modem prompt followed by a raw payload.
/// The bridge emits a standard "> " prompt, collects bytes through Ctrl-Z,
/// then calls the interactive handler with Ctrl-Z removed.
typedef BOOL (^EC20PTYInteractiveCommandMatcher)(NSString *command);
typedef NSData * _Nullable (^EC20PTYInteractiveCommandHandler)(
    NSString *command,
    NSData *followUp);

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

/// Extended constructor for prompt-driven operations such as AT+CMGS. Normal
/// commands continue to use `handler`; interactive payloads are bounded and
/// cannot be interleaved with another command.
+ (nullable instancetype)startWithCommandHandler:(EC20PTYCommandHandler)handler
                       interactiveCommandMatcher:(nullable EC20PTYInteractiveCommandMatcher)matcher
                       interactiveCommandHandler:(nullable EC20PTYInteractiveCommandHandler)interactiveHandler
                                           error:(NSError **)error;

/// Writes one already-framed unsolicited modem record to the PTY. This is
/// used by deterministic mock tests; callers must include CR/LF framing.
/// Command responses and unsolicited writes are serialized byte-for-byte.
- (BOOL)injectUnsolicitedData:(NSData *)data error:(NSError **)error;

/// Wakes the worker, waits for it to finish, and closes every PTY/pipe fd.
/// Calling stop more than once is safe.
- (void)stop;

/// Exercises framing, fragmented input, batched commands, and overflow
/// recovery with an injected handler. This method never accesses USB.
+ (BOOL)runSelfTestsWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
