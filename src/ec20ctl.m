#import <Foundation/Foundation.h>

#import "EC20IPCProtocol.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static NSString * const EC20CTLClientVersion = @"0.1";

static NSErrorDomain const EC20CTLErrorDomain = @"EC20CTLErrorDomain";
static NSErrorDomain const EC20CTLServerErrorDomain = @"EC20CTLServerErrorDomain";

typedef NS_ERROR_ENUM(EC20CTLErrorDomain, EC20CTLError) {
    EC20CTLErrorUsage = 1,
    EC20CTLErrorSystem = 2,
    EC20CTLErrorProtocol = 3,
    EC20CTLErrorMessageTooLarge = 4,
    EC20CTLErrorUnexpectedEOF = 5,
    EC20CTLErrorInvalidResult = 6,
    EC20CTLErrorSelfTest = 7,
};

static void AssignError(NSError **destination, NSError *error)
{
    if (destination != NULL) {
        *destination = error;
    }
}

static NSError *ClientError(EC20CTLError code, NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);

static NSError *ClientError(EC20CTLError code, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *description = [[NSString alloc] initWithFormat:format
                                                   arguments:arguments];
    va_end(arguments);
    return [NSError errorWithDomain:EC20CTLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *SafeDiagnosticText(NSString *text)
{
    if (text.length == 0) {
        return @"unspecified error";
    }

    NSUInteger limit = text.length < 512 ? text.length : 512;
    NSMutableString *safe = [NSMutableString stringWithCapacity:limit];
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    for (NSUInteger index = 0; index < limit; index++) {
        unichar character = [text characterAtIndex:index];
        if ([controls characterIsMember:character]) {
            [safe appendString:@" "];
        } else {
            [safe appendFormat:@"%C", character];
        }
    }
    if (text.length > limit) {
        [safe appendString:@"..."];
    }
    return safe;
}

static NSError *SystemError(NSString *operation, int errorNumber)
{
    const char *message = strerror(errorNumber);
    NSString *reason = message != NULL
        ? [NSString stringWithUTF8String:message]
        : @"unknown system error";
    return ClientError(EC20CTLErrorSystem,
                       @"%@ failed: %@",
                       operation,
                       SafeDiagnosticText(reason));
}

static BOOL IsJSONBoolean(id value)
{
    return [value isKindOfClass:[NSNumber class]] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IsNonEmptyString(id value)
{
    return [value isKindOfClass:[NSString class]] &&
           ((NSString *)value).length > 0;
}

static BOOL IsValidGeneration(id value, NSNumber **generation)
{
    if (![value isKindOfClass:[NSNumber class]] || IsJSONBoolean(value)) {
        return NO;
    }
    double numericValue = [value doubleValue];
    if (!isfinite(numericValue) || numericValue < 0.0 ||
        floor(numericValue) != numericValue || numericValue > 9007199254740991.0) {
        return NO;
    }
    if (generation != NULL) {
        *generation = value;
    }
    return YES;
}

typedef ssize_t (*EC20CTLWriteFunction)(void *context,
                                        const void *bytes,
                                        size_t length);

static BOOL WriteAllUsing(EC20CTLWriteFunction writer,
                          void *context,
                          NSData *data,
                          NSString *operation,
                          NSError **error)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t written = writer(context, bytes + offset, data.length - offset);
        if (written > 0) {
            offset += (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        int errorNumber = written == 0 ? EIO : errno;
        AssignError(error, SystemError(operation, errorNumber));
        return NO;
    }
    return YES;
}

static ssize_t SendWriter(void *context, const void *bytes, size_t length)
{
    int socketFD = *(int *)context;
    return send(socketFD, bytes, length, 0);
}

static ssize_t FileWriter(void *context, const void *bytes, size_t length)
{
    int fileDescriptor = *(int *)context;
    return write(fileDescriptor, bytes, length);
}

typedef NS_ENUM(NSInteger, EC20CTLLineExtraction) {
    EC20CTLLineExtractionNeedMore,
    EC20CTLLineExtractionReady,
    EC20CTLLineExtractionFailed,
};

static EC20CTLLineExtraction ExtractNDJSONLine(NSMutableData *buffer,
                                               NSData **line,
                                               NSError **error)
{
    const uint8_t *bytes = buffer.bytes;
    for (NSUInteger index = 0; index < buffer.length; index++) {
        if (bytes[index] != '\n') {
            continue;
        }

        NSUInteger recordLength = index + 1;
        if (recordLength > EC20IPCMaximumMessageBytes) {
            AssignError(error,
                        ClientError(EC20CTLErrorMessageTooLarge,
                                    @"IPC response exceeds the 1 MiB limit."));
            return EC20CTLLineExtractionFailed;
        }
        if (line != NULL) {
            *line = [buffer subdataWithRange:NSMakeRange(0, recordLength)];
        }
        [buffer replaceBytesInRange:NSMakeRange(0, recordLength)
                          withBytes:NULL
                             length:0];
        return EC20CTLLineExtractionReady;
    }

    // The newline itself counts toward the message limit. A newline added after
    // this point would therefore make the record too large.
    if (buffer.length >= EC20IPCMaximumMessageBytes) {
        AssignError(error,
                    ClientError(EC20CTLErrorMessageTooLarge,
                                @"IPC response exceeds the 1 MiB limit."));
        return EC20CTLLineExtractionFailed;
    }
    return EC20CTLLineExtractionNeedMore;
}

@interface EC20CTLLineReader : NSObject

- (instancetype)initWithFileDescriptor:(int)fileDescriptor;
- (NSData * _Nullable)readLine:(NSError **)error;

@end

@implementation EC20CTLLineReader {
    int _fileDescriptor;
    NSMutableData *_buffer;
}

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
{
    self = [super init];
    if (self != nil) {
        _fileDescriptor = fileDescriptor;
        _buffer = [NSMutableData data];
    }
    return self;
}

- (NSData *)readLine:(NSError **)error
{
    for (;;) {
        NSData *line = nil;
        EC20CTLLineExtraction extraction = ExtractNDJSONLine(_buffer,
                                                              &line,
                                                              error);
        if (extraction == EC20CTLLineExtractionReady) {
            return line;
        }
        if (extraction == EC20CTLLineExtractionFailed) {
            return nil;
        }

        uint8_t incoming[16384];
        ssize_t received = recv(_fileDescriptor, incoming, sizeof(incoming), 0);
        if (received > 0) {
            [_buffer appendBytes:incoming length:(NSUInteger)received];
            continue;
        }
        if (received < 0 && errno == EINTR) {
            continue;
        }
        if (received < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                AssignError(error,
                            ClientError(EC20CTLErrorSystem,
                                        @"Timed out waiting for an IPC response."));
            } else {
                AssignError(error, SystemError(@"receive IPC response", errno));
            }
            return nil;
        }

        NSString *message = _buffer.length == 0
            ? @"IPC server closed the connection while a response was pending."
            : @"IPC server closed the connection in the middle of an NDJSON record.";
        AssignError(error, ClientError(EC20CTLErrorUnexpectedEOF, @"%@", message));
        return nil;
    }
}

@end


static NSData *EncodeRequest(NSString *identifier,
                             NSString *method,
                             NSDictionary<NSString *, id> *params,
                             NSError **error)
{
    NSDictionary<NSString *, id> *request = @{
        @"schema": EC20IPCSchema,
        @"api_version": EC20IPCAPI,
        @"id": identifier,
        @"method": method,
        @"params": params,
    };
    if (![NSJSONSerialization isValidJSONObject:request]) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC request contains a value that JSON cannot encode."));
        return nil;
    }

    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:request
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (json == nil) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"Could not encode IPC request: %@",
                                SafeDiagnosticText(jsonError.localizedDescription)));
        return nil;
    }
    if (json.length + 1 > EC20IPCMaximumMessageBytes) {
        AssignError(error,
                    ClientError(EC20CTLErrorMessageTooLarge,
                                @"IPC request exceeds the 1 MiB limit."));
        return nil;
    }

    NSMutableData *record = [json mutableCopy];
    const uint8_t newline = '\n';
    [record appendBytes:&newline length:1];
    return record;
}

