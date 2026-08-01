#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const EC20USBNetworkErrorDomain;

typedef NS_ERROR_ENUM(EC20USBNetworkErrorDomain, EC20USBNetworkErrorCode) {
    EC20USBNetworkErrorEnumeration = 1,
    EC20USBNetworkErrorDuplicateInterface,
};

// A live BSD data-plane interface that has been proven to descend from
// interface 4 of one 2c7c:0125 USB attachment.  Runtime names and addresses
// are deliberately not stable identity.
@interface EC20USBNetworkState : NSObject

@property(nonatomic, readonly) uint32_t locationID;
@property(nonatomic, copy, readonly) NSString *interfaceName;
@property(nonatomic, readonly) unsigned int interfaceIndex;
@property(nonatomic, readonly, getter=isLinkActive) BOOL linkActive;
@property(nonatomic, copy, readonly) NSArray<NSString *> *addresses;

@end

@interface EC20USBNetwork : NSObject

// Returns ECM interfaces keyed by their USB location ID.  The lookup validates
// the IORegistry parent relationship; it never associates devices by enX unit.
+ (nullable NSDictionary<NSNumber *, EC20USBNetworkState *> *)
    enumerateECMInterfacesWithError:(NSError * _Nullable * _Nullable)error;

@end


NS_ASSUME_NONNULL_END
