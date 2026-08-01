#import "EC20USBNetwork.h"

#import <IOKit/IOKitLib.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>

NSErrorDomain const EC20USBNetworkErrorDomain = @"EC20USBNetworkErrorDomain";

static const uint16_t kEC20VendorID = 0x2c7c;
static const uint16_t kEC20ProductID = 0x0125;
static const uint8_t kEC20NetworkInterfaceNumber = 4;
static const uint8_t kCDCCommunicationClass = 2;
static const uint8_t kCDCEthernetControlModelSubclass = 6;

@interface EC20USBNetworkState ()

@property(nonatomic, readwrite) uint32_t locationID;
@property(nonatomic, copy, readwrite) NSString *interfaceName;
@property(nonatomic, readwrite) unsigned int interfaceIndex;
@property(nonatomic, readwrite, getter=isLinkActive) BOOL linkActive;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *addresses;

@end


@implementation EC20USBNetworkState
@end

static NSError *NetworkError(EC20USBNetworkErrorCode code,
                             NSString *description,
                             kern_return_t ioReturn)
{
    NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo =
        [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (ioReturn != kIOReturnSuccess) {
        userInfo[@"IOReturn"] = @((uint32_t)ioReturn);
    }
    return [NSError errorWithDomain:EC20USBNetworkErrorDomain
                               code:code
                           userInfo:userInfo];
}

static NSNumber *CopyNumberProperty(io_registry_entry_t entry, CFStringRef key)
{
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry,
                                                       key,
                                                       kCFAllocatorDefault,
                                                       0);
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSNumber class]] ? object : nil;
}

static NSString *CopyStringProperty(io_registry_entry_t entry, CFStringRef key)
{
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry,
                                                       key,
                                                       kCFAllocatorDefault,
                                                       0);
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSString class]] ? object : nil;
}

static NSString *AddressString(const struct sockaddr *address,
                               NSString *interfaceName)
{
    if (address == NULL) {
        return nil;
    }
    char buffer[INET6_ADDRSTRLEN] = {0};
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)address;
        if (inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
        return [NSString stringWithUTF8String:buffer];
    }
    if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)address;
        if (inet_ntop(AF_INET6, &ipv6->sin6_addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
        NSString *text = [NSString stringWithUTF8String:buffer];
        if (text == nil) {
            return nil;
        }
        if (IN6_IS_ADDR_LINKLOCAL(&ipv6->sin6_addr)) {
            return [NSString stringWithFormat:@"%@%%%@", text, interfaceName];
        }
        return text;
    }
    return nil;
}

static void ReadInterfaceState(EC20USBNetworkState *state)
{
    NSMutableOrderedSet<NSString *> *addresses = [NSMutableOrderedSet orderedSet];
    BOOL sawInterface = NO;
    BOOL up = NO;
    BOOL running = NO;
    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) != 0) {
        state.addresses = @[];
        state.linkActive = NO;
        return;
    }
    @try {
        for (const struct ifaddrs *cursor = head;
             cursor != NULL;
             cursor = cursor->ifa_next) {
            if (cursor->ifa_name == NULL ||
                strcmp(cursor->ifa_name, state.interfaceName.UTF8String) != 0) {
                continue;
            }
            sawInterface = YES;
            up = up || (cursor->ifa_flags & IFF_UP) != 0;
            running = running || (cursor->ifa_flags & IFF_RUNNING) != 0;
            NSString *text = AddressString(cursor->ifa_addr, state.interfaceName);
            if (text != nil) {
                [addresses addObject:text];
            }
        }
    } @finally {
        freeifaddrs(head);
    }
    state.addresses = [[addresses array]
        sortedArrayUsingSelector:@selector(compare:)];
    state.linkActive = sawInterface && up && running;
}

static EC20USBNetworkState *StateFromNetworkService(io_service_t service)
{
    NSString *userClass = CopyStringProperty(service, CFSTR("IOUserClass"));
    NSString *interfaceName = CopyStringProperty(service, CFSTR("IOInterfaceName"));
    if (![userClass isEqualToString:@"AppleUserECM"] ||
        interfaceName.length == 0 || interfaceName.length >= IFNAMSIZ) {
        return nil;
    }

    io_registry_entry_t parent = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) !=
        kIOReturnSuccess) {
        return nil;
    }
    @try {
        NSNumber *vendor = CopyNumberProperty(parent, CFSTR("idVendor"));
        NSNumber *product = CopyNumberProperty(parent, CFSTR("idProduct"));
        NSNumber *interfaceNumber =
            CopyNumberProperty(parent, CFSTR("bInterfaceNumber"));
        NSNumber *interfaceClass =
            CopyNumberProperty(parent, CFSTR("bInterfaceClass"));
        NSNumber *interfaceSubclass =
            CopyNumberProperty(parent, CFSTR("bInterfaceSubClass"));
        NSNumber *location = CopyNumberProperty(parent, CFSTR("locationID"));
        if (vendor.unsignedIntValue != kEC20VendorID ||
            product.unsignedIntValue != kEC20ProductID ||
            interfaceNumber.unsignedIntValue != kEC20NetworkInterfaceNumber ||
            interfaceClass.unsignedIntValue != kCDCCommunicationClass ||
            interfaceSubclass.unsignedIntValue !=
                kCDCEthernetControlModelSubclass ||
            location == nil || location.unsignedIntValue == 0) {
            return nil;
        }

        unsigned int index = if_nametoindex(interfaceName.UTF8String);
        if (index == 0) {
            return nil;
        }
        EC20USBNetworkState *state = [[EC20USBNetworkState alloc] init];
        state.locationID = location.unsignedIntValue;
        state.interfaceName = interfaceName;
        state.interfaceIndex = index;
        ReadInterfaceState(state);
        return state;
    } @finally {
        IOObjectRelease(parent);
    }
}

@implementation EC20USBNetwork

+ (NSDictionary<NSNumber *, EC20USBNetworkState *> *)
    enumerateECMInterfacesWithError:(NSError **)error
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOUserNetworkEthernet");
    if (matching == NULL) {
        if (error != NULL) {
            *error = NetworkError(EC20USBNetworkErrorEnumeration,
                                  @"Could not create the ECM service match.",
                                  kIOReturnNoMemory);
        }
        return nil;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                         matching,
                                                         &iterator);
    if (result != kIOReturnSuccess) {
        if (error != NULL) {
            *error = NetworkError(EC20USBNetworkErrorEnumeration,
                                  @"Could not enumerate ECM network services.",
                                  result);
        }
        return nil;
    }

    NSMutableDictionary<NSNumber *, EC20USBNetworkState *> *states =
        [NSMutableDictionary dictionary];
    @try {
        io_service_t service;
        while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            @autoreleasepool {
                EC20USBNetworkState *state = StateFromNetworkService(service);
                IOObjectRelease(service);
                if (state == nil) {
                    continue;
                }
                NSNumber *key = @(state.locationID);
                if (states[key] != nil) {
                    if (error != NULL) {
                        *error = NetworkError(
                            EC20USBNetworkErrorDuplicateInterface,
                            @"More than one AppleUserECM interface maps to one EC20 attachment.",
                            kIOReturnSuccess);
                    }
                    return nil;
                }
                states[key] = state;
            }
        }
    } @finally {
        IOObjectRelease(iterator);
    }
    return [states copy];
}

@end