static NSData *NDJSONBody(NSData *record, NSError **error)
{
    if (record.length == 0 || record.length > EC20IPCMaximumMessageBytes) {
        AssignError(error,
                    ClientError(record.length == 0 ? EC20CTLErrorProtocol
                                                   : EC20CTLErrorMessageTooLarge,
                                record.length == 0
                                    ? @"IPC response is empty."
                                    : @"IPC response exceeds the 1 MiB limit."));
        return nil;
    }

    const uint8_t *bytes = record.bytes;
    NSUInteger bodyLength = record.length;
    if (bytes[bodyLength - 1] != '\n') {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC response is missing its NDJSON newline."));
        return nil;
    }
    bodyLength--;
    if (bodyLength > 0 && bytes[bodyLength - 1] == '\r') {
        bodyLength--;
    }
    if (bodyLength == 0) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC response contains an empty NDJSON record."));
        return nil;
    }
    for (NSUInteger index = 0; index < bodyLength; index++) {
        if (bytes[index] == '\r' || bytes[index] == '\n') {
            AssignError(error,
                        ClientError(EC20CTLErrorProtocol,
                                    @"IPC response contains multiple NDJSON records."));
            return nil;
        }
    }
    return [record subdataWithRange:NSMakeRange(0, bodyLength)];
}

