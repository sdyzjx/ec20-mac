#import "EC20PTYBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

NSErrorDomain const EC20PTYBridgeErrorDomain = @"EC20PTYBridgeErrorDomain";

static const NSUInteger kMaximumCommandBytes = 4096;
static const NSUInteger kMaximumInteractiveBytes = 64 * 1024;
static const uint8_t kStandardErrorResponse[] = "\r\nERROR\r\n";
static const uint8_t kStandardPromptResponse[] = "\r\n> ";

static NSError *BridgeError(EC20PTYBridgeErrorCode code,
                            NSString *description,
                            int systemError)
{
    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description;
    if (systemError != 0) {
        userInfo[NSUnderlyingErrorKey] =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:systemError userInfo:nil];
    }
    return [NSError errorWithDomain:EC20PTYBridgeErrorDomain
                               code:code
                           userInfo:userInfo];
}

static void AssignError(NSError **destination, NSError *error)
{
    if (destination != NULL) {
        *destination = error;
    }
}

static BOOL SetCloseOnExec(int fileDescriptor)
{
    int flags;
    do {
        flags = fcntl(fileDescriptor, F_GETFD);
    } while (flags < 0 && errno == EINTR);
    if (flags < 0) {
        return NO;
    }

    int result;
    do {
        result = fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC);
    } while (result < 0 && errno == EINTR);
    return result == 0;
}

static BOOL SetNonBlocking(int fileDescriptor)
{
    int flags;
    do {
        flags = fcntl(fileDescriptor, F_GETFL);
    } while (flags < 0 && errno == EINTR);
    if (flags < 0) {
        return NO;
    }

    int result;
    do {
        result = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK);
    } while (result < 0 && errno == EINTR);
    return result == 0;
}

static void CloseFileDescriptor(int fileDescriptor)
{
    if (fileDescriptor < 0) {
        return;
    }
    // Do not retry close(2) after EINTR: the descriptor state is unspecified
    // and a retry could close a descriptor reused by another thread.
    (void)close(fileDescriptor);
}

static BOOL ConfigureRawSlave(int slaveFileDescriptor, NSError **error)
{
    struct termios attributes;
    int result;
    do {
        result = tcgetattr(slaveFileDescriptor, &attributes);
    } while (result < 0 && errno == EINTR);
    if (result != 0) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYConfiguration,
                                @"Could not read PTY terminal attributes.",
                                errno));
        return NO;
    }

    cfmakeraw(&attributes);
    attributes.c_cflag |= CLOCAL | CREAD;
    attributes.c_cc[VMIN] = 1;
    attributes.c_cc[VTIME] = 0;
    do {
        result = tcsetattr(slaveFileDescriptor, TCSANOW, &attributes);
    } while (result < 0 && errno == EINTR);
    if (result != 0) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYConfiguration,
                                @"Could not put the PTY into raw mode.",
                                errno));
        return NO;
    }

    do {
        result = fchmod(slaveFileDescriptor, 0600);
    } while (result < 0 && errno == EINTR);
    if (result != 0) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYConfiguration,
                                @"Could not restrict PTY slave permissions.",
                                errno));
        return NO;
    }

    struct stat status;
    do {
        result = fstat(slaveFileDescriptor, &status);
    } while (result < 0 && errno == EINTR);
    if (result != 0 || status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0600 || !S_ISCHR(status.st_mode)) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYConfiguration,
                                @"PTY slave ownership or mode verification failed.",
                                result == 0 ? 0 : errno));
        return NO;
    }

    do {
        result = tcflush(slaveFileDescriptor, TCIOFLUSH);
    } while (result < 0 && errno == EINTR);
    if (result != 0) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYConfiguration,
                                @"Could not flush the new PTY.",
                                errno));
        return NO;
    }
    return YES;
}

@interface EC20PTYBridgeWorker : NSObject

