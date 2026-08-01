#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The wire schema and API advertised by every request and response.
FOUNDATION_EXPORT NSString * const EC20IPCSchema;
FOUNDATION_EXPORT NSString * const EC20IPCAPI;

/// Maximum number of bytes in one complete NDJSON record, including its newline.
FOUNDATION_EXPORT const NSUInteger EC20IPCMaximumMessageBytes;

FOUNDATION_EXPORT NSErrorDomain const EC20IPCProtocolErrorDomain;

/// NSError userInfo keys populated when the corresponding value is trustworthy.
FOUNDATION_EXPORT NSString * const EC20IPCWireErrorCodeErrorKey;
FOUNDATION_EXPORT NSString * const EC20IPCRequestIDErrorKey;

/// Methods implemented by the first ec20d/Vohive protocol surface.
FOUNDATION_EXPORT NSString * const EC20IPCMethodSystemHello;
FOUNDATION_EXPORT NSString * const EC20IPCMethodDevicesList;
FOUNDATION_EXPORT NSString * const EC20IPCMethodATAcquire;
FOUNDATION_EXPORT NSString * const EC20IPCMethodATExecute;
FOUNDATION_EXPORT NSString * const EC20IPCMethodATRelease;
FOUNDATION_EXPORT NSString * const EC20IPCMethodMockURCInject;

/// Stable error codes used in the wire-level `error.code` field.
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeInvalidRequest;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeUnsupportedAPI;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeNotFound;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeNotReady;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeBusy;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodePermissionDenied;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeTimeout;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeDeviceRemoved;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeTransportError;
FOUNDATION_EXPORT NSString * const EC20IPCErrorCodeResyncRequired;

typedef NS_ERROR_ENUM(EC20IPCProtocolErrorDomain, EC20IPCProtocolError) {
    EC20IPCProtocolErrorInvalidUTF8 = 1,
    EC20IPCProtocolErrorMalformedJSON = 2,
    EC20IPCProtocolErrorInvalidEnvelope = 3,
    EC20IPCProtocolErrorMessageTooLarge = 4,
    EC20IPCProtocolErrorUnsupportedSchema = 5,
    EC20IPCProtocolErrorUnsupportedAPIVersion = 6,
    EC20IPCProtocolErrorInvalidResponse = 7,
    EC20IPCProtocolErrorEncodingFailed = 8,
    EC20IPCProtocolErrorSelfTestFailed = 9,
};

/// A validated request envelope. Unknown top-level fields are deliberately not
/// retained so a newer peer can add fields without changing this API.
@interface EC20IPCRequest : NSObject

@property(nonatomic, copy, readonly) NSString *schema;
@property(nonatomic, copy, readonly) NSString *apiVersion;
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *method;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *params;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// Parses exactly one complete NDJSON request record. The final LF (or CRLF) is
/// optional because callers commonly remove framing before invoking the parser.
/// Embedded line breaks and multiple records are rejected. Requests must contain
/// string `schema`, `api_version`, `id`, and `method` fields plus an object
/// `params` field.
FOUNDATION_EXPORT EC20IPCRequest * _Nullable
EC20IPCRequestFromNDJSONLine(NSData *line, NSError **error);

/// Serializes a successful response as one LF-terminated NDJSON record.
/// A nil result is represented by JSON null.
FOUNDATION_EXPORT NSData * _Nullable
EC20IPCEncodeSuccessResponse(NSString *identifier,
                             id _Nullable result,
                             NSError **error);

/// Serializes an error response as one LF-terminated NDJSON record. `identifier`
/// may be nil when parsing failed before a trustworthy request id was available.
/// Only one of the stable EC20IPCErrorCode* constants is accepted as `code`.
FOUNDATION_EXPORT NSData * _Nullable
EC20IPCEncodeErrorResponse(NSString * _Nullable identifier,
                           NSString *code,
                           NSString *message,
                           BOOL retryable,
                           NSDictionary<NSString *, id> * _Nullable details,
                           NSError **error);

/// Maps parser/encoder NSError values to a stable wire error code. Errors from
/// other domains map to `internal_error`.
FOUNDATION_EXPORT NSString *EC20IPCWireErrorCodeForError(NSError *error);

/// Convenience wrapper for returning a protocol NSError to a peer.
FOUNDATION_EXPORT NSData * _Nullable
EC20IPCEncodeProtocolErrorResponse(NSString * _Nullable identifier,
                                   NSError *protocolError,
                                   NSError **error);

/// Runs deterministic protocol unit checks without opening any USB device.
FOUNDATION_EXPORT BOOL EC20IPCProtocolRunSelfTests(NSError **error);

NS_ASSUME_NONNULL_END