static BOOL IsCompatibleAPIVersion(NSString *version)
{
    if (![version isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSArray<NSString *> *components = [version componentsSeparatedByString:@"."];
    NSArray<NSString *> *supported = [EC20IPCAPI componentsSeparatedByString:@"."];
    if (components.count != 2 || supported.count != 2 ||
        ![components[0] isEqualToString:supported[0]]) {
        return NO;
    }
    for (NSString *component in components) {
        if (component.length == 0) {
            return NO;
        }
        for (NSUInteger index = 0; index < component.length; index++) {
            unichar character = [component characterAtIndex:index];
            if (character < '0' || character > '9') {
                return NO;
            }
        }
    }
    return YES;
}

typedef NS_ENUM(NSInteger, EC20CTLParsedMessageKind) {
    EC20CTLParsedMessageResponse,
    EC20CTLParsedMessageEvent,
};

static BOOL ParseResponseRecord(NSData *record,
                                NSString *expectedIdentifier,
                                EC20CTLParsedMessageKind *kind,
                                id _Nullable * _Nullable result,
                                NSError **error)
{
    NSData *body = NDJSONBody(record, error);
    if (body == nil) {
        return NO;
    }
    if ([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] == nil) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC response is not valid UTF-8."));
        return NO;
    }

    NSError *jsonError = nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonError];
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        NSString *reason = decoded == nil
            ? SafeDiagnosticText(jsonError.localizedDescription)
            : @"top-level value is not an object";
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"Malformed IPC response: %@.", reason));
        return NO;
    }

    NSDictionary<NSString *, id> *envelope = decoded;
    if (![envelope[@"schema"] isEqualToString:EC20IPCSchema] ||
        !IsCompatibleAPIVersion(envelope[@"api_version"])) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC response uses an unsupported schema or API version."));
        return NO;
    }

    id event = envelope[@"event"];
    if (event != nil && envelope[@"id"] == nil) {
        if (!IsNonEmptyString(event)) {
            AssignError(error,
                        ClientError(EC20CTLErrorProtocol,
                                    @"IPC event has an invalid event name."));
            return NO;
        }
        if (kind != NULL) {
            *kind = EC20CTLParsedMessageEvent;
        }
        return YES;
    }

    id identifier = envelope[@"id"];
    if (![identifier isKindOfClass:[NSString class]] ||
        ![identifier isEqualToString:expectedIdentifier]) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC response id does not match the pending request."));
        return NO;
    }
    id ok = envelope[@"ok"];
    if (!IsJSONBoolean(ok)) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC response has an invalid or missing ok field."));
        return NO;
    }
    if (kind != NULL) {
        *kind = EC20CTLParsedMessageResponse;
    }

    if ([ok boolValue]) {
        id responseResult = envelope[@"result"];
        if (responseResult == nil) {
            AssignError(error,
                        ClientError(EC20CTLErrorProtocol,
                                    @"Successful IPC response is missing result."));
            return NO;
        }
        if (result != NULL) {
            *result = responseResult;
        }
        return YES;
    }

    id wireError = envelope[@"error"];
    if (![wireError isKindOfClass:[NSDictionary class]]) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"Failed IPC response is missing its error object."));
        return NO;
    }
    NSString *code = wireError[@"code"];
    NSString *message = wireError[@"message"];
    id retryable = wireError[@"retryable"];
    if (!IsNonEmptyString(code) || !IsNonEmptyString(message) ||
        !IsJSONBoolean(retryable)) {
        AssignError(error,
                    ClientError(EC20CTLErrorProtocol,
                                @"IPC server error object is malformed."));
        return NO;
    }

    NSString *description = [NSString stringWithFormat:
        @"server error %@: %@%@",
        SafeDiagnosticText(code),
        SafeDiagnosticText(message),
        [retryable boolValue] ? @" (retryable)" : @""];
    AssignError(error,
                [NSError errorWithDomain:EC20CTLServerErrorDomain
                                    code:1
                                userInfo:@{
                                    NSLocalizedDescriptionKey: description,
                                    @"wire_code": code,
                                    @"retryable": retryable,
                                }]);
    return NO;
}

static int ConnectUnixSocket(NSString *path, NSError **error)
{
    NSData *pathBytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (pathBytes.length == 0 || pathBytes.length >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
        memchr(pathBytes.bytes, '\0', pathBytes.length) != NULL) {
        AssignError(error,
                    ClientError(EC20CTLErrorUsage,
                                @"Unix socket path is empty, invalid, or too long."));
        return -1;
    }

    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD < 0) {
        AssignError(error, SystemError(@"create Unix socket", errno));
        return -1;
    }

    int flags = fcntl(socketFD, F_GETFD);
    if (flags >= 0) {
        (void)fcntl(socketFD, F_SETFD, flags | FD_CLOEXEC);
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE,
                   &enabled, sizeof(enabled)) != 0) {
        int errorNumber = errno;
        close(socketFD);
        AssignError(error, SystemError(@"configure Unix socket", errorNumber));
        return -1;
    }
#endif

    struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
    (void)setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, pathBytes.bytes, pathBytes.length);
    address.sun_path[pathBytes.length] = '\0';
#ifdef __APPLE__
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) +
                                pathBytes.length + 1);
#endif
    socklen_t addressLength = (socklen_t)(offsetof(struct sockaddr_un, sun_path) +
                                          pathBytes.length + 1);

    while (connect(socketFD, (struct sockaddr *)&address, addressLength) != 0) {
        if (errno == EINTR) {
            continue;
        }
        int errorNumber = errno;
        close(socketFD);
        AssignError(error, SystemError(@"connect to ec20d", errorNumber));
        return -1;
    }
    return socketFD;
}

@interface EC20CTLClient : NSObject

- (instancetype)initWithSocketPath:(NSString *)socketPath error:(NSError **)error;
- (instancetype)initWithConnectedFileDescriptor:(int)fileDescriptor;
- (BOOL)performMethod:(NSString *)method
               params:(NSDictionary<NSString *, id> *)params
               result:(id _Nullable * _Nullable)result
                error:(NSError **)error;

@end


@implementation EC20CTLClient {
    int _socketFD;
    BOOL _ownsSocket;
    EC20CTLLineReader *_reader;
    NSUInteger _nextIdentifier;
}

- (instancetype)initWithSocketPath:(NSString *)socketPath error:(NSError **)error
{
    int socketFD = ConnectUnixSocket(socketPath, error);
    if (socketFD < 0) {
        return nil;
    }
    return [self initWithConnectedFileDescriptor:socketFD];
}

- (instancetype)initWithConnectedFileDescriptor:(int)fileDescriptor
{
    self = [super init];
    if (self != nil) {
        _socketFD = fileDescriptor;
        _ownsSocket = YES;
        _reader = [[EC20CTLLineReader alloc] initWithFileDescriptor:fileDescriptor];
        _nextIdentifier = 1;
    }
    return self;
}