@property(nonatomic) int masterFileDescriptor;
@property(nonatomic) int slaveAnchorFileDescriptor;
@property(nonatomic) int stopReadFileDescriptor;
@property(nonatomic) int stopWriteFileDescriptor;
@property(nonatomic, copy) EC20PTYCommandHandler handler;
@property(nonatomic, copy, nullable) EC20PTYInteractiveCommandMatcher interactiveMatcher;
@property(nonatomic, copy, nullable) EC20PTYInteractiveCommandHandler interactiveHandler;
@property(nonatomic, strong) NSCondition *exitCondition;
@property(nonatomic, strong) NSLock *writeLock;
@property(nonatomic, copy, nullable) NSString *pendingInteractiveCommand;
@property(nonatomic, strong) NSMutableData *interactiveBuffer;
@property(nonatomic) BOOL interactiveIgnoreLeadingTerminators;
@property(nonatomic) BOOL exited;

- (instancetype)initWithMaster:(int)master
                    slaveAnchor:(int)slaveAnchor
                       stopRead:(int)stopRead
                      stopWrite:(int)stopWrite
                        handler:(EC20PTYCommandHandler)handler
             interactiveMatcher:(nullable EC20PTYInteractiveCommandMatcher)interactiveMatcher
             interactiveHandler:(nullable EC20PTYInteractiveCommandHandler)interactiveHandler;
- (void)run;
- (BOOL)writeResponse:(NSData *)response;
- (void)requestStop;
- (void)waitUntilExited;

@end

@implementation EC20PTYBridgeWorker

- (instancetype)initWithMaster:(int)master
                    slaveAnchor:(int)slaveAnchor
                       stopRead:(int)stopRead
                      stopWrite:(int)stopWrite
                        handler:(EC20PTYCommandHandler)handler
             interactiveMatcher:(EC20PTYInteractiveCommandMatcher)interactiveMatcher
             interactiveHandler:(EC20PTYInteractiveCommandHandler)interactiveHandler
{
    self = [super init];
    if (self != nil) {
        _masterFileDescriptor = master;
        _slaveAnchorFileDescriptor = slaveAnchor;
        _stopReadFileDescriptor = stopRead;
        _stopWriteFileDescriptor = stopWrite;
        _handler = [handler copy];
        _interactiveMatcher = [interactiveMatcher copy];
        _interactiveHandler = [interactiveHandler copy];
        _exitCondition = [[NSCondition alloc] init];
        _writeLock = [[NSLock alloc] init];
        _interactiveBuffer = [NSMutableData data];
    }
    return self;
}

