//
//  FilePickerFix.m
//  ASign
//
//  A tiny constructor dylib that can be injected into signed apps. Some
//  sandboxed apps try to *open* files that live outside their container and
//  fail; forcing the system document picker into copy mode and relocating the
//  picked files into the app's own tmp directory makes those flows work.
//
//  Built by the makefile (`make tweaks`) into FilePickerFix.dylib and shipped
//  inside the signer's bundle; the signing pipeline injects it when the
//  "Fix File Picker" option is enabled.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static char const * const kASFixOriginalDelegateKey = "as_fix_original_delegate";
static char const * const kASFixModeKey = "as_fix_mode";

static void ASFixRelocateIntoContainer(NSURL *sourceURL) {
    if (!sourceURL) return;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return;

    NSString *staging = [docs stringByAppendingPathComponent:@"../tmp/FilePickerFix"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *destination = [NSURL fileURLWithPath:
        [staging stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@", [[NSUUID UUID] UUIDString], sourceURL.lastPathComponent]]];

    NSError *error = nil;
    [fm copyItemAtURL:sourceURL toURL:destination error:&error];
}

#pragma mark - Delegate forwarding shim

@interface ASFixPickerDelegateProxy : NSObject
@property (nonatomic, strong) id originalDelegate;
@end

@implementation ASFixPickerDelegateProxy

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:selector];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if ([self.originalDelegate respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)]) {
        NSInteger mode = (NSInteger)[objc_getAssociatedObject(self, (__bridge const void *)kASFixModeKey) integerValue];
        for (NSURL *url in urls) {
            // Mode 1 = Open (UIDocumentPickerModeOpen legacy value). Only
            // relocate for open-style pickers; copy mode already gives the app
            // its own copy inside the sandbox.
            if (mode == 1 && ![url.path hasPrefix:NSTemporaryDirectory()]) {
                ASFixRelocateIntoContainer(url);
            }
        }
    }
    if ([self.originalDelegate respondsToSelector:@selector(documentPicker:didPickDocumentsAtURLs:)]) {
        [self.originalDelegate documentPicker:controller didPickDocumentsAtURLs:urls];
    }
}

@end

__attribute__((constructor))
static void ASFixFilePickerInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{

        // Force copy semantics on the modern initializer.
        Method modernMethod = class_getInstanceMethod(
            [UIDocumentPickerViewController class],
            @selector(initWithDocumentTypes:inMode:)
        );
        if (modernMethod) {
            SEL newSelector = @selector(as_fix_initWithDocumentTypes:inMode:);
            Method newMethod = class_getInstanceMethod(
                [UIDocumentPickerViewController class], newSelector);
            if (newMethod) {
                method_exchangeImplementations(modernMethod, newMethod);
            }
        }

        // Force "asCopy" on the content-type initializer.
        Method copyMethod = class_getInstanceMethod(
            [UIDocumentPickerViewController class],
            @selector(initWithForOpeningContentTypes:asCopy:)
        );
        if (copyMethod) {
            SEL newSelector = @selector(as_fix_initWithForOpeningContentTypes:asCopy:);
            Method newMethod = class_getInstanceMethod(
                [UIDocumentPickerViewController class], newSelector);
            if (newMethod) {
                method_exchangeImplementations(copyMethod, newMethod);
            }
        }

        // Wrap the delegate so picked files get relocated into the sandbox.
        Method delegateMethod = class_getInstanceMethod(
            [UIDocumentPickerViewController class],
            @selector(setDelegate:)
        );
        if (delegateMethod) {
            SEL newSelector = @selector(as_fix_setDelegate:);
            Method newMethod = class_getInstanceMethod(
                [UIDocumentPickerViewController class], newSelector);
            if (newMethod) {
                method_exchangeImplementations(delegateMethod, newMethod);
            }
        }
    });
}

#pragma mark - Swizzled implementations

@implementation UIDocumentPickerViewController (ASFixFilePicker)

- (instancetype)as_fix_initWithDocumentTypes:(NSArray<NSString *> *)documentTypes inMode:(UIDocumentPickerMode)mode {
    UIDocumentPickerMode forced = (mode == UIDocumentPickerModeOpen) ? UIDocumentPickerModeImport : mode;
    return [self as_fix_initWithDocumentTypes:documentTypes inMode:forced];
}

- (instancetype)as_fix_initWithForOpeningContentTypes:(NSArray<UTType *> *)contentTypes asCopy:(BOOL)copy {
    return [self as_fix_initWithForOpeningContentTypes:contentTypes asCopy:YES];
}

- (void)as_fix_setDelegate:(id<UIDocumentPickerDelegate>)delegate {
    if (delegate == nil) {
        [self as_fix_setDelegate:nil];
        return;
    }

    ASFixPickerDelegateProxy *proxy = [[ASFixPickerDelegateProxy alloc] init];
    proxy.originalDelegate = delegate;
    objc_setAssociatedObject(proxy, (__bridge const void *)kASFixModeKey, @(1), OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, (__bridge const void *)kASFixOriginalDelegateKey, proxy, OBJC_ASSOCIATION_RETAIN);

    [self as_fix_setDelegate:proxy];
}

@end