- (void)dealloc
{
    if (_ownsSocket && _socketFD >= 0) {
        close(_socketFD);
        _socketFD = -1;
        _ownsSocket = NO;
    }
}

- (BOOL)performMethod:(NSString *)method
               params:(NSDictionary<NSString *, id> *)params
               result:(id *)result
                error:(NSError **)error
{
    NSString *identifier = [NSString stringWithFormat:@"%lu",
                                                       (unsigned long)_nextIdentifier++];
    NSData *request = EncodeRequest(identifier, method, params, error);
    if (request == nil) {
        return NO;
    }
    if (!WriteAllUsing(SendWriter,
                       &_socketFD,
                       request,
                       @"send IPC request",
                       error)) {
        return NO;
    }

    // A lease owner may receive at.urc events while a command is pending. They
    // are intentionally not logged by this diagnostic client because URCs can
    // contain phone numbers or message metadata.
    for (NSUInteger eventCount = 0; eventCount <= 64; eventCount++) {
        NSData *record = [_reader readLine:error];
        if (record == nil) {
            return NO;
        }
        EC20CTLParsedMessageKind kind = EC20CTLParsedMessageResponse;
        id responseResult = nil;
        if (!ParseResponseRecord(record,
                                 identifier,
                                 &kind,
                                 &responseResult,
                                 error)) {
            return NO;
        }
        if (kind == EC20CTLParsedMessageEvent) {
            continue;
        }
        if (result != NULL) {
            *result = responseResult;
        }
        return YES;
    }

    AssignError(error,
                ClientError(EC20CTLErrorProtocol,
                            @"Too many unsolicited IPC events arrived before the response."));
    return NO;
}

@end


static NSDictionary<NSString *, id> *HelloParams(void)
{
    return @{
        @"client": @"ec20ctl",
        @"client_version": EC20CTLClientVersion,
    };
}

static BOOL RequireDictionaryResult(id result,
                                    NSString *method,
                                    NSDictionary<NSString *, id> **dictionary,
                                    NSError **error)
{
    if (![result isKindOfClass:[NSDictionary class]]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"%@ returned a non-object result.", method));
        return NO;
    }
    if (dictionary != NULL) {
        *dictionary = result;
    }
    return YES;
}

static BOOL WriteJSONResult(id result, NSError **error)
{
    if (![NSJSONSerialization isValidJSONObject:result]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"IPC result cannot be represented as JSON."));
        return NO;
    }
    NSError *jsonError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                   options:(NSJSONWritingPrettyPrinted |
                                                            NSJSONWritingSortedKeys)
                                                     error:&jsonError];
    if (json == nil) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"Could not encode command output: %@",
                                SafeDiagnosticText(jsonError.localizedDescription)));
        return NO;
    }
    NSMutableData *output = [json mutableCopy];
    const uint8_t newline = '\n';
    [output appendBytes:&newline length:1];
    int outputFD = STDOUT_FILENO;
    return WriteAllUsing(FileWriter, &outputFD, output, @"write stdout", error);
}

static BOOL RunHello(EC20CTLClient *client, NSError **error)
{
    id result = nil;
    if (![client performMethod:EC20IPCMethodSystemHello
                        params:HelloParams()
                        result:&result
                         error:error]) {
        return NO;
    }
    if (!RequireDictionaryResult(result, EC20IPCMethodSystemHello, NULL, error)) {
        return NO;
    }
    return WriteJSONResult(result, error);
}

static BOOL FetchDevices(EC20CTLClient *client,
                         NSDictionary<NSString *, id> **snapshot,
                         NSError **error)
{
    id result = nil;
    if (![client performMethod:EC20IPCMethodDevicesList
                        params:@{}
                        result:&result
                         error:error]) {
        return NO;
    }
    NSDictionary<NSString *, id> *dictionary = nil;
    if (!RequireDictionaryResult(result,
                                 EC20IPCMethodDevicesList,
                                 &dictionary,
                                 error) ||
        ![dictionary[@"devices"] isKindOfClass:[NSArray class]]) {
        if (error != NULL && *error == nil) {
            *error = ClientError(EC20CTLErrorInvalidResult,
                                 @"devices.list result is missing its devices array.");
        }
        return NO;
    }
    if (snapshot != NULL) {
        *snapshot = dictionary;
    }
    return YES;
}

static BOOL RunList(EC20CTLClient *client, NSError **error)
{
    NSDictionary<NSString *, id> *snapshot = nil;
    if (!FetchDevices(client, &snapshot, error)) {
        return NO;
    }
    return WriteJSONResult(snapshot, error);
}

