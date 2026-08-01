#import "EC20IPCProtocol.h"

NSString * const EC20IPCSchema = @"ec20.vohive/1";
NSString * const EC20IPCAPI = @"1.0";
const NSUInteger EC20IPCMaximumMessageBytes = 1024 * 1024;

NSErrorDomain const EC20IPCProtocolErrorDomain = @"EC20IPCProtocolErrorDomain";
NSString * const EC20IPCWireErrorCodeErrorKey = @"EC20IPCWireErrorCode";
NSString * const EC20IPCRequestIDErrorKey = @"EC20IPCRequestID";

NSString * const EC20IPCMethodSystemHello = @"system.hello";
NSString * const EC20IPCMethodDevicesList = @"devices.list";
NSString * const EC20IPCMethodATExecute = @"at.execute";

NSString * const EC20IPCErrorCodeInvalidRequest = @"invalid_request";
NSString * const EC20IPCErrorCodeUnsupportedAPI = @"unsupported_api";
NSString * const EC20IPCErrorCodeNotFound = @"not_found";
NSString * const EC20IPCErrorCodeNotReady = @"not_ready";
NSString * const EC20IPCErrorCodeBusy = @"busy";
NSString * const EC20IPCErrorCodePermissionDenied = @"permission_denied";
NSString * const EC20IPCErrorCodeTimeout = @"timeout";
NSString * const EC20IPCErrorCodeDeviceRemoved = @"device_removed";
NSString * const EC20IPCErrorCodeTransportError = @"transport_error";
NSString * const EC20IPCErrorCodeResyncRequired = @"resync_required";

static const NSInteger kSupportedSchemaMajor = 1;
static const NSInteger kSupportedAPIMajor = 1;

@interface EC20IPCRequest ()

- (instancetype)initWithSchema:(NSString *)schema
                     apiVersion:(NSString *)apiVersion
                     identifier:(NSString *)identifier
                         method:(NSString *)method
                         params:(NSDictionary<NSString *, id> *)params;

@end

@implementation EC20IPCRequest

- (instancetype)initWithSchema:(NSString *)schema
                     apiVersion:(NSString *)apiVersion
                     identifier:(NSString *)identifier
                         method:(NSString *)method
                         params:(NSDictionary<NSString *, id> *)params
{
    self = [super init];
    if (self != nil) {
        _schema = [schema copy];
        _apiVersion = [apiVersion copy];
        _identifier = [identifier copy];
        _method = [method copy];
        _params = [params copy];
    }
    return self;
}

@end

static NSError *ProtocolError(EC20IPCProtocolError code,
                              NSString *wireCode,
                              NSString *description,
                              NSString *identifier,
                              NSError *underlyingError)
{
    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description;
    userInfo[EC20IPCWireErrorCodeErrorKey] = wireCode;
    if (identifier != nil) {
        userInfo[EC20IPCRequestIDErrorKey] = identifier;
    }
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:EC20IPCProtocolErrorDomain code:code userInfo:userInfo];
}

static void AssignError(NSError **destination, NSError *error)
{
    if (destination != NULL) {
        *destination = error;
    }
}

static BOOL ParseUnsignedDecimal(NSString *text, NSInteger *value)
{
    if (text.length == 0) {
        return NO;
    }

    NSInteger parsed = 0;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character < '0' || character > '9') {
            return NO;
        }
        NSInteger digit = character - '0';
        if (parsed > (NSIntegerMax - digit) / 10) {
            return NO;
        }
        parsed = parsed * 10 + digit;
    }
    if (value != NULL) {
        *value = parsed;
    }
    return YES;
}

static BOOL ParseSchemaMajor(NSString *schema, NSInteger *major)
{
    static NSString * const prefix = @"ec20.vohive/";
    if (![schema hasPrefix:prefix]) {
        return NO;
    }
    return ParseUnsignedDecimal([schema substringFromIndex:prefix.length], major);
}

