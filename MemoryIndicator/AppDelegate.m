//
//  AppDelegate.m
//  MemoryIndicator
//
//  Created by 马浩萌 on 2024/2/6.
//

#import "AppDelegate.h"
#import <sys/stat.h>

#define stack_logging_type_alloc    2    /* malloc, realloc, etc... */
#define stack_logging_type_dealloc    4    /* free, realloc, etc... */
#define stack_logging_type_vm_allocate  16      /* vm_allocate or mmap */
#define stack_logging_type_vm_deallocate  32    /* vm_deallocate or munmap */
#define    stack_logging_flag_zone        8    /* NSZoneMalloc, etc... */
#define stack_logging_flag_cleared    64    /* for NewEmptyHandle */
#define stack_logging_type_mapped_file_or_shared_mem 128

#define max_stack_depth_sys 64
#define md5_length 8

//#if __has_feature(objc_arc)
//#error This file must be compiled without ARC. Use -fno-objc-arc flag.
//#endif

malloc_zone_t *global_memory_zone;

void my_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip) {
    /*
     type : 内存信息类型: ... 0000 0000 0000 0000
     第1位 (1 << 0)：保留
     第2位 (1 << 1)：分配内存操作（malloc, realloc 等）
     第3位 (1 << 2)：释放内存操作（free, realloc 等）
     第4位 (1 << 3)：特殊的内存分配操作（如 NSZoneMalloc）
     第5位 (1 << 4)：使用 vm_allocate 或 mmap 分配内存
     第6位 (1 << 5)：使用 vm_deallocate 或 munmap 释放内存
     */
    
    static unsigned long addr = 0;
    
    uint32_t alloctype = type;
    if (alloctype & stack_logging_flag_zone) { // mask掉第4位（NSZoneMalloc位）（不知道什么原理）
        alloctype &= ~stack_logging_flag_zone;
    }
    if (alloctype == (stack_logging_type_dealloc|stack_logging_type_alloc)) { // type: 0x0110 -> realloc
        // arg2: old vm address
        // arg3: malloc size
        // result: new vm address
        if (arg3 >= 51 * 1024 * 1024) { // threshold 过滤指定大小的realloc size
            if (arg2 != result) { // arg2有可能与result相等，如果新旧地址不相等重新记录地址
                addr = result;
            }
            NSLog(@"@mahaomeng realloc type %d", alloctype);
            NSLog(@"@mahaomeng realloc size %ld Bytes", arg3);
            NSLog(@"@mahaomeng realloc addr from 0x%lx to 0x%lx", arg2, result);
        }
    }
    else if ((alloctype & stack_logging_type_dealloc) != 0) { // type: 0x0100 -> free
        // arg2: vm address
        if (addr > 0 && arg2 == addr) {
            NSLog(@"@mahaomeng free type %d", alloctype);
            NSLog(@"@mahaomeng free addr 0x%lx", addr);
        }
    }
    else if((alloctype & stack_logging_type_alloc) != 0) { // type: 0x0010 -> malloc
        // arg2: malloc size
        // result: vm address
        if (arg2 >= 51 * 1024 * 1024) { // threshold 过滤指定大小的malloc size
            addr = result;
            NSLog(@"@mahaomeng malloc type %d", alloctype);
            NSLog(@"@mahaomeng malloc size %ld Bytes", arg2);
            NSLog(@"@mahaomeng malloc addr 0x%lx", addr);
        }
    }
}

@interface AppDelegate ()

@end

static NSString *const JRFPreviousBundleVersionKey = @"JRFPreviousBundleVersionKey";
static NSString *const JRFAppDidCrashKey = @"JRFAppDidCrashKey";
static NSString *const JRFAppWasTerminatedKey = @"JRFAppWasTerminatedKey";
static NSString *const JRFPreviousOSVersionKey = @"JRFPreviousOSVersionKey";
static NSString *const JRFAppWasInBackgroundKey = @"JRFAppWasInBackgroundKey";

@implementation AppDelegate