static BOOL ValidateHelloForAT(id result, NSError **error)
{
    NSDictionary<NSString *, id> *hello = nil;
    if (!RequireDictionaryResult(result,
                                 EC20IPCMethodSystemHello,
                                 &hello,
                                 error)) {
        return NO;
    }
    id capabilities = hello[@"capabilities"];
    if (![capabilities isKindOfClass:[NSArray class]]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"system.hello result is missing capabilities."));
        return NO;
    }
    for (id capability in capabilities) {
        if (![capability isKindOfClass:[NSString class]]) {
            AssignError(error,
                        ClientError(EC20CTLErrorInvalidResult,
                                    @"system.hello returned an invalid capability."));
            return NO;
        }
    }
    if (![capabilities containsObject:@"at.rpc"]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"ec20d does not advertise the at.rpc capability."));
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *SelectDevice(NSDictionary<NSString *, id> *snapshot,
                                                   NSString *requestedInstance,
                                                   NSError **error)
{
    NSArray *devices = snapshot[@"devices"];
    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray array];
    for (id candidate in devices) {
        if (![candidate isKindOfClass:[NSDictionary class]]) {
            AssignError(error,
                        ClientError(EC20CTLErrorInvalidResult,
                                    @"devices.list contains a non-object device."));
            return nil;
        }
        id instance = candidate[@"instance_id"];
        if (!IsNonEmptyString(instance)) {
            AssignError(error,
                        ClientError(EC20CTLErrorInvalidResult,
                                    @"devices.list contains a device without instance_id."));
            return nil;
        }
        if (requestedInstance == nil || [instance isEqualToString:requestedInstance]) {
            [matches addObject:candidate];
        }
    }

    if (requestedInstance == nil && matches.count != 1) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"AT requires exactly one attached device when --instance is omitted (found %lu).",
                                (unsigned long)matches.count));
        return nil;
    }
    if (requestedInstance != nil && matches.count != 1) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                matches.count == 0
                                    ? @"The requested device instance was not found."
                                    : @"The requested device instance is not unique."));
        return nil;
    }

    NSDictionary<NSString *, id> *device = matches.firstObject;
    if (!IsValidGeneration(device[@"generation"], NULL)) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"Selected device has an invalid generation."));
        return nil;
    }
    return device;
}

static BOOL ValidateAcquireResult(id result,
                                  NSString *instance,
                                  NSNumber *generation,
                                  NSString **leaseIdentifier,
                                  NSError **error)
{
    NSDictionary<NSString *, id> *acquire = nil;
    if (!RequireDictionaryResult(result,
                                 EC20IPCMethodATAcquire,
                                 &acquire,
                                 error)) {
        return NO;
    }
    if (!IsNonEmptyString(acquire[@"lease_id"]) ||
        ![acquire[@"instance_id"] isEqualToString:instance] ||
        ![acquire[@"generation"] isEqual:generation]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"at.acquire returned an invalid or mismatched lease."));
        return NO;
    }
    if (leaseIdentifier != NULL) {
        *leaseIdentifier = acquire[@"lease_id"];
    }
    return YES;
}

static BOOL DecodeExecuteResult(id result,
                                NSData **response,
                                NSError **error)
{
    NSDictionary<NSString *, id> *execute = nil;
    if (!RequireDictionaryResult(result,
                                 EC20IPCMethodATExecute,
                                 &execute,
                                 error)) {
        return NO;
    }

    id terminal = execute[@"terminal"];
    NSSet<NSString *> *terminalValues = [NSSet setWithArray:@[@"ok", @"error", @"pending"]];
    if (![terminal isKindOfClass:[NSString class]] ||
        ![terminalValues containsObject:terminal]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"at.execute returned an invalid terminal state."));
        return NO;
    }

    NSData *decoded = nil;
    id encodedResponse = execute[@"response_base64"];
    if (encodedResponse != nil) {
        if (![encodedResponse isKindOfClass:[NSString class]]) {
            AssignError(error,
                        ClientError(EC20CTLErrorInvalidResult,
                                    @"at.execute returned an invalid Base64 response."));
            return NO;
        }
        decoded = [[NSData alloc] initWithBase64EncodedString:encodedResponse options:0];
        if (decoded == nil) {
            AssignError(error,
                        ClientError(EC20CTLErrorInvalidResult,
                                    @"at.execute returned malformed Base64 response data."));
            return NO;
        }
    } else if ([execute[@"response"] isKindOfClass:[NSString class]]) {
        decoded = [execute[@"response"] dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"at.execute result is missing response data."));
        return NO;
    }

    if (decoded.length > 65536) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"at.execute response exceeds the requested 64 KiB limit."));
        return NO;
    }
    if (response != NULL) {
        *response = decoded;
    }
    return YES;
}

static BOOL ValidateReleaseResult(id result, NSError **error)
{
    NSDictionary<NSString *, id> *release = nil;
    if (!RequireDictionaryResult(result,
                                 EC20IPCMethodATRelease,
                                 &release,
                                 error)) {
        return NO;
    }
    if (!IsJSONBoolean(release[@"released"]) ||
        ![release[@"released"] boolValue]) {
        AssignError(error,
                    ClientError(EC20CTLErrorInvalidResult,
                                @"at.release did not confirm lease release."));
        return NO;
    }
    return YES;
}

static BOOL IsSafeATCommand(NSString *command)
{
    if (command.length < 2 ||
        [[command substringToIndex:2] caseInsensitiveCompare:@"AT"] != NSOrderedSame) {
        return NO;
    }
    NSData *ascii = [command dataUsingEncoding:NSASCIIStringEncoding];
    if (ascii == nil || ascii.length != command.length) {
        return NO;
    }
    const uint8_t *bytes = ascii.bytes;
    for (NSUInteger index = 0; index < ascii.length; index++) {
        if (bytes[index] < 0x20 || bytes[index] == 0x7f) {
            return NO;
        }
    }
    return YES;
}

static NSError *CombinedOperationAndReleaseError(NSError *operationError,
                                                  NSError *releaseError)
{
    if (operationError == nil) {
        return releaseError;
    }
    if (releaseError == nil) {
        return operationError;
    }
    return ClientError(EC20CTLErrorSystem,
                       @"%@; lease cleanup also failed: %@",
                       SafeDiagnosticText(operationError.localizedDescription),
                       SafeDiagnosticText(releaseError.localizedDescription));
}

