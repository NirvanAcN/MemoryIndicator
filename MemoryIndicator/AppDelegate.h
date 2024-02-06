//
//  AppDelegate.h
//  MemoryIndicator
//
//  Created by 马浩萌 on 2024/2/6.
//

#import <UIKit/UIKit.h>
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

@interface AppDelegate : UIResponder <UIApplicationDelegate>


@end

