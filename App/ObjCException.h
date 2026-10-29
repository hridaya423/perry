#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, if any. Swift cannot
/// catch NSException, and one that unwinds through Swift task frames corrupts the
/// concurrency runtime.
NSException *_Nullable PerryCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