static BOOL RunAT(EC20CTLClient *client,
                  NSString *command,
                  NSString *requestedInstance,
                  NSError **error)
{
    if (!IsSafeATCommand(command)) {
        AssignError(error,
                    ClientError(EC20CTLErrorUsage,
                                @"AT command must be non-empty printable ASCII without control characters."));
        return NO;
    }

    id helloResult = nil;
    if (![client performMethod:EC20IPCMethodSystemHello
                        params:HelloParams()
                        result:&helloResult
                         error:error] ||
        !ValidateHelloForAT(helloResult, error)) {
        return NO;
    }

    NSDictionary<NSString *, id> *snapshot = nil;
    if (!FetchDevices(client, &snapshot, error)) {
        return NO;
    }
    NSDictionary<NSString *, id> *device = SelectDevice(snapshot,
                                                         requestedInstance,
                                                         error);
    if (device == nil) {
        return NO;
    }
    NSString *instance = device[@"instance_id"];
    NSNumber *generation = device[@"generation"];

    id acquireResult = nil;
    NSDictionary<NSString *, id> *leaseBase = @{
        @"instance_id": instance,
        @"generation": generation,
    };
    if (![client performMethod:EC20IPCMethodATAcquire
                        params:leaseBase
                        result:&acquireResult
                         error:error]) {
        return NO;
    }
    NSString *leaseIdentifier = nil;
    if (!ValidateAcquireResult(acquireResult,
                               instance,
                               generation,
                               &leaseIdentifier,
                               error)) {
        return NO;
    }

    NSDictionary<NSString *, id> *leaseParams = @{
        @"instance_id": instance,
        @"generation": generation,
        @"lease_id": leaseIdentifier,
    };
    NSMutableDictionary<NSString *, id> *executeParams = [leaseParams mutableCopy];
    executeParams[@"command"] = command;
    executeParams[@"timeout_ms"] = @3000;
    executeParams[@"max_response_bytes"] = @65536;

    NSError *operationError = nil;
    NSData *response = nil;
    id executeResult = nil;
    if (![client performMethod:EC20IPCMethodATExecute
                        params:executeParams
                        result:&executeResult
                         error:&operationError] ||
        !DecodeExecuteResult(executeResult, &response, &operationError)) {
        // Release is still attempted below. No command or response bytes are
        // included in diagnostics.
    }

    NSError *releaseError = nil;
    id releaseResult = nil;
    if (![client performMethod:EC20IPCMethodATRelease
                        params:leaseParams
                        result:&releaseResult
                         error:&releaseError] ||
        !ValidateReleaseResult(releaseResult, &releaseError)) {
        // Reported after preserving the primary execute failure, if any.
    }

    NSError *finalError = CombinedOperationAndReleaseError(operationError,
                                                            releaseError);
    if (finalError != nil) {
        AssignError(error, finalError);
        return NO;
    }

    int outputFD = STDOUT_FILENO;
    return WriteAllUsing(FileWriter,
                         &outputFD,
                         response,
                         @"write AT response",
                         error);
}

typedef struct {
    __unsafe_unretained NSMutableData *output;
    size_t maximumChunk;
    BOOL interruptOnce;
} EC20CTLShortWriterContext;

static ssize_t ShortTestWriter(void *opaque, const void *bytes, size_t length)
{
    EC20CTLShortWriterContext *context = opaque;
    if (context->interruptOnce) {
        context->interruptOnce = NO;
        errno = EINTR;
        return -1;
    }
    size_t amount = length < context->maximumChunk
        ? length
        : context->maximumChunk;
    [context->output appendBytes:bytes length:amount];
    return (ssize_t)amount;
}

static BOOL SelfTestAssert(BOOL condition, NSString *message, NSError **error)
{
    if (condition) {
        return YES;
    }
    AssignError(error, ClientError(EC20CTLErrorSelfTest, @"%@", message));
    return NO;
}

