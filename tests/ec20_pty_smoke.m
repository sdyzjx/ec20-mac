#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

enum {
    kSmokeTimeoutMilliseconds = 3000,
    kMaximumResponseBytes = 64 * 1024,
};

typedef enum {
    TerminalPending = 0,
    TerminalOK,
    TerminalError,
} TerminalState;

static void PrintUsage(const char *program)
{
    fprintf(stderr,
            "usage: %s /dev/ttysNNN [READ_ONLY_AT_COMMAND]\n"
            "allowed commands: AT, ATI, AT+GMR, AT+QCFG=\"usbnet\"\n",
            program);
}

static bool IsAllowedCommand(const char *command)
{
    static const char *const commands[] = {
        "AT",
        "ATI",
        "AT+GMR",
        "AT+QCFG=\"usbnet\"",
    };

    if (command == NULL || command[0] == '\0') {
        return false;
    }
    for (size_t index = 0; index < sizeof(commands) / sizeof(commands[0]); index++) {
        if (strcmp(command, commands[index]) == 0) {
            return true;
        }
    }
    return false;
}

static bool MonotonicNanoseconds(uint64_t *value)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return false;
    }
    *value = (uint64_t)now.tv_sec * UINT64_C(1000000000) +
             (uint64_t)now.tv_nsec;
    return true;
}

static int RemainingMilliseconds(uint64_t deadlineNanoseconds)
{
    uint64_t now = 0;
    if (!MonotonicNanoseconds(&now) || now >= deadlineNanoseconds) {
        return 0;
    }

    uint64_t remaining = deadlineNanoseconds - now;
    uint64_t milliseconds = (remaining + UINT64_C(999999)) / UINT64_C(1000000);
    return milliseconds > (uint64_t)INT_MAX ? INT_MAX : (int)milliseconds;
}