static BOOL ParseAPIVersion(NSString *version, NSInteger *major)
{
    NSArray<NSString *> *components = [version componentsSeparatedByString:@"."];
    if (components.count != 2) {
        return NO;
    }

    NSInteger parsedMajor = 0;
    NSInteger ignoredMinor = 0;
    if (!ParseUnsignedDecimal(components[0], &parsedMajor) ||
        !ParseUnsignedDecimal(components[1], &ignoredMinor)) {
        return NO;
    }
    if (major != NULL) {
        *major = parsedMajor;
    }
    return YES;
}

static BOOL IsValidIdentifier(NSString *identifier)
{
    return identifier.length > 0;
}

static BOOL IsValidMethod(NSString *method)
{
    if (method.length == 0 || method.length > 128) {
        return NO;
    }

    NSCharacterSet *firstCharacters =
        [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"];
    NSMutableCharacterSet *remainingCharacters = [firstCharacters mutableCopy];
    [remainingCharacters addCharactersInString:@"0123456789_.-"];

    if (![firstCharacters characterIsMember:[method characterAtIndex:0]]) {
        return NO;
    }
    for (NSUInteger index = 1; index < method.length; index++) {
        if (![remainingCharacters characterIsMember:[method characterAtIndex:index]]) {
            return NO;
        }
    }
    return YES;
}

static NSData *BodyFromNDJSONLine(NSData *line, NSError **error)
{
    if (line.length > EC20IPCMaximumMessageBytes) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorMessageTooLarge,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"IPC message exceeds the 1 MiB limit.",
                                         nil,
                                         nil));
        return nil;
    }
    if (line.length == 0) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidEnvelope,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"IPC request is empty.",
                                         nil,
                                         nil));
        return nil;
    }

    const uint8_t *bytes = line.bytes;
    NSUInteger bodyLength = line.length;
    if (bytes[bodyLength - 1] == '\n') {
        bodyLength--;
        if (bodyLength > 0 && bytes[bodyLength - 1] == '\r') {
            bodyLength--;
        }
    }
    if (bodyLength == 0) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidEnvelope,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"IPC request is empty.",
                                         nil,
                                         nil));
        return nil;
    }
    for (NSUInteger index = 0; index < bodyLength; index++) {
        if (bytes[index] == '\r' || bytes[index] == '\n') {
            AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidEnvelope,
                                             EC20IPCErrorCodeInvalidRequest,
                                             @"Expected exactly one NDJSON record.",
                                             nil,
                                             nil));
            return nil;
        }
    }
    return [line subdataWithRange:NSMakeRange(0, bodyLength)];
}

EC20IPCRequest *EC20IPCRequestFromNDJSONLine(NSData *line, NSError **error)
{
    NSData *body = BodyFromNDJSONLine(line, error);
    if (body == nil) {
        return nil;
    }

    if ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] == nil) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidUTF8,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"IPC request is not valid UTF-8.",
                                         nil,
                                         nil));
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonError];
    if (object == nil) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorMalformedJSON,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"IPC request contains malformed JSON.",
                                         nil,
                                         jsonError));
        return nil;
    }
    if (![object isKindOfClass:[NSDictionary class]]) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidEnvelope,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"IPC request must be a JSON object.",
                                         nil,
                                         nil));
        return nil;
    }

    NSDictionary<NSString *, id> *envelope = object;
    id rawSchema = envelope[@"schema"];
    id rawAPI = envelope[@"api_version"];
    id rawIdentifier = envelope[@"id"];
    id rawMethod = envelope[@"method"];
    id rawParams = envelope[@"params"];

    NSString *identifier = [rawIdentifier isKindOfClass:[NSString class]] ? rawIdentifier : nil;
    if (![rawSchema isKindOfClass:[NSString class]] ||
        ![rawAPI isKindOfClass:[NSString class]] ||
        !IsValidIdentifier(identifier) ||
        ![rawMethod isKindOfClass:[NSString class]] ||
        !IsValidMethod(rawMethod) ||
        ![rawParams isKindOfClass:[NSDictionary class]]) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidEnvelope,
                                         EC20IPCErrorCodeInvalidRequest,
                                         @"Request requires string schema/api_version/id/method fields and an object params field.",
                                         identifier,
                                         nil));
        return nil;
    }

    NSInteger schemaMajor = 0;
    if (!ParseSchemaMajor(rawSchema, &schemaMajor) || schemaMajor != kSupportedSchemaMajor) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorUnsupportedSchema,
                                         EC20IPCErrorCodeUnsupportedAPI,
                                         @"Unsupported IPC schema major version.",
                                         identifier,
                                         nil));
        return nil;
    }

    NSInteger apiMajor = 0;
    if (!ParseAPIVersion(rawAPI, &apiMajor) || apiMajor != kSupportedAPIMajor) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorUnsupportedAPIVersion,
                                         EC20IPCErrorCodeUnsupportedAPI,
                                         @"Unsupported IPC API major version.",
                                         identifier,
                                         nil));
        return nil;
    }

    return [[EC20IPCRequest alloc] initWithSchema:rawSchema
                                      apiVersion:rawAPI
                                      identifier:identifier
                                          method:rawMethod
                                          params:rawParams];
}