static BOOL RunSelfTests(NSError **error)
{
    NSError *testError = nil;
    NSData *requestLine = EncodeRequest(@"42",
                                        EC20IPCMethodSystemHello,
                                        HelloParams(),
                                        &testError);
    EC20IPCRequest *request = requestLine != nil
        ? EC20IPCRequestFromNDJSONLine(requestLine, &testError)
        : nil;
    if (!SelfTestAssert(request != nil && testError == nil &&
                        [request.identifier isEqualToString:@"42"] &&
                        [request.method isEqualToString:EC20IPCMethodSystemHello],
                        @"request encoding is not accepted by EC20IPCProtocol",
                        error)) {
        return NO;
    }

    NSMutableData *stream = [NSMutableData data];
    [stream appendData:[@"{\"one\":" dataUsingEncoding:NSUTF8StringEncoding]];
    NSData *line = nil;
    EC20CTLLineExtraction extraction = ExtractNDJSONLine(stream, &line, &testError);
    if (!SelfTestAssert(extraction == EC20CTLLineExtractionNeedMore && line == nil,
                        @"partial NDJSON record was not buffered",
                        error)) {
        return NO;
    }
    [stream appendData:[@"1}\n{\"two\":2}\n"
                        dataUsingEncoding:NSUTF8StringEncoding]];
    extraction = ExtractNDJSONLine(stream, &line, &testError);
    NSString *firstLine = [[NSString alloc] initWithData:line
                                                encoding:NSUTF8StringEncoding];
    if (!SelfTestAssert(extraction == EC20CTLLineExtractionReady &&
                        [firstLine isEqualToString:@"{\"one\":1}\n"],
                        @"fragmented NDJSON record was not reassembled",
                        error)) {
        return NO;
    }
    extraction = ExtractNDJSONLine(stream, &line, &testError);
    NSString *secondLine = [[NSString alloc] initWithData:line
                                                 encoding:NSUTF8StringEncoding];
    if (!SelfTestAssert(extraction == EC20CTLLineExtractionReady &&
                        [secondLine isEqualToString:@"{\"two\":2}\n"] &&
                        stream.length == 0,
                        @"coalesced NDJSON records were not separated",
                        error)) {
        return NO;
    }

    NSMutableData *writeOutput = [NSMutableData data];
    EC20CTLShortWriterContext writeContext = {
        .output = writeOutput,
        .maximumChunk = 3,
        .interruptOnce = YES,
    };
    NSData *writeInput = [@"short-write-check" dataUsingEncoding:NSUTF8StringEncoding];
    testError = nil;
    BOOL wrote = WriteAllUsing(ShortTestWriter,
                               &writeContext,
                               writeInput,
                               @"self-test write",
                               &testError);
    if (!SelfTestAssert(wrote && testError == nil &&
                        [writeOutput isEqualToData:writeInput],
                        @"short write or EINTR handling failed",
                        error)) {
        return NO;
    }

    NSDictionary *wireResult = @{
        @"terminal": @"ok",
        @"response": @"AT\r\nOK\r\n",
        @"response_base64": [[@"AT\r\nOK\r\n"
            dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0],
    };
    testError = nil;
    NSData *success = EC20IPCEncodeSuccessResponse(@"9", wireResult, &testError);
    EC20CTLParsedMessageKind kind = EC20CTLParsedMessageEvent;
    id parsedResult = nil;
    BOOL parsed = success != nil &&
        ParseResponseRecord(success, @"9", &kind, &parsedResult, &testError);
    NSData *decodedResponse = nil;
    BOOL decoded = parsed && DecodeExecuteResult(parsedResult,
                                                  &decodedResponse,
                                                  &testError);
    if (!SelfTestAssert(decoded && testError == nil &&
                        kind == EC20CTLParsedMessageResponse &&
                        [decodedResponse isEqualToData:
                            [@"AT\r\nOK\r\n" dataUsingEncoding:NSUTF8StringEncoding]],
                        @"success response parsing or Base64 decoding failed",
                        error)) {
        return NO;
    }

    testError = nil;
    NSData *wireFailure = EC20IPCEncodeErrorResponse(@"10",
                                                     EC20IPCErrorCodeBusy,
                                                     @"lease unavailable",
                                                     YES,
                                                     nil,
                                                     &testError);
    parsedResult = nil;
    parsed = ParseResponseRecord(wireFailure,
                                 @"10",
                                 &kind,
                                 &parsedResult,
                                 &testError);
    if (!SelfTestAssert(!parsed &&
                        [testError.domain isEqualToString:EC20CTLServerErrorDomain] &&
                        [testError.userInfo[@"wire_code"] isEqualToString:EC20IPCErrorCodeBusy],
                        @"server error response was not preserved",
                        error)) {
        return NO;
    }

    testError = nil;
    parsed = ParseResponseRecord(success, @"different-id", &kind, NULL, &testError);
    if (!SelfTestAssert(!parsed &&
                        [testError.domain isEqualToString:EC20CTLErrorDomain] &&
                        testError.code == EC20CTLErrorProtocol,
                        @"mismatched response id was not rejected",
                        error)) {
        return NO;
    }

    NSMutableData *oversized = [NSMutableData dataWithLength:EC20IPCMaximumMessageBytes];
    memset(oversized.mutableBytes, 'x', oversized.length);
    testError = nil;
    extraction = ExtractNDJSONLine(oversized, NULL, &testError);
    if (!SelfTestAssert(extraction == EC20CTLLineExtractionFailed &&
                        testError.code == EC20CTLErrorMessageTooLarge,
                        @"oversized NDJSON response was not rejected",
                        error)) {
        return NO;
    }

    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        AssignError(error, SystemError(@"create self-test socketpair", errno));
        return NO;
    }
    NSData *partial = [@"{\"incomplete\":true}"
        dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(sockets[1], partial.bytes, partial.length);
    close(sockets[1]);
    EC20CTLLineReader *reader = [[EC20CTLLineReader alloc]
        initWithFileDescriptor:sockets[0]];
    testError = nil;
    NSData *unexpectedLine = [reader readLine:&testError];
    close(sockets[0]);
    if (!SelfTestAssert(unexpectedLine == nil &&
                        testError.code == EC20CTLErrorUnexpectedEOF,
                        @"mid-record EOF was not rejected",
                        error)) {
        return NO;
    }

    return YES;
}

typedef NS_ENUM(NSInteger, EC20CTLCommand) {
    EC20CTLCommandNone,
    EC20CTLCommandHello,
    EC20CTLCommandList,
    EC20CTLCommandAT,
    EC20CTLCommandSelfTest,
};

@interface EC20CTLOptions : NSObject

@property(nonatomic) EC20CTLCommand command;
@property(nonatomic, copy) NSString *socketPath;
@property(nonatomic, copy, nullable) NSString *atCommand;
@property(nonatomic, copy, nullable) NSString *instanceIdentifier;

@end


@implementation EC20CTLOptions
@end


static void PrintUsage(FILE *stream)
{
    fprintf(stream,
            "usage:\n"
            "  ec20ctl [--socket PATH] hello\n"
            "  ec20ctl [--socket PATH] list\n"
            "  ec20ctl [--socket PATH] at COMMAND [--instance INSTANCE_ID]\n"
            "  ec20ctl --self-test\n");
}

static NSString *ArgumentString(const char *argument, NSError **error)
{
    NSString *value = [NSString stringWithUTF8String:argument];
    if (value == nil) {
        AssignError(error,
                    ClientError(EC20CTLErrorUsage,
                                @"Command-line argument is not valid UTF-8."));
    }
    return value;
}

static EC20CTLOptions *ParseOptions(int argumentCount,
                                    const char *arguments[],
                                    NSError **error)
{
    EC20CTLOptions *options = [[EC20CTLOptions alloc] init];
    const char *environmentPath = getenv("EC20D_SOCKET");
    if (environmentPath != NULL && environmentPath[0] != '\0') {
        options.socketPath = ArgumentString(environmentPath, error);
        if (options.socketPath == nil) {
            return nil;
        }
    } else {
        options.socketPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"ec20d.sock"];
    }

    if (argumentCount == 2 && strcmp(arguments[1], "--self-test") == 0) {
        options.command = EC20CTLCommandSelfTest;
        return options;
    }

    int index = 1;
    if (index < argumentCount && strcmp(arguments[index], "--socket") == 0) {
        if (index + 1 >= argumentCount) {
            AssignError(error,
                        ClientError(EC20CTLErrorUsage,
                                    @"--socket requires a path."));
            return nil;
        }
        options.socketPath = ArgumentString(arguments[index + 1], error);
        if (options.socketPath.length == 0) {
            if (error != NULL && *error == nil) {
                *error = ClientError(EC20CTLErrorUsage,
                                     @"--socket requires a non-empty path.");
            }
            return nil;
        }
        index += 2;
    }

    if (index >= argumentCount) {
        AssignError(error,
                    ClientError(EC20CTLErrorUsage,
                                @"A command is required."));
        return nil;
    }
    const char *command = arguments[index++];
    if (strcmp(command, "hello") == 0) {
        options.command = EC20CTLCommandHello;
    } else if (strcmp(command, "list") == 0) {
        options.command = EC20CTLCommandList;
    } else if (strcmp(command, "at") == 0) {
        options.command = EC20CTLCommandAT;
    } else {
        AssignError(error,
                    ClientError(EC20CTLErrorUsage,
                                @"Unknown command."));
        return nil;
    }

    if (options.command == EC20CTLCommandHello || options.command == EC20CTLCommandList) {
        if (index != argumentCount) {
            AssignError(error,
                        ClientError(EC20CTLErrorUsage,
                                    @"This command does not accept additional arguments."));
            return nil;
        }
        return options;
    }

    if (index >= argumentCount) {
        AssignError(error,
                    ClientError(EC20CTLErrorUsage,
                                @"at requires a command string."));
        return nil;
    }
    options.atCommand = ArgumentString(arguments[index++], error);
    if (options.atCommand == nil) {
        return nil;
    }
    while (index < argumentCount) {
        if (strcmp(arguments[index], "--instance") != 0 ||
            options.instanceIdentifier != nil ||
            index + 1 >= argumentCount) {
            AssignError(error,
                        ClientError(EC20CTLErrorUsage,
                                    @"Invalid at option; expected --instance INSTANCE_ID."));
            return nil;
        }
        options.instanceIdentifier = ArgumentString(arguments[index + 1], error);
        if (options.instanceIdentifier.length == 0) {
            if (error != NULL && *error == nil) {
                *error = ClientError(EC20CTLErrorUsage,
                                     @"--instance requires a non-empty identifier.");
            }
            return nil;
        }
        index += 2;
    }
    return options;
}