// Returns 1 when ready, 0 on deadline, and -1 on an error.
static int WaitForDescriptor(int descriptor,
                             short events,
                             uint64_t deadlineNanoseconds,
                             short *returnedEvents)
{
    for (;;) {
        int timeout = RemainingMilliseconds(deadlineNanoseconds);
        if (timeout == 0) {
            return 0;
        }

        struct pollfd item = {
            .fd = descriptor,
            .events = events,
            .revents = 0,
        };
        int result = poll(&item, 1, timeout);
        if (result > 0) {
            if (returnedEvents != NULL) {
                *returnedEvents = item.revents;
            }
            return 1;
        }
        if (result == 0) {
            return 0;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
}

static bool WriteAllWithDeadline(int descriptor,
                                 const uint8_t *bytes,
                                 size_t length,
                                 uint64_t deadlineNanoseconds)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(descriptor, bytes + offset, length - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            short events = 0;
            int ready = WaitForDescriptor(descriptor,
                                          POLLOUT,
                                          deadlineNanoseconds,
                                          &events);
            if (ready <= 0) {
                if (ready == 0) {
                    errno = ETIMEDOUT;
                }
                return false;
            }
            if ((events & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                errno = EIO;
                return false;
            }
            continue;
        }
        if (written == 0) {
            errno = EIO;
        }
        return false;
    }
    return true;
}

static bool BytesEqualASCII(const uint8_t *bytes,
                            size_t length,
                            const char *text)
{
    size_t textLength = strlen(text);
    return length == textLength && memcmp(bytes, text, length) == 0;
}

static bool BytesHaveASCIIPrefix(const uint8_t *bytes,
                                 size_t length,
                                 const char *prefix)
{
    size_t prefixLength = strlen(prefix);
    return length >= prefixLength && memcmp(bytes, prefix, prefixLength) == 0;
}

static TerminalState TerminalStateForResponse(const uint8_t *bytes, size_t length)
{
    size_t lineStart = 0;
    for (size_t index = 0; index < length; index++) {
        if (bytes[index] != '\r' && bytes[index] != '\n') {
            continue;
        }

        size_t start = lineStart;
        size_t end = index;
        while (start < end && (bytes[start] == ' ' || bytes[start] == '\t')) {
            start++;
        }
        while (end > start && (bytes[end - 1] == ' ' || bytes[end - 1] == '\t')) {
            end--;
        }

        const uint8_t *line = bytes + start;
        size_t lineLength = end - start;
        if (BytesEqualASCII(line, lineLength, "OK")) {
            return TerminalOK;
        }
        if (BytesEqualASCII(line, lineLength, "ERROR") ||
            BytesHaveASCIIPrefix(line, lineLength, "+CME ERROR:") ||
            BytesHaveASCIIPrefix(line, lineLength, "+CMS ERROR:")) {
            return TerminalError;
        }
        lineStart = index + 1;
    }
    return TerminalPending;
}

int main(int argumentCount, const char *arguments[])
{
    if (argumentCount < 2 || argumentCount > 3) {
        PrintUsage(arguments[0]);
        return 64;
    }

    const char *path = arguments[1];
    const char *command = argumentCount == 3 ? arguments[2] : "AT";
    if (strncmp(path, "/dev/ttys", strlen("/dev/ttys")) != 0) {
        fprintf(stderr, "ec20-pty-smoke: refusing non-PTY path: %s\n", path);
        return 64;
    }
    if (!IsAllowedCommand(command)) {
        fprintf(stderr, "ec20-pty-smoke: command is not in the read-only allowlist\n");
        PrintUsage(arguments[0]);
        return 64;
    }

    int descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (descriptor < 0) {
        fprintf(stderr, "ec20-pty-smoke: open %s: %s\n", path, strerror(errno));
        return 1;
    }

    int exitCode = 1;
    bool termiosChanged = false;
    struct termios originalAttributes;
    if (!isatty(descriptor)) {
        fprintf(stderr, "ec20-pty-smoke: %s is not a terminal\n", path);
        goto cleanup;
    }
    if (tcgetattr(descriptor, &originalAttributes) != 0) {
        fprintf(stderr, "ec20-pty-smoke: tcgetattr: %s\n", strerror(errno));
        goto cleanup;
    }

    struct termios rawAttributes = originalAttributes;
    cfmakeraw(&rawAttributes);
    rawAttributes.c_cflag |= CLOCAL | CREAD;
    rawAttributes.c_cc[VMIN] = 0;
    rawAttributes.c_cc[VTIME] = 0;
    if (cfsetispeed(&rawAttributes, B115200) != 0 ||
        cfsetospeed(&rawAttributes, B115200) != 0 ||
        tcsetattr(descriptor, TCSANOW, &rawAttributes) != 0) {
        fprintf(stderr, "ec20-pty-smoke: configure raw termios: %s\n", strerror(errno));
        goto cleanup;
    }
    termiosChanged = true;

    if (tcflush(descriptor, TCIOFLUSH) != 0) {
        fprintf(stderr, "ec20-pty-smoke: tcflush: %s\n", strerror(errno));
        goto cleanup;
    }

    uint64_t now = 0;
    if (!MonotonicNanoseconds(&now)) {
        fprintf(stderr, "ec20-pty-smoke: clock_gettime: %s\n", strerror(errno));
        goto cleanup;
    }
    uint64_t deadline = now +
        (uint64_t)kSmokeTimeoutMilliseconds * UINT64_C(1000000);

    size_t commandLength = strlen(command);
    uint8_t *wireCommand = malloc(commandLength + 1);
    if (wireCommand == NULL) {
        fprintf(stderr, "ec20-pty-smoke: could not allocate command buffer\n");
        goto cleanup;
    }
    memcpy(wireCommand, command, commandLength);
    wireCommand[commandLength] = '\r';
    bool writeSucceeded = WriteAllWithDeadline(descriptor,
                                               wireCommand,
                                               commandLength + 1,
                                               deadline);
    free(wireCommand);
    if (!writeSucceeded) {
        fprintf(stderr, "ec20-pty-smoke: write command: %s\n", strerror(errno));
        goto cleanup;
    }

    uint8_t response[kMaximumResponseBytes];
    size_t responseLength = 0;
    for (;;) {
        short events = 0;
        int ready = WaitForDescriptor(descriptor, POLLIN, deadline, &events);
        if (ready == 0) {
            fprintf(stderr,
                    "ec20-pty-smoke: timed out after %d ms without an independent OK line\n",
                    kSmokeTimeoutMilliseconds);
            goto cleanup;
        }
        if (ready < 0) {
            fprintf(stderr, "ec20-pty-smoke: poll: %s\n", strerror(errno));
            goto cleanup;
        }
        if ((events & POLLNVAL) != 0) {
            fprintf(stderr, "ec20-pty-smoke: PTY descriptor became invalid\n");
            goto cleanup;
        }

        ssize_t bytesRead = read(descriptor,
                                 response + responseLength,
                                 sizeof(response) - responseLength);
        if (bytesRead > 0) {
            responseLength += (size_t)bytesRead;
            TerminalState state = TerminalStateForResponse(response, responseLength);
            if (state == TerminalOK) {
                printf("ec20 PTY smoke: PASS (%zu response bytes)\n", responseLength);
                exitCode = 0;
                goto cleanup;
            }
            if (state == TerminalError) {
                fprintf(stderr, "ec20-pty-smoke: modem returned a terminal error\n");
                goto cleanup;
            }
            if (responseLength == sizeof(response)) {
                fprintf(stderr,
                        "ec20-pty-smoke: response exceeded the %d-byte limit\n",
                        kMaximumResponseBytes);
                goto cleanup;
            }
            continue;
        }
        if (bytesRead < 0 && errno == EINTR) {
            continue;
        }
        if (bytesRead < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (bytesRead == 0 || (events & (POLLERR | POLLHUP)) != 0) {
            fprintf(stderr, "ec20-pty-smoke: PTY closed before returning OK\n");
            goto cleanup;
        }
        fprintf(stderr, "ec20-pty-smoke: read: %s\n", strerror(errno));
        goto cleanup;
    }

cleanup:
    if (termiosChanged && tcsetattr(descriptor, TCSANOW, &originalAttributes) != 0) {
        fprintf(stderr, "ec20-pty-smoke: restore termios: %s\n", strerror(errno));
        exitCode = 1;
    }
    if (close(descriptor) != 0) {
        fprintf(stderr, "ec20-pty-smoke: close: %s\n", strerror(errno));
        exitCode = 1;
    }
    return exitCode;
}