static NSSet<NSString *> *StableErrorCodes(void)
{
    static NSSet<NSString *> *codes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = [NSSet setWithArray:@[
            EC20IPCErrorCodeInvalidRequest,
            EC20IPCErrorCodeUnsupportedAPI,
            EC20IPCErrorCodeNotFound,
            EC20IPCErrorCodeNotReady,
            EC20IPCErrorCodeBusy,
            EC20IPCErrorCodePermissionDenied,
            EC20IPCErrorCodeTimeout,
            EC20IPCErrorCodeDeviceRemoved,
            EC20IPCErrorCodeTransportError,
            EC20IPCErrorCodeResyncRequired,
        ]];
    });
    return codes;
}

static NSData *EncodeResponseObject(NSDictionary<NSString *, id> *response,
                                    NSError **error)
{
    if (![NSJSONSerialization isValidJSONObject:response]) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidResponse,
                                         EC20IPCErrorCodeTransportError,
                                         @"IPC response contains a value that JSON cannot encode.",
                                         nil,
                                         nil));
        return nil;
    }

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:response
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (json == nil) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorEncodingFailed,
                                         EC20IPCErrorCodeTransportError,
                                         @"Could not encode the IPC response.",
                                         nil,
                                         jsonError));
        return nil;
    }
    if (json.length + 1 > EC20IPCMaximumMessageBytes) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorMessageTooLarge,
                                         EC20IPCErrorCodeTransportError,
                                         @"Encoded IPC response exceeds the 1 MiB limit.",
                                         nil,
                                         nil));
        return nil;
    }

    NSMutableData *record = [json mutableCopy];
    const uint8_t newline = '\n';
    [record appendBytes:&newline length:1];
    return record;
}

NSData *EC20IPCEncodeSuccessResponse(NSString *identifier,
                                     id result,
                                     NSError **error)
{
    if (!IsValidIdentifier(identifier)) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidResponse,
                                         EC20IPCErrorCodeTransportError,
                                         @"A success response requires a non-empty request id.",
                                         nil,
                                         nil));
        return nil;
    }

    NSDictionary<NSString *, id> *response = @{
        @"schema": EC20IPCSchema,
        @"api_version": EC20IPCAPI,
        @"id": identifier,
        @"ok": @YES,
        @"result": result != nil ? result : [NSNull null],
    };
    return EncodeResponseObject(response, error);
}