static char *intentionalQuitPathname;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    
    malloc_logger = (malloc_logger_t *)my_stack_logger;
    
    // 每次启动
    // app upgrade
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *majorVersion = infoDictionary[@"CFBundleShortVersionString"];
    NSString *minorVersion = infoDictionary[@"CFBundleVersion"];
    NSString *currentBundleVersion = [NSString stringWithFormat:@"%@.%@", majorVersion, minorVersion];
    NSString *previousAppVersion = [[NSUserDefaults standardUserDefaults] objectForKey:JRFPreviousBundleVersionKey];
    
    BOOL didUpgradeApp = ![currentBundleVersion isEqualToString:previousAppVersion];
    if (didUpgradeApp) {
        NSLog(@"@mahaomeng app starting because of app upgrade");
    }
    [[NSUserDefaults standardUserDefaults] setObject:currentBundleVersion forKey:JRFPreviousBundleVersionKey];
    
    // app intentionally quit
    NSString *appSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
    if ([[NSFileManager defaultManager] fileExistsAtPath:appSupportDirectory isDirectory:NULL]) {
        if ([[NSFileManager defaultManager] createDirectoryAtPath:appSupportDirectory withIntermediateDirectories:YES attributes:nil error:nil]) {
            NSString *fileName = [appSupportDirectory stringByAppendingPathComponent:@"intentionalquit"];
            intentionalQuitPathname = strdup([fileName UTF8String]);
            struct stat statbuffer;
            if (stat(intentionalQuitPathname, &statbuffer) == 0){
                // A file exists at the path, we had an intentional quit
                NSLog(@"@mahaomeng app starting because of app intentionally quit");
            }
            signal(SIGABRT, JRFIntentionalQuitHandler);
            signal(SIGQUIT, JRFIntentionalQuitHandler);
            // Remove intentional quit file
            unlink(intentionalQuitPathname);
        }
    }
    
    // app crashed
    BOOL appCrashed = [[NSUserDefaults standardUserDefaults] boolForKey:JRFAppDidCrashKey];
    if (appCrashed) {
        NSLog(@"@mahaomeng app starting because of app crashed");
    }
    if (NSGetUncaughtExceptionHandler()) {
        NSLog(@"Warning: something in your application (probably a crash reporting framework) has already set an uncaught exception handler. This will break that code. You should pass a crashReporter block to checkForOutOfMemoryEventsWithHandler:crashReporter: that uses your crash reporting framework.");
    }
    NSSetUncaughtExceptionHandler(&defaultExceptionHandler);
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:JRFAppDidCrashKey];
    
    // terminated
    BOOL terminated = [[NSUserDefaults standardUserDefaults] boolForKey:JRFAppWasTerminatedKey];
    if (terminated) {
        NSLog(@"@mahaomeng app starting because of terminate");
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:JRFAppWasTerminatedKey];
    
    // os upgrade
    NSString *previousOSVersion = [[NSUserDefaults standardUserDefaults] objectForKey:JRFPreviousOSVersionKey];
    NSOperatingSystemVersion currentOSVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSString *currentOSVersionStr = [NSString stringWithFormat:@"%@.%@.%@", @(currentOSVersion.majorVersion), @(currentOSVersion.minorVersion), @(currentOSVersion.patchVersion)];
    BOOL didUpdateOS = ![currentOSVersionStr isEqualToString:previousOSVersion];
    if (didUpdateOS) {
        NSLog(@"@mahaomeng app starting because of OS upgrade");
    }
    [[NSUserDefaults standardUserDefaults] setObject:currentOSVersionStr forKey:JRFPreviousOSVersionKey];
    
    // in background
    // 注意：前提是上面的情况都不满足，则认为是oom，下面判断是boom还是foom;
    BOOL isBoom = [[NSUserDefaults standardUserDefaults] boolForKey:JRFAppWasInBackgroundKey]; // 之前应该还要判断一下是否是首次启动等情况造成返回NO
    if (isBoom) {
        NSLog(@"@mahaomeng app starting because of BOOM");
    } else {
        NSLog(@"@mahaomeng app starting because of FOOM");
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:JRFAppWasInBackgroundKey];
    
    return YES;
}

static void JRFIntentionalQuitHandler(int signal) {
    // Create intentional quit file
    creat(intentionalQuitPathname, S_IREAD | S_IWRITE);
}

static void defaultExceptionHandler (NSException *exception) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JRFAppDidCrashKey];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JRFAppWasTerminatedKey];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:JRFAppWasInBackgroundKey];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:JRFAppWasInBackgroundKey];
}

#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end