- (BOOL)writeResponse:(NSData *)response
{
    [self.writeLock lock];
    @try {
        if (self.masterFileDescriptor < 0) {
            return NO;
        }
        const uint8_t *bytes = response.bytes;
        NSUInteger offset = 0;
        while (offset < response.length) {
            ssize_t count = write(self.masterFileDescriptor,
                                  bytes + offset,
                                  response.length - offset);
            if (count > 0) {
                offset += (NSUInteger)count;
                continue;
            }
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                struct pollfd descriptors[2] = {
                    { .fd = self.masterFileDescriptor, .events = POLLOUT },
                    { .fd = self.stopReadFileDescriptor, .events = POLLIN },
                };
                int pollResult;
                do {
                    pollResult = poll(descriptors, 2, -1);
                } while (pollResult < 0 && errno == EINTR);
                if (pollResult <= 0 ||
                    (descriptors[1].revents &
                        (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0 ||
                    (descriptors[0].revents & POLLNVAL) != 0) {
                    return NO;
                }
                continue;
            }
            // EIO means the slave endpoint disappeared. It is not recoverable
            // for this response, but the framing worker remains available for
            // a later client because it keeps an owner-only slave anchor open.
            return NO;
        }
        return YES;
    } @finally {
        [self.writeLock unlock];
    }
}

- (void)writeStandardError
{
    NSData *errorResponse = [NSData dataWithBytes:kStandardErrorResponse
                                            length:sizeof(kStandardErrorResponse) - 1];
    (void)[self writeResponse:errorResponse];
}

- (void)executeCommandData:(NSData *)commandData
{
    NSString *command = [[NSString alloc] initWithData:commandData
                                               encoding:NSASCIIStringEncoding];
    if (command == nil) {
        [self writeStandardError];
        return;
    }

    BOOL interactive = NO;
    @try {
        interactive = self.interactiveMatcher != nil &&
                      self.interactiveHandler != nil &&
                      self.interactiveMatcher(command);
    } @catch (__unused NSException *exception) {
        interactive = NO;
    }
    if (interactive) {
        self.pendingInteractiveCommand = command;
        [self.interactiveBuffer setLength:0];
        self.interactiveIgnoreLeadingTerminators = YES;
        NSData *prompt = [NSData dataWithBytes:kStandardPromptResponse
                                        length:sizeof(kStandardPromptResponse) - 1];
        (void)[self writeResponse:prompt];
        return;
    }

    NSData *response = nil;
    @try {
        response = self.handler(command);
    } @catch (__unused NSException *exception) {
        response = nil;
    }
    if (response == nil) {
        [self writeStandardError];
        return;
    }
    (void)[self writeResponse:response];
}

- (void)finishInteractiveRequest
{
    NSString *command = self.pendingInteractiveCommand;
    NSData *followUp = [self.interactiveBuffer copy];
    self.pendingInteractiveCommand = nil;
    [self.interactiveBuffer setLength:0];
    self.interactiveIgnoreLeadingTerminators = NO;

    NSData *response = nil;
    @try {
        response = command != nil && self.interactiveHandler != nil
            ? self.interactiveHandler(command, followUp)
            : nil;
    } @catch (__unused NSException *exception) {
        response = nil;
    }
    if (response == nil) {
        [self writeStandardError];
        return;
    }
    (void)[self writeResponse:response];
}

- (BOOL)consumeInteractiveByte:(uint8_t)byte
{
    if (self.pendingInteractiveCommand == nil) {
        return NO;
    }
    if (self.interactiveIgnoreLeadingTerminators &&
        (byte == '\r' || byte == '\n')) {
        return YES;
    }
    self.interactiveIgnoreLeadingTerminators = NO;
    if (byte == 0x1a) {
        [self finishInteractiveRequest];
        return YES;
    }
    if (byte == 0x1b) {
        self.pendingInteractiveCommand = nil;
        [self.interactiveBuffer setLength:0];
        self.interactiveIgnoreLeadingTerminators = NO;
        [self writeStandardError];
        return YES;
    }
    if (byte < 0x20 || byte > 0x7e ||
        self.interactiveBuffer.length == kMaximumInteractiveBytes) {
        self.pendingInteractiveCommand = nil;
        [self.interactiveBuffer setLength:0];
        self.interactiveIgnoreLeadingTerminators = NO;
        [self writeStandardError];
        return YES;
    }
    [self.interactiveBuffer appendBytes:&byte length:1];
    return YES;
}

- (void)consumeBytes:(const uint8_t *)bytes
               count:(NSUInteger)count
       commandBuffer:(NSMutableData *)commandBuffer
            dropping:(BOOL *)dropping
{
    for (NSUInteger index = 0; index < count; index++) {
        uint8_t byte = bytes[index];
        if ([self consumeInteractiveByte:byte]) {
            continue;
        }
        if (byte == '\r' || byte == '\n') {
            if (*dropping) {
                *dropping = NO;
                [commandBuffer setLength:0];
            } else if (commandBuffer.length != 0) {
                [self executeCommandData:[commandBuffer copy]];
                [commandBuffer setLength:0];
            }
            continue;
        }

        if (*dropping) {
            continue;
        }
        if (byte < 0x20 || byte > 0x7e ||
            commandBuffer.length == kMaximumCommandBytes) {
            [self writeStandardError];
            [commandBuffer setLength:0];
            *dropping = YES;
            continue;
        }
        [commandBuffer appendBytes:&byte length:1];
    }
}

- (void)closeOwnedDescriptors
{
    [self.writeLock lock];
    [self.exitCondition lock];
    CloseFileDescriptor(self.masterFileDescriptor);
    CloseFileDescriptor(self.slaveAnchorFileDescriptor);
    CloseFileDescriptor(self.stopReadFileDescriptor);
    CloseFileDescriptor(self.stopWriteFileDescriptor);
    self.masterFileDescriptor = -1;
    self.slaveAnchorFileDescriptor = -1;
    self.stopReadFileDescriptor = -1;
    self.stopWriteFileDescriptor = -1;
    self.exited = YES;
    [self.exitCondition broadcast];
    [self.exitCondition unlock];
    [self.writeLock unlock];
}

- (void)run
{
    @autoreleasepool {
        NSMutableData *commandBuffer = [NSMutableData data];
        BOOL dropping = NO;
        uint8_t readBuffer[4096];

        for (;;) {
            struct pollfd descriptors[2] = {
                { .fd = self.masterFileDescriptor,
                  .events = POLLIN | POLLHUP | POLLERR },
                { .fd = self.stopReadFileDescriptor,
                  .events = POLLIN | POLLHUP | POLLERR },
            };
            int pollResult;
            do {
                pollResult = poll(descriptors, 2, -1);
            } while (pollResult < 0 && errno == EINTR);
            if (pollResult < 0) {
                break;
            }
            if ((descriptors[1].revents &
                    (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0) {
                break;
            }
            if ((descriptors[0].revents & POLLNVAL) != 0) {
                break;
            }
            short masterEvents = descriptors[0].revents;
            if ((masterEvents & (POLLIN | POLLHUP | POLLERR)) == 0) {
                continue;
            }

            for (;;) {
                ssize_t count = read(self.masterFileDescriptor,
                                     readBuffer,
                                     sizeof(readBuffer));
                if (count > 0) {
                    [self consumeBytes:readBuffer
                                  count:(NSUInteger)count
                          commandBuffer:commandBuffer
                               dropping:&dropping];
                    continue;
                }
                if (count < 0 && errno == EINTR) {
                    continue;
                }
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    if ((masterEvents & (POLLHUP | POLLERR)) != 0) {
                        pollResult = -1;
                    }
                    break;
                }
                if (count == 0 || (count < 0 && errno == EIO)) {
                    pollResult = -1;
                    break;
                }
                // A permanent master error ends the worker; stop/dealloc still
                // joins it and closes all descriptors deterministically.
                pollResult = -1;
                break;
            }
            if (pollResult < 0) {
                break;
            }
        }
        [self closeOwnedDescriptors];
    }
}

- (void)requestStop
{
    [self.exitCondition lock];
    int fileDescriptor = self.stopWriteFileDescriptor;
    if (fileDescriptor >= 0 && !self.exited) {
        const uint8_t wake = 1;
        ssize_t result;
        do {
            result = write(fileDescriptor, &wake, sizeof(wake));
        } while (result < 0 && errno == EINTR);
        // EAGAIN means a previous wake byte is already pending.
        (void)result;
    }
    [self.exitCondition unlock];
}

- (void)waitUntilExited
{
    [self.exitCondition lock];
    while (!self.exited) {
        [self.exitCondition wait];
    }
    [self.exitCondition unlock];
}

@end

@interface EC20PTYBridge ()

@property(nonatomic, copy, readwrite) NSString *slavePath;
@property(nonatomic, strong) EC20PTYBridgeWorker *worker;
@property(nonatomic, strong) NSThread *workerThread;

- (instancetype)initWithSlavePath:(NSString *)slavePath
                            worker:(EC20PTYBridgeWorker *)worker
                            thread:(NSThread *)thread;

@end


@implementation EC20PTYBridge

- (instancetype)initWithSlavePath:(NSString *)slavePath
                            worker:(EC20PTYBridgeWorker *)worker
                            thread:(NSThread *)thread
{
    self = [super init];
    if (self != nil) {
        _slavePath = [slavePath copy];
        _worker = worker;
        _workerThread = thread;
    }
    return self;
}

+ (instancetype)startWithCommandHandler:(EC20PTYCommandHandler)handler
                                   error:(NSError **)error
{
    return [self startWithCommandHandler:handler
               interactiveCommandMatcher:nil
               interactiveCommandHandler:nil
                                   error:error];
}

+ (instancetype)startWithCommandHandler:(EC20PTYCommandHandler)handler
               interactiveCommandMatcher:(EC20PTYInteractiveCommandMatcher)interactiveMatcher
               interactiveCommandHandler:(EC20PTYInteractiveCommandHandler)interactiveHandler
                                   error:(NSError **)error
{
    if (handler == nil) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorInvalidHandler,
                                @"A PTY command handler is required.",
                                0));
        return nil;
    }
    if ((interactiveMatcher == nil) != (interactiveHandler == nil)) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorInvalidHandler,
                                @"Interactive matcher and handler must be supplied together.",
                                0));
        return nil;
    }

    int master = -1;
    int slave = -1;
    char suppliedPath[PATH_MAX];
    memset(suppliedPath, 0, sizeof(suppliedPath));
    if (openpty(&master, &slave, suppliedPath, NULL, NULL) != 0) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYCreation,
                                @"Could not create a pseudoterminal.",
                                errno));
        return nil;
    }

    int stopPipe[2] = {-1, -1};
    if (!SetCloseOnExec(master) || !SetCloseOnExec(slave) ||
        !SetNonBlocking(master) ||
        pipe(stopPipe) != 0 ||
        !SetCloseOnExec(stopPipe[0]) || !SetCloseOnExec(stopPipe[1]) ||
        !SetNonBlocking(stopPipe[0]) || !SetNonBlocking(stopPipe[1])) {
        int systemError = errno;
        CloseFileDescriptor(master);
        CloseFileDescriptor(slave);
        CloseFileDescriptor(stopPipe[0]);
        CloseFileDescriptor(stopPipe[1]);
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYCreation,
                                @"Could not configure PTY worker descriptors.",
                                systemError));
        return nil;
    }

    NSError *configurationError = nil;
    if (!ConfigureRawSlave(slave, &configurationError)) {
        CloseFileDescriptor(master);
        CloseFileDescriptor(slave);
        CloseFileDescriptor(stopPipe[0]);
        CloseFileDescriptor(stopPipe[1]);
        AssignError(error, configurationError);
        return nil;
    }

    char verifiedPath[PATH_MAX];
    memset(verifiedPath, 0, sizeof(verifiedPath));
    int pathResult;
    do {
        pathResult = ttyname_r(slave, verifiedPath, sizeof(verifiedPath));
    } while (pathResult == EINTR);
    NSString *slavePath = pathResult == 0
        ? [[NSString alloc] initWithUTF8String:verifiedPath]
        : nil;
    if (slavePath.length == 0) {
        CloseFileDescriptor(master);
        CloseFileDescriptor(slave);
        CloseFileDescriptor(stopPipe[0]);
        CloseFileDescriptor(stopPipe[1]);
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorPTYCreation,
                                @"Could not determine the PTY slave path.",
                                pathResult));
        return nil;
    }

    EC20PTYBridgeWorker *worker = [[EC20PTYBridgeWorker alloc]
        initWithMaster:master
           slaveAnchor:slave
              stopRead:stopPipe[0]
             stopWrite:stopPipe[1]
               handler:handler
    interactiveMatcher:interactiveMatcher
    interactiveHandler:interactiveHandler];
    NSThread *thread = [[NSThread alloc] initWithTarget:worker
                                               selector:@selector(run)
                                                 object:nil];
    thread.name = @"ec20.pty.bridge";

    EC20PTYBridge *bridge = [[self alloc] initWithSlavePath:slavePath
                                                     worker:worker
                                                     thread:thread];
    [thread start];
    return bridge;
}