NSData *EC20IPCEncodeErrorResponse(NSString *identifier,
                                   NSString *code,
                                   NSString *message,
                                   BOOL retryable,
                                   NSDictionary<NSString *, id> *details,
                                   NSError **error)
{
    if (identifier != nil && !IsValidIdentifier(identifier)) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidResponse,
                                         EC20IPCErrorCodeTransportError,
                                         @"An error response id must be nil or a non-empty string.",
                                         nil,
                                         nil));
        return nil;
    }
    if (![StableErrorCodes() containsObject:code] || message.length == 0) {
        AssignError(error, ProtocolError(EC20IPCProtocolErrorInvalidResponse,
                                         EC20IPCErrorCodeTransportError,
                                         @"An error response requires a stable code and non-empty message.",
                                         identifier,
                                         nil));
        return nil;
    }

    NSMutableDictionary<NSString *, id> *wireError = [@{
        @"code": code,
        @"message": message,
        @"retryable": @(retryable),
    } mutableCopy];
    if (details != nil) {
        wireError[@"details"] = details;
    }

    NSDictionary<NSString *, id> *response = @{
        @"schema": EC20IPCSchema,
        @"api_version": EC20IPCAPI,
        @"id": identifier != nil ? identifier : [NSNull null],
        @"ok": @NO,
        @"error": wireError,
    };
    return EncodeResponseObject(response, error);
}

NSString *EC20IPCWireErrorCodeForError(NSError *error)
{
    id explicitCode = error.userInfo[EC20IPCWireErrorCodeErrorKey];
    if ([explicitCode isKindOfClass:[NSString class]] &&
        [StableErrorCodes() containsObject:explicitCode]) {
        return explicitCode;
    }
    if (![error.domain isEqualToString:EC20IPCProtocolErrorDomain]) {
        return EC20IPCErrorCodeTransportError;
    }

    switch ((EC20IPCProtocolError)error.code) {
        case EC20IPCProtocolErrorInvalidUTF8:
        case EC20IPCProtocolErrorMalformedJSON:
            return EC20IPCErrorCodeInvalidRequest;
        case EC20IPCProtocolErrorInvalidEnvelope:
            return EC20IPCErrorCodeInvalidRequest;
        case EC20IPCProtocolErrorMessageTooLarge:
            return EC20IPCErrorCodeInvalidRequest;
        case EC20IPCProtocolErrorUnsupportedSchema:
            return EC20IPCErrorCodeUnsupportedAPI;
        case EC20IPCProtocolErrorUnsupportedAPIVersion:
            return EC20IPCErrorCodeUnsupportedAPI;
        case EC20IPCProtocolErrorInvalidResponse:
        case EC20IPCProtocolErrorEncodingFailed:
        case EC20IPCProtocolErrorSelfTestFailed:
            return EC20IPCErrorCodeTransportError;
    }
    return EC20IPCErrorCodeTransportError;
}

NSData *EC20IPCEncodeProtocolErrorResponse(NSString *identifier,
                                           NSError *protocolError,
                                           NSError **error)
{
    NSString *trustedIdentifier = identifier;
    if (trustedIdentifier == nil) {
        id candidate = protocolError.userInfo[EC20IPCRequestIDErrorKey];
        if ([candidate isKindOfClass:[NSString class]] && IsValidIdentifier(candidate)) {
            trustedIdentifier = candidate;
        }
    }
    NSString *message = protocolError.localizedDescription;
    if (message.length == 0) {
        message = @"IPC request failed.";
    }
    return EC20IPCEncodeErrorResponse(trustedIdentifier,
                                      EC20IPCWireErrorCodeForError(protocolError),
                                      message,
                                      NO,
                                      nil,
                                      error);
}

static BOOL SelfTestAssert(BOOL condition,
                           NSString *failure,
                           NSError **error)
{
    if (condition) {
        return YES;
    }
    AssignError(error, ProtocolError(EC20IPCProtocolErrorSelfTestFailed,
                                     EC20IPCErrorCodeTransportError,
                                     failure,
                                     nil,
                                     nil));
    return NO;
}

static NSData *JSONLine(NSDictionary<NSString *, id> *object)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    NSMutableData *line = [json mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];
    return line;
}

