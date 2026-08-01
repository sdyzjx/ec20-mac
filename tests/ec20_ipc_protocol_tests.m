#import <Foundation/Foundation.h>

#import "EC20IPCProtocol.h"

#include <stdio.h>

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        if (!EC20IPCProtocolRunSelfTests(&error)) {
            const char *description = error.localizedDescription.UTF8String;
            fprintf(stderr,
                    "ec20 IPC protocol self-test failed: %s\n",
                    description != NULL ? description : "unknown error");
            return 1;
        }

        fprintf(stdout, "ec20 IPC protocol self-test: PASS\n");
        return 0;
    }
}