- (BOOL)injectUnsolicitedData:(NSData *)data error:(NSError **)error
{
    static const NSUInteger maximumUnsolicitedBytes = 64 * 1024;
    if (data.length == 0 || data.length > maximumUnsolicitedBytes) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorInvalidUnsolicitedData,
                                @"Unsolicited PTY data must contain 1..65536 bytes.",
                                0));
        return NO;
    }

    EC20PTYBridgeWorker *worker;
    @synchronized (self) {
        worker = self.worker;
    }
    if (worker == nil) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorNotRunning,
                                @"The PTY bridge is not running.",
                                0));
        return NO;
    }
    if (![worker writeResponse:data]) {
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorWriteFailed,
                                @"Could not write unsolicited PTY data.",
                                errno));
        return NO;
    }
    return YES;
}

- (void)stop
{
    EC20PTYBridgeWorker *worker;
    NSThread *thread;
    @synchronized (self) {
        worker = self.worker;
        thread = self.workerThread;
    }
    if (worker == nil) {
        return;
    }

    [worker requestStop];
    if (NSThread.currentThread != thread) {
        [worker waitUntilExited];
    }

    @synchronized (self) {
        if (worker.exited) {
            self.worker = nil;
            self.workerThread = nil;
        }
    }
}

- (void)dealloc
{
    [self stop];
}