BOOL EC20IPCProtocolRunSelfTests(NSError **error)
{
    NSDictionary<NSString *, id> *validEnvelope = @{
        @"schema": EC20IPCSchema,
        @"api_version": @"1.37",
        @"id": @"test-1",
        @"method": EC20IPCMethodATExecute,
        @"params": @{ @"command": @"ATI" },
        @"future_field": @{ @"ignored": @YES },
    };
    NSError *testError = nil;
    EC20IPCRequest *request = EC20IPCRequestFromNDJSONLine(JSONLine(validEnvelope),
                                                           &testError);
    if (!SelfTestAssert(request != nil && testError == nil &&
                        [request.identifier isEqualToString:@"test-1"] &&
                        [request.method isEqualToString:EC20IPCMethodATExecute] &&
                        [request.params[@"command"] isEqualToString:@"ATI"],
                        @"Valid JSON request or forward-compatible minor version failed.",
                        error)) {
        return NO;
    }

    NSData *malformed = [@"{not-json}\n" dataUsingEncoding:NSUTF8StringEncoding];
    testError = nil;
    request = EC20IPCRequestFromNDJSONLine(malformed, &testError);
    if (!SelfTestAssert(request == nil &&
                        testError.code == EC20IPCProtocolErrorMalformedJSON &&
                        [EC20IPCWireErrorCodeForError(testError)
                            isEqualToString:EC20IPCErrorCodeInvalidRequest],
                        @"Malformed JSON did not produce invalid_request.",
                        error)) {
        return NO;
    }

    NSMutableDictionary<NSString *, id> *wrongSchema = [validEnvelope mutableCopy];
    wrongSchema[@"schema"] = @"ec20.vohive/2";
    testError = nil;
    request = EC20IPCRequestFromNDJSONLine(JSONLine(wrongSchema), &testError);
    if (!SelfTestAssert(request == nil &&
                        testError.code == EC20IPCProtocolErrorUnsupportedSchema,
                        @"Unknown schema major version was not rejected.",
                        error)) {
        return NO;
    }

    NSMutableDictionary<NSString *, id> *wrongAPI = [validEnvelope mutableCopy];
    wrongAPI[@"api_version"] = @"2.0";
    testError = nil;
    request = EC20IPCRequestFromNDJSONLine(JSONLine(wrongAPI), &testError);
    if (!SelfTestAssert(request == nil &&
                        testError.code == EC20IPCProtocolErrorUnsupportedAPIVersion,
                        @"Unknown API major version was not rejected.",
                        error)) {
        return NO;
    }

    NSMutableData *oversized = [NSMutableData dataWithLength:EC20IPCMaximumMessageBytes + 1];
    testError = nil;
    request = EC20IPCRequestFromNDJSONLine(oversized, &testError);
    if (!SelfTestAssert(request == nil &&
                        testError.code == EC20IPCProtocolErrorMessageTooLarge,
                        @"Oversized request was not rejected.",
                        error)) {
        return NO;
    }

    testError = nil;
    NSData *encodedError = EC20IPCEncodeErrorResponse(nil,
                                                      EC20IPCErrorCodeInvalidRequest,
                                                      @"command is required",
                                                      NO,
                                                      @{ @"field": @"command" },
                                                      &testError);
    if (!SelfTestAssert(encodedError != nil && testError == nil,
                        @"Error response could not be encoded.",
                        error)) {
        return NO;
    }
    const uint8_t *encodedBytes = encodedError.bytes;
    NSData *encodedBody = [encodedError subdataWithRange:
        NSMakeRange(0, encodedError.length - 1)];
    NSDictionary<NSString *, id> *decodedError =
        [NSJSONSerialization JSONObjectWithData:encodedBody options:0 error:&testError];
    NSDictionary<NSString *, id> *errorObject = decodedError[@"error"];
    if (!SelfTestAssert(encodedBytes[encodedError.length - 1] == '\n' &&
                        [decodedError[@"schema"] isEqualToString:EC20IPCSchema] &&
                        [decodedError[@"api_version"] isEqualToString:EC20IPCAPI] &&
                        [decodedError[@"id"] isEqual:[NSNull null]] &&
                        [decodedError[@"ok"] isEqual:@NO] &&
                        [errorObject[@"code"] isEqualToString:EC20IPCErrorCodeInvalidRequest] &&
                        [errorObject[@"retryable"] isEqual:@NO],
                        @"Encoded error response has an invalid wire envelope.",
                        error)) {
        return NO;
    }

    return YES;
}
