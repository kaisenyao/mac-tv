#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Keeps a test run away from Mac TV's real data. +load runs as the test bundle loads, before any test can reach it.
//
// Keychain: MACTV_KEYCHAIN=memory makes every Keychain user keep its items in memory, and SystemKeychain refuse
// any call that would reach the real Keychain.
//
// Folders: MACTV_DATA_DIR points AppFolder (~/Library/Application Support/Mac TV) and BrowserCache
// (~/Library/Caches/Mac TV) at a folder in the temporary folder, emptied at the start of every run.
//
// Defaults: Mac TV keeps the first profile's settings and the Mac's in UserDefaults.standard, and in a test run that
// is the test runner's own (~/Library/Preferences/swiftpm-testing-helper.plist), which every test reaching
// Preferences.shared, the screen saver's settings or phone pairing would write to. +[NSUserDefaults
// standardUserDefaults] answers with a plist in the temporary folder instead, next to TestDefaults' stores, emptied
// at the start of every run too.

static NSUserDefaults *testStandard;

@implementation NSUserDefaults (MacTVTestSandbox)

+ (void)load {
    setenv("MACTV_KEYCHAIN", "memory", 1);

    NSFileManager *files = NSFileManager.defaultManager;

    NSString *data = [NSTemporaryDirectory() stringByAppendingPathComponent:@"MacTVTests-data"];
    [files removeItemAtPath:data error:nil];
    [files createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("MACTV_DATA_DIR", data.fileSystemRepresentation, 1);

    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:@"MacTVTests-defaults"];
    [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [folder stringByAppendingPathComponent:@"standard.plist"];
    testStandard = [[NSUserDefaults alloc] initWithSuiteName:path];
    // Emptied key by key: removePersistentDomainForName: doesn't clear a plist suite.
    for (NSString *key in [testStandard persistentDomainForName:path]) [testStandard removeObjectForKey:key];
    method_exchangeImplementations(class_getClassMethod(self, @selector(standardUserDefaults)),
                                   class_getClassMethod(self, @selector(macTVTests_standardUserDefaults)));
}

+ (NSUserDefaults *)macTVTests_standardUserDefaults {
    return testStandard;
}

@end
