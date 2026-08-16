//
//  PIObjCExceptionBridge.h
//
//  The one Objective-C frame in this project, and it exists for one reason: Swift cannot @catch.
//
//  AVAudioEngine's graph API — installTap, attach, connect, detach, removeTap, prepare — signals
//  misuse by *raising* an NSException rather than returning an error. That exception unwinds
//  straight past every Swift do/catch and aborts the process, which is how a leaked input tap
//  turned into three crash reports on 2026-08-14 (gotcha #14). Wrapping those calls in a frame
//  that can @catch converts the whole family into ordinary Swift errors.
//
//  See withGraphBarrier(_:_:) in AudioCore for the Swift side, and the rules on using it —
//  in particular that a caught exception leaves the audio graph in an undefined state, so the
//  only correct response is to tear it down rather than carry on.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain of the NSError produced from a caught exception.
extern NSErrorDomain const PIObjCExceptionErrorDomain;

/// userInfo key carrying the NSException's name, e.g. "NSInternalInconsistencyException".
extern NSString *const PIObjCExceptionNameKey;

/// Runs `block`, catching any Objective-C exception it raises.
///
/// Returns YES when the block completed normally. Returns NO and populates `error` when an
/// NSException was raised; that error carries the exception's reason as its localized
/// description and its name under `PIObjCExceptionNameKey`.
///
/// `block` is non-escaping — called exactly once, before this function returns. The NS_NOESCAPE
/// is load-bearing rather than documentation: it is what lets the Swift wrapper write the
/// block's outcome into a local variable.
///
/// Note the limits. This catches NSException, which is what the AVFoundation misuse family
/// actually raises; a C++ exception thrown from inside CoreAudio would not be caught. And
/// unwinding past Swift frames skips their ARC cleanup, so a catch leaks. Both are acceptable
/// against the alternative, which is termination.
BOOL PIRunCatchingNSException(void(NS_NOESCAPE ^ block)(void),
                              NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
