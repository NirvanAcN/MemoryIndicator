# 监测大内存开辟以及内存生命周期追踪

## 原理

通过设置`libmalloc`中的`malloc_logger`和`__syscall_logger`函数指针，从而达到在我们开发所写的代码层面捕获`malloc/free/realloc/vm_allocate/vm_deallocate`等所有的内存分配/释放函数的信息，这也是内存调试工具malloc stack的实现原理。有了这些信息，我们是可以轻易的记录内存的分配大小、分配堆栈，分配堆栈可以用`backtrace`函数捕获，但捕获到的地址是虚拟内存地址，不能从符号表dsym解析符号。所以还要记录每个image加载时的偏移slide，这样符号表地址=堆栈地址-slide。

## 代码实现

在代码中只需要设置一下`malloc_logger`函数指针即可捕获内存分配信息：
```
#import <malloc/malloc.h>

#ifdef __cplusplus   //如果是C++环境，这个宏存在
extern "C" {        //声明这是C语言
#endif
    
    typedef void (malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t num_hot_frames_to_skip);
    
    void my_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip);
    
    extern malloc_logger_t *malloc_logger;
    
#ifdef __cplusplus
    }
#endif
```

```
#define stack_logging_type_alloc    2    /* malloc, realloc, etc... */
#define stack_logging_type_dealloc    4    /* free, realloc, etc... */
#define stack_logging_type_vm_allocate  16      /* vm_allocate or mmap */
#define stack_logging_type_vm_deallocate  32    /* vm_deallocate or munmap */
#define    stack_logging_flag_zone        8    /* NSZoneMalloc, etc... */
#define stack_logging_flag_cleared    64    /* for NewEmptyHandle */
#define stack_logging_type_mapped_file_or_shared_mem 128

#define max_stack_depth_sys 64
#define md5_length 8

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
```

## 补充
### `realloc`相关知识

#### 什么情况下会触发realloc
`realloc` 函数在 C 语言中用于重新分配内存块的大小。它可以扩大或缩小已分配内存块的大小，并且在可能的情况下，`realloc` 会尝试扩展当前内存块，否则它会分配一个新的内存块，将原来内存块的内容复制到新块中，然后释放原来的内存块。`realloc` 主要在以下情况下被触发：

1. **动态数组的扩展**:
   当使用动态数组（如在 C 中的数组或 C++ 中的 `std::vector`）时，如果数组的元素个数超过了当前分配的内存能容纳的数量，就需要扩展内存以容纳更多元素。

2. **优化内存使用**:
   如果确定一个之前分配了过多内存的内存块不再需要那么多内存，可以使用 `realloc` 减少它的大小，释放未使用的内存，从而优化内存使用。

3. **动态数据结构的修改**:
   在实现一些动态数据结构（如链表、树、图等）时，可能需要根据数据结构的当前状态动态地增加或减少内存的使用。

4. **资源调整**:
   在处理不同大小的资源时（例如，读取不同大小的文件或调整图像的大小），可能需要根据资源的大小动态地调整已分配内存的大小。

使用 `realloc` 时需要注意：

- 如果 `realloc` 成功，它返回指向新分配（或重新分配）内存的指针，旧指针应该不再使用。
- 如果 `realloc` 失败（例如，因为系统没有足够的内存），它会返回 `NULL`，而原始内存块不受影响。因此，调用 `realloc` 之前应该总是保存原始指针的副本，以便在 `realloc` 失败时能够正确地释放内存。
- 如果新的大小为零，并且旧指针不是 `NULL`，`realloc` 的行为等同于 `free`。

#### OC中哪些方法能触发realloc
在 Objective-C 中，内存管理通常由系统的自动引用计数（ARC）机制处理，这意味着开发者不经常直接使用 `malloc`、`realloc`、`free` 等函数。不过，Objective-C 仍然允许直接使用这些 C 语言风格的内存管理函数，特别是在处理底层 C 数据结构时。

在 Objective-C 中，可能会间接触发内存重新分配的情况主要涉及到集合类的动态调整，例如：

