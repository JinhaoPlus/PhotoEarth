#import <Foundation/Foundation.h>

@interface PECachedPhotoAddress : NSObject
+ (nullable NSString *)addressForIdentifier:(nonnull NSString *)identifier
                                  latitude:(double)latitude longitude:(double)longitude
    NS_SWIFT_NAME(read(identifier:latitude:longitude:));
+ (nullable NSString *)addressFromProperties:(nonnull NSObject *)properties NS_SWIFT_NAME(validatedText(from:));
@end
