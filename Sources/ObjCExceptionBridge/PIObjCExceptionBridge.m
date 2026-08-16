#import "PIObjCExceptionBridge.h"

NSErrorDomain const PIObjCExceptionErrorDomain = @"com.pluginput.objc-exception";
NSString *const PIObjCExceptionNameKey = @"PIObjCExceptionName";

BOOL PIRunCatchingNSException(void(NS_NOESCAPE ^ block)(void),
                              NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            // The reason is the half worth reading — "required condition is false: nullptr ==
            // Tap()" says what went wrong, while the name only says which family it belongs to.
            // Both are kept, and the reason becomes the localized description because that is
            // what ends up rendered in the menu bar.
            *error = [NSError errorWithDomain:PIObjCExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: exception.reason ?: @"no reason given",
                                         PIObjCExceptionNameKey: exception.name ?: @"NSException",
                                     }];
        }
        return NO;
    }
}