static BOOL TestWriteAll(int fileDescriptor, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = write(fileDescriptor, bytes + offset, data.length - offset);
        if (count > 0) {
            offset += (NSUInteger)count;
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd descriptor = { .fd = fileDescriptor, .events = POLLOUT };
            int result;
            do {
                result = poll(&descriptor, 1, 1000);
            } while (result < 0 && errno == EINTR);
            if (result > 0) {
                continue;
            }
        }
        return NO;
    }
    return YES;
}

static NSData *TestReadExactly(int fileDescriptor,
                               NSUInteger expectedLength,
                               NSTimeInterval timeout)
{
    NSMutableData *received = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (received.length < expectedLength) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) {
            return nil;
        }
        NSTimeInterval remainingMilliseconds = remaining * 1000.0;
        int milliseconds = remainingMilliseconds < (NSTimeInterval)INT_MAX
            ? (int)remainingMilliseconds
            : INT_MAX;
        if (milliseconds < 1) {
            milliseconds = 1;
        }
        struct pollfd descriptor = { .fd = fileDescriptor, .events = POLLIN };
        int pollResult;
        do {
            pollResult = poll(&descriptor, 1, milliseconds);
        } while (pollResult < 0 && errno == EINTR);
        if (pollResult <= 0) {
            return nil;
        }

        uint8_t buffer[4096];
        NSUInteger remainingBytes = expectedLength - received.length;
        NSUInteger wanted = remainingBytes < sizeof(buffer)
            ? remainingBytes
            : sizeof(buffer);
        ssize_t count = read(fileDescriptor, buffer, wanted);
        if (count > 0) {
            [received appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        return nil;
    }
    return received;
}

