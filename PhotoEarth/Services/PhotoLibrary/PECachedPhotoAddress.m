#import "PECachedPhotoAddress.h"
#import <Photos/Photos.h>
#import <CoreLocation/CoreLocation.h>
#import <math.h>

@implementation PECachedPhotoAddress

+ (id)read:(NSObject *)object key:(NSString *)key {
    if (![object respondsToSelector:NSSelectorFromString(key)]) return nil;
    return [object valueForKey:key];
}

+ (NSString *)addressFromProperties:(NSObject *)properties {
    @try {
        id valid = [self read:properties key:@"reverseLocationDataIsValid"];
        if (![valid isKindOfClass:NSNumber.class] || ![valid boolValue]) return nil;
        id value = [self read:properties key:@"addressString"];
        if (![value isKindOfClass:NSString.class] || [value length] > 4096) return nil;
        NSString *address = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return address.length ? address : nil;
    } @catch (NSException *exception) {
        // Do not expose exception descriptions: they can contain asset metadata.
        return nil;
    }
}

+ (BOOL)canReadLibrary {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    return status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited;
}

+ (BOOL)asset:(PHAsset *)asset matchesLatitude:(double)latitude longitude:(double)longitude {
    CLLocation *location = asset.location;
    return asset && !asset.hidden && location
        && CLLocationCoordinate2DIsValid(location.coordinate)
        && fabs(location.coordinate.latitude - latitude) < 0.0000001
        && fabs(location.coordinate.longitude - longitude) < 0.0000001;
}

+ (NSString *)addressForIdentifier:(NSString *)identifier latitude:(double)latitude longitude:(double)longitude {
    @autoreleasepool {
        @try {
            if (!identifier.length || !CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude, longitude))
                || ![self canReadLibrary]) return nil;
            PHAsset *original = [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
            if (![self asset:original matchesLatitude:latitude longitude:longitude]) return nil;
            Class propertyClass = NSClassFromString(@"PHAssetPhotosOneUpProperties");
            SEL selector = NSSelectorFromString(@"propertySetName");
            if (!propertyClass || ![propertyClass respondsToSelector:selector]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id propertySet = [propertyClass performSelector:selector];
#pragma clang diagnostic pop
            if (![propertySet isKindOfClass:NSString.class]) return nil;
            PHFetchOptions *options = [PHFetchOptions new];
            if (![options respondsToSelector:NSSelectorFromString(@"setFetchPropertySets:")]) return nil;
            [options setValue:@[propertySet] forKey:@"fetchPropertySets"];
            PHAsset *expanded = [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:options].firstObject;
            if (![self asset:expanded matchesLatitude:latitude longitude:longitude]) return nil;
            id properties = [self read:expanded key:@"photosOneUpProperties"];
            NSString *address = [properties isKindOfClass:NSObject.class] ? [self addressFromProperties:properties] : nil;
            if (!address || ![self canReadLibrary]) return nil;
            // A location edit or deletion during the read must not publish an old name.
            PHAsset *current = [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
            if (![self asset:current matchesLatitude:latitude longitude:longitude]
                || ![original.modificationDate isEqual:current.modificationDate]) return nil;
            return address;
        } @catch (NSException *exception) {
            return nil;
        }
    }
}
@end

