#import "KeyboardIMEHost.h"

// ============================================================================
// ★ [HWKBD-IME] 见 KeyboardIMEHost.h 顶部说明。
// 主线程专用；静态变量即可，无需加锁。
// ============================================================================

static BOOL sIMEHostActive    = NO;   // 有 IME 文本宿主在岗
static BOOL sIMEHostComposing = NO;   // 该宿主正在组字(marked text 非空)
static void (^sIMEHostFlush)(void) = NULL;   // 宿主的「取消组字」回调

BOOL ameIMEHostActive(void)    { return sIMEHostActive; }
BOOL ameIMEHostComposing(void) { return sIMEHostComposing; }

void ameIMEHostBecameActive(void) {
    if (!sIMEHostActive) {
        NSLog(@"[HWKBD-IME] text-input host became first responder -- system IME owns text; "
              @"legacy raw key.characters forwarding will be suppressed (committed text goes via insertText:)");
    }
    sIMEHostActive    = YES;
    sIMEHostComposing = NO;
}

void ameIMEHostResigned(void) {
    if (sIMEHostActive) {
        NSLog(@"[HWKBD-IME] text-input host resigned -- legacy raw key.characters forwarding restored");
    }
    sIMEHostActive    = NO;
    sIMEHostComposing = NO;
    sIMEHostFlush     = NULL;
}

void ameIMEHostSetComposing(BOOL composing) {
    sIMEHostComposing = composing;
}

void ameIMEHostSetFlushHandler(void (^handler)(void)) {
    // ARC：赋值给强引用全局变量会自动 copy 传入的 block；传 NULL 注销。
    sIMEHostFlush = handler;
}

BOOL ameIMEHostFlushComposition(void) {
    void (^handler)(void) = sIMEHostFlush;
    if (handler == NULL) {
        return NO;
    }
    handler();
    sIMEHostComposing = NO;
    return YES;
}