static BOOL SelfTestFailure(NSString *message, NSError **error)
{
    AssignError(error,
                BridgeError(EC20PTYBridgeErrorSelfTest,
                            message,
                            0));
    return NO;
}

+ (BOOL)runSelfTestsWithError:(NSError **)error
{
    EC20PTYCommandHandler handler = ^NSData *(NSString *command) {
        NSString *response = [NSString stringWithFormat:@"\r\n%@\r\r\nOK\r\n", command];
        return [response dataUsingEncoding:NSASCIIStringEncoding];
    };
    __block BOOL interactiveHandlerCalled = NO;
    EC20PTYInteractiveCommandMatcher matcher = ^BOOL(NSString *command) {
        return [command isEqualToString:@"AT+CMGS=15"];
    };
    EC20PTYInteractiveCommandHandler interactiveHandler =
        ^NSData *(NSString *command, NSData *followUp) {
        NSData *expected = [@"001122AABB" dataUsingEncoding:NSASCIIStringEncoding];
        if (![command isEqualToString:@"AT+CMGS=15"] ||
            ![followUp isEqualToData:expected]) {
            return nil;
        }
        interactiveHandlerCalled = YES;
        return [@"\r\n+CMGS: 7\r\n\r\nOK\r\n"
            dataUsingEncoding:NSASCIIStringEncoding];
    };
    NSError *startError = nil;
    EC20PTYBridge *bridge = [self startWithCommandHandler:handler
                                interactiveCommandMatcher:matcher
                                interactiveCommandHandler:interactiveHandler
                                                    error:&startError];
    if (bridge == nil) {
        AssignError(error, startError);
        return NO;
    }

    int slave = open(bridge.slavePath.fileSystemRepresentation,
                     O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (slave < 0) {
        int systemError = errno;
        [bridge stop];
        AssignError(error,
                    BridgeError(EC20PTYBridgeErrorSelfTest,
                                @"Self-test could not open the PTY slave.",
                                systemError));
        return NO;
    }
    (void)SetCloseOnExec(slave);

    NSData *fragment1 = [@"A" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *fragment2 = [@"T\r" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *expectedAT = [@"\r\nAT\r\r\nOK\r\n"
        dataUsingEncoding:NSASCIIStringEncoding];
    if (!TestWriteAll(slave, fragment1) || !TestWriteAll(slave, fragment2) ||
        ![TestReadExactly(slave, expectedAT.length, 2.0) isEqualToData:expectedAT]) {
        CloseFileDescriptor(slave);
        [bridge stop];
        return SelfTestFailure(@"Fragmented AT framing self-test failed.", error);
    }

    NSData *batched = [@"ATI\rAT+CSQ\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *expectedBatch = [@"\r\nATI\r\r\nOK\r\n\r\nAT+CSQ\r\r\nOK\r\n"
        dataUsingEncoding:NSASCIIStringEncoding];
    if (!TestWriteAll(slave, batched) ||
        ![TestReadExactly(slave, expectedBatch.length, 2.0)
            isEqualToData:expectedBatch]) {
        CloseFileDescriptor(slave);
        [bridge stop];
        return SelfTestFailure(@"Batched command framing self-test failed.", error);
    }

    NSData *interactiveCommand = [@"AT+CMGS=15\r\n"
        dataUsingEncoding:NSASCIIStringEncoding];
    NSData *expectedPrompt = [NSData dataWithBytes:kStandardPromptResponse
                                             length:sizeof(kStandardPromptResponse) - 1];
    NSData *interactivePayloadPart1 = [@"001122"
        dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *interactivePayloadPart2 = [[@"AABB"
        dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    const uint8_t controlZ = 0x1a;
    [interactivePayloadPart2 appendBytes:&controlZ length:1];
    NSData *expectedInteractiveResponse = [@"\r\n+CMGS: 7\r\n\r\nOK\r\n"
        dataUsingEncoding:NSASCIIStringEncoding];
    if (!TestWriteAll(slave, interactiveCommand) ||
        ![TestReadExactly(slave, expectedPrompt.length, 2.0)
            isEqualToData:expectedPrompt] ||
        !TestWriteAll(slave, interactivePayloadPart1) ||
        !TestWriteAll(slave, interactivePayloadPart2) ||
        ![TestReadExactly(slave, expectedInteractiveResponse.length, 2.0)
            isEqualToData:expectedInteractiveResponse] ||
        !interactiveHandlerCalled) {
        CloseFileDescriptor(slave);
        [bridge stop];
        return SelfTestFailure(@"Interactive prompt/Ctrl-Z self-test failed.", error);
    }

    NSData *unsolicited = [@"\r\n+CUSD: 0,\"Mock balance\",15\r\n"
        dataUsingEncoding:NSASCIIStringEncoding];
    NSError *injectError = nil;
    if (![bridge injectUnsolicitedData:unsolicited error:&injectError] ||
        ![TestReadExactly(slave, unsolicited.length, 2.0)
            isEqualToData:unsolicited]) {
        CloseFileDescriptor(slave);
        [bridge stop];
        if (injectError != nil) {
            AssignError(error, injectError);
            return NO;
        }
        return SelfTestFailure(@"Unsolicited PTY write self-test failed.", error);
    }

    NSMutableData *overflow = [NSMutableData dataWithLength:kMaximumCommandBytes + 1];
    memset(overflow.mutableBytes, 'A', overflow.length);
    const uint8_t recovery[] = "\rAT\r";
    [overflow appendBytes:recovery length:sizeof(recovery) - 1];
    NSData *standardError = [NSData dataWithBytes:kStandardErrorResponse
                                            length:sizeof(kStandardErrorResponse) - 1];
    NSMutableData *expectedRecovery = [standardError mutableCopy];
    [expectedRecovery appendData:expectedAT];
    if (!TestWriteAll(slave, overflow) ||
        ![TestReadExactly(slave, expectedRecovery.length, 2.0)
            isEqualToData:expectedRecovery]) {
        CloseFileDescriptor(slave);
        [bridge stop];
        return SelfTestFailure(@"Oversized command recovery self-test failed.", error);
    }

    CloseFileDescriptor(slave);
    [bridge stop];
    [bridge stop];
    if ([bridge injectUnsolicitedData:unsolicited error:NULL]) {
        return SelfTestFailure(@"Stopped PTY accepted unsolicited data.", error);
    }
    return YES;
}

@end