1. **NSMutableArray**:
   - 当你向 `NSMutableArray` 添加或删除对象时，数组可能需要调整其内部存储空间来适应新的对象数量。

2. **NSMutableData**:
   - 当你改变 `NSMutableData` 对象的大小，例如使用 `setLength:` 方法时，它可能需要分配或释放内存来适应新的大小。

3. **NSMutableString**:
   - 修改 `NSMutableString` 的内容，比如添加、删除或替换字符，可能会触发内存的重新分配。

在这些情况下，Objective-C 的集合类底层可能会使用类似于 `realloc` 的机制来动态调整内存。但是，这一过程对于开发者是透明的，你不需要（也不应该）直接在你的 Objective-C 代码中调用 `realloc`。相反，你应该使用这些集合类提供的方法来管理集合的内容，让系统负责处理内存管理的细节。

如果你需要在 Objective-C 中处理 C 风格的数据结构，或者需要直接管理内存，你仍然可以使用 `malloc`、`realloc` 和 `free`，但务必小心，确保正确地管理内存，避免泄露或损坏。

触发realloc的示例代码：
```
NSMutableData *data;

- (IBAction)click:(id)sender {
    data = [NSMutableData dataWithLength:51 * 1024 * 1024];
}

- (IBAction)expandClick:(id)sender { // expand十几次后会触发realloc，还记得3/4扩容吗？
    NSData *tData = [NSMutableData dataWithLength:1024*1024];
    [data appendData:tData];
}

- (IBAction)deClick:(id)sender {
    data = nil;
}

2024-02-06 17:01:18.542822+0800 MemoryIndicator[55142:2859195] @mahaomeng app starting because of FOOM
2024-02-06 17:01:19.754130+0800 MemoryIndicator[55142:2859195] @mahaomeng malloc type 66
2024-02-06 17:01:19.754331+0800 MemoryIndicator[55142:2859195] @mahaomeng malloc size 66846720 Bytes
2024-02-06 17:01:19.754438+0800 MemoryIndicator[55142:2859195] @mahaomeng malloc addr 0x160100000

2024-02-06 17:01:30.928136+0800 MemoryIndicator[55142:2859195] @mahaomeng realloc type 6
2024-02-06 17:01:30.928271+0800 MemoryIndicator[55142:2859195] @mahaomeng realloc size 83886080 Bytes
2024-02-06 17:01:30.928309+0800 MemoryIndicator[55142:2859195] @mahaomeng realloc addr from 0x160100000 to 0x164440000

2024-02-06 17:02:02.972678+0800 MemoryIndicator[55142:2859195] @mahaomeng free type 4
2024-02-06 17:02:02.972773+0800 MemoryIndicator[55142:2859195] @mahaomeng free addr 0x164440000
```


# FOOM/BOOM监测思路

## 原理
[Reducing FOOMs in the Facebook iOS app](https://engineering.fb.com/2015/08/24/ios/reducing-fooms-in-the-facebook-ios-app/)
![OOM](oom.png)

穷举上次app退出的原因：
- app更新（上次保存的app版本号与本次启动的版本号不一致）
- app Intentionally quit（触发了`exit()`或者`abort()`函数）
- app发生了crash
- 用户上划退出了app（terminate）
- 系统更新（上次保存的系统版本号与本次启动的版本号不一致）
如果本次app启动时都没命中以上app退出的原因，则认为app是因为发生了OOM而造成的退出，如果上次退出前app保存了是否在后台的信息，就可以判断是BOOM还是FOOM。

## 代码实现
```
#import <sys/stat.h>

static NSString *const JRFPreviousBundleVersionKey = @"JRFPreviousBundleVersionKey";
static NSString *const JRFAppDidCrashKey = @"JRFAppDidCrashKey";
static NSString *const JRFAppWasTerminatedKey = @"JRFAppWasTerminatedKey";
static NSString *const JRFPreviousOSVersionKey = @"JRFPreviousOSVersionKey";
static NSString *const JRFAppWasInBackgroundKey = @"JRFAppWasInBackgroundKey";

static char *intentionalQuitPathname;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
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
```

> 注意：可以手动调用`abort()`函数来触发，但是不要连着Xcode。