static void PrintError(NSError *error)
{
    NSString *description = SafeDiagnosticText(error.localizedDescription);
    const char *text = description.UTF8String;
    fprintf(stderr, "ec20ctl: %s\n", text != NULL ? text : "operation failed");
}

int main(int argumentCount, const char *arguments[])
{
    @autoreleasepool {
        // Broken stdout pipes and disconnected AF_UNIX peers are reported as
        // EPIPE errors instead of terminating the process asynchronously.
        (void)signal(SIGPIPE, SIG_IGN);

        NSError *error = nil;
        EC20CTLOptions *options = ParseOptions(argumentCount, arguments, &error);
        if (options == nil) {
            PrintError(error);
            PrintUsage(stderr);
            return 2;
        }

        if (options.command == EC20CTLCommandSelfTest) {
            if (!RunSelfTests(&error)) {
                PrintError(error);
                return 1;
            }
            fprintf(stdout, "ec20ctl self-test: PASS\n");
            return 0;
        }

        EC20CTLClient *client = [[EC20CTLClient alloc]
            initWithSocketPath:options.socketPath
                         error:&error];
        if (client == nil) {
            PrintError(error);
            return 1;
        }

        BOOL succeeded = NO;
        switch (options.command) {
            case EC20CTLCommandHello:
                succeeded = RunHello(client, &error);
                break;
            case EC20CTLCommandList:
                succeeded = RunList(client, &error);
                break;
            case EC20CTLCommandAT:
                succeeded = RunAT(client,
                                  options.atCommand,
                                  options.instanceIdentifier,
                                  &error);
                break;
            case EC20CTLCommandNone:
            case EC20CTLCommandSelfTest:
                error = ClientError(EC20CTLErrorUsage, @"Invalid command state.");
                succeeded = NO;
                break;
        }
        if (!succeeded) {
            PrintError(error);
            return 1;
        }
        return 0;
    }
}
