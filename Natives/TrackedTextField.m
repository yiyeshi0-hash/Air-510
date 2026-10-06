#import "TrackedTextField.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "input/KeyboardIMEHost.h"
#include "glfw_keycodes.h"
#include <mach/mach_time.h>

extern bool isUseStackQueueCall;

// There are private functions that we are unable to find public replacements
// (Both are found by placing breakpoints)
@interface UITextField(private)
- (NSRange)insertFilteredText:(NSString *)text;
- (id) replaceRangeWithTextWithoutClosingTyping:(UITextRange *)range replacementText:(NSString *)text;
@end

@interface TrackedTextField()
@property(nonatomic) int lastTextPos;
@property(nonatomic) CGFloat lastPointX;
// Task156：最近一次经私有路径（insertFilteredText:/replaceRangeWithText-
// WithoutClosingTyping:/paste:）送达游戏的文本 + 时间戳——公有 insertText:
// 兑底路径用它做短窗去重，避免同一次提交被双发。
@property(nonatomic, copy, nullable) NSString *ame156_lastDeliveredText;
@property(nonatomic) uint64_t ame156_lastDeliveredTick;
// ★ [HWKBD-IME] 取消(丢弃)当前组字；见实现。
- (void)ameFlushCompositionIfNeeded:(NSString *)reason;
@end

static uint64_t ame156_mach_ms(void) {
    static mach_timebase_info_data_t tb;
    static BOOL inited = NO;
    if (!inited) {
        mach_timebase_info(&tb);
        inited = YES;
    }
    return mach_absolute_time() * tb.numer / tb.denom / 1000000ull;
}

@implementation TrackedTextField

- (BOOL)resignFirstResponder {
    // SDL 的 text-input 更新、IME 候选确定等带来的临时 resign 要求：
    // 用户正在输入时不关标准键盘。显式键盘 toggle 由 SurfaceViewController
    // 临时解除本标志后 resign，不受影响。
    if (self.preventUnexpectedResign && self.isFirstResponder) {
        return NO;
    }
    // ★ [HWKBD-IME] 失焦前 flush/取消未提交的组字：候选是暂态，既不留给下次
    //   第一响应者带出来，也绝不作为正文送进游戏。
    [self ameFlushCompositionIfNeeded:@"resignFirstResponder"];
    BOOL ok = [super resignFirstResponder];
    if (ok) {
        ameIMEHostSetFlushHandler(NULL);
        ameIMEHostResigned();
    }
    return ok;
}

// ★ [HWKBD-IME] 成为第一响应者 ⇒ 系统输入法正文由本宿主接管。
//   这一步是「硬件键盘能组中文」的前提：没有 UITextInput 第一响应者时，
//   系统不会调用 setMarkedText:/insertText:，中文永远组不出来。
- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    if (ok) {
        __weak typeof(self) weakSelf = self;
        ameIMEHostSetFlushHandler(^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf ameFlushCompositionIfNeeded:@"external-flush"];
        });
        ameIMEHostBecameActive();
    }
    return ok;
}

// ★ [HWKBD-IME] 取消当前组字(marked text)：丢弃候选拼字，不发送给游戏。
- (void)ameFlushCompositionIfNeeded:(NSString *)reason {
    UITextRange *marked = self.markedTextRange;
    if (marked == nil) {
        ameIMEHostSetComposing(NO);
        return;
    }
    NSInteger markedLen = [self offsetFromPosition:marked.start toPosition:marked.end];
    if (markedLen < 0 || (NSUInteger)markedLen > self.text.length) {
        markedLen = 0;   // iOS 27 上 offsetFromPosition 对异常位置返回值不可靠
    }
    NSLog(@"[HWKBD-IME] flush/unmark composition (%@): dropping %ld marked char(s) -- NOT sent to game",
          reason, (long)markedLen);
    [self unmarkText];
    ameIMEHostSetComposing(NO);
}

- (void)sendMultiBackspaces:(int)times {
    for (int i = 0; i < times; i++) {
        self.sendKey(GLFW_KEY_BACKSPACE, 0, 1, 0);
        self.sendKey(GLFW_KEY_BACKSPACE, 0, 0, 0);
    }
}

// workaround pasted text not being caught
- (void)paste:(id)sender {
    [super paste:sender];
    [self sendText:UIPasteboard.generalPasteboard.string];
}

// Task156：短窗去重记录——私有路径送达后登记；公有 insertText: 兑底在
// 80ms 内遇到同文本则跳过（同一提交不会被双发，不同键击间隔远大于 80ms）。
- (void)ame156_recordDelivery:(NSString *)text {
    self.ame156_lastDeliveredText = text;
    self.ame156_lastDeliveredTick = ame156_mach_ms();
}

- (BOOL)ame156_recentlyDelivered:(NSString *)text {
    if (self.ame156_lastDeliveredText == nil) return NO;
    uint64_t now = ame156_mach_ms();
    if (now < self.ame156_lastDeliveredTick ||
        now - self.ame156_lastDeliveredTick > 80) {
        return NO;
    }
    return [self.ame156_lastDeliveredText isEqualToString:text];
}

- (void)sendText:(NSString *)text {
    for (int i = 0; i < text.length; i++) {
        // Directly convert unichar to jchar since both are in UTF-16 encoding.
        unichar theChar = [text characterAtIndex:i];
        // 关键修复（虚拟键盘输入无反应）：
        //   之前用 if-else 二选一：isUseStackQueueCall=true 时只调用 sendCharMods，
        //   不调用 sendChar。但 MC 1.13+ 已废弃 glfwSetCharModsCallback，只注册
        //   glfwSetCharCallback，故 GLFW_invoke_CharMods 为 NULL，
        //   CallbackBridge_nativeSendCharMods 在 `if (GLFW_invoke_CharMods && isInputReady)`
        //   处直接返回 NO，字符被静默丢弃 → 虚拟键盘输入完全无反应。
        //
        //   与硬件键盘（input/KeyboardInput.m:162-163）行为对齐：同时发送 CharMods
        //   和 Char。MC 实际只会响应其注册的那个回调（Char 或 CharMods），
        //   不会出现重复字符。这样：
        //   - MC 1.13+（仅 Char）→ sendChar 生效，sendCharMods 静默失败
        //   - MC pre-1.13（仅 CharMods）→ sendCharMods 生效，sendChar 静默失败
        //   - 任何 GLFW 后端版本都能正确传递字符
        if (self.sendCharMods != nil) {
            self.sendCharMods(theChar, 0);
        }
        if (self.sendChar != nil) {
            self.sendChar(theChar);
        }
    }
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    [super beginFloatingCursorAtPoint:point];
    self.lastPointX = point.x;
}

// Handle cursor movement in the empty space
- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    [super updateFloatingCursorAtPoint:point];

    if (self.lastPointX == 0 || (self.lastTextPos > 0 && self.lastTextPos < self.text.length)) {
        // This is handled in -[TrackedTextField closestPositionToPoint:]
        return;
    }

    CGFloat diff = point.x - self.lastPointX;
    if (ABS(diff) < 8) {
        return;
    }
    self.lastPointX = point.x;

    int key = (diff > 0) ? GLFW_KEY_DPAD_RIGHT : GLFW_KEY_DPAD_LEFT;
    self.sendKey(key, 0, 1, 0);
    self.sendKey(key, 0, 0, 0);
}

- (void)endFloatingCursor {
    [super endFloatingCursor];
    self.lastPointX = 0;
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    // Handle cursor movement between characters
    UITextPosition *position = [super closestPositionToPoint:point];
    int start = [self offsetFromPosition:self.beginningOfDocument toPosition:position];
    if (start - self.lastTextPos != 0) {
        int key = (start - self.lastTextPos > 0) ? GLFW_KEY_DPAD_RIGHT : GLFW_KEY_DPAD_LEFT;
        self.sendKey(key, 0, 1, 0);
        self.sendKey(key, 0, 0, 0);
    }
    self.lastTextPos = start;
    return position;
}

- (void)deleteBackward {
    // ★ [HWKBD-IME] 组字期间退格只改「拼字候选」，不是游戏里的退格 ——
    //   组字不再镜像进游戏(见 setAttributedMarkedText:)，此处若照旧补发退格，
    //   会把已经提交的正文误删。
    if (self.markedTextRange != nil) {
        [super deleteBackward];
        self.lastTextPos = (int)self.text.length;
        return;
    }
    if (self.text.length > 1) {
        // Keep the first character (a space)
        [super deleteBackward];
    } else {
        self.text = @" ";
    }
    self.lastTextPos = [super offsetFromPosition:self.beginningOfDocument toPosition:self.selectedTextRange.start];

    [self sendMultiBackspaces:1];
}

- (BOOL)hasText {
    self.lastTextPos = MAX(self.lastTextPos, 1);
    return YES;
}

// Old name: insertText
- (NSRange)insertFilteredText:(NSString *)text {
    int cursorPos = [super offsetFromPosition:self.beginningOfDocument toPosition:self.selectedTextRange.start];

    int off = self.lastTextPos - cursorPos;
    // ★ [HWKBD-IME] 安全钳制：off 只应删除「游戏侧已提交」的字符，永远不可能超过
    //   宿主自身文本长度。异常坐标(旧版 iOS 27 上 offsetFromPosition: 返回 NSNotFound)
    //   下这里能挡住退格风暴，且不改变正常路径(off 通常为 0)。
    if (off > (int)self.text.length) {
        NSLog(@"[HWKBD-IME] insertFilteredText: clamping suspicious backspace off=%d -> %lu (text len)",
              off, (unsigned long)self.text.length);
        off = (int)self.text.length;
    }
    if (off > 0) {
        // Handle text markup by first deleting N amount of characters equal to the replaced text
        [self sendMultiBackspaces:off];
    }
    // What else is done by past-autocomplete (insert a space after autocompletion)
    // See -[TrackedTextField replaceRangeWithTextWithoutClosingTyping:replacementText:]

    NSLog(@"[HWKBD-IME] commit insertFilteredText: \"%@\" (len=%lu, off=%d) -> game",
          text, (unsigned long)text.length, off);

    [self sendText:text];
    [self ame156_recordDelivery:text];

    NSRange range = [super insertFilteredText:text];
    // ★ [HWKBD-IME] 组字不再镜像进游戏 ⇒ 宿主文本长度可 > 游戏侧长度；旧的
    //   `cursorPos + text.length`(按替换 marked 区间前的坐标算)会在下一次提交
    //   时算出虚假退格数。改以【提交后真实的宿主长度】为准。
    self.lastTextPos = (int)self.text.length;
    ameIMEHostSetComposing(NO);
    return range;
}

- (id)replaceRangeWithTextWithoutClosingTyping:(UITextRange *)range replacementText:(NSString *)text
{
    int oldLength = [super offsetFromPosition:range.start toPosition:range.end];

    // Delete the range of needs for autocompletion
    [self sendMultiBackspaces:oldLength];

    // Insert the autocompleted text
    NSLog(@"[HWKBD-IME] commit replaceRangeWithoutClosingTyping (old=%d): \"%@\" -> game", oldLength, text);
    [self sendText:text];
    [self ame156_recordDelivery:text];

    id result = [super replaceRangeWithTextWithoutClosingTyping:range replacementText:text];
    // ★ [HWKBD-IME] 同 insertFilteredText:：以提交后的真实宿主长度为准，避免
    //   组字不镜像后 `+= text.length - oldLength` 累积出虚假长度。
    self.lastTextPos = (int)self.text.length;
    ameIMEHostSetComposing(NO);
    return result;
}

// ============================================================================
// Task 156：iOS 27 输入法兼容兑底（公有 UIKeyInput 路径）。
//
// 病历：设备 iPadOS 27.0（24A437）报告“输入法无法正常输入”。本类的字符
// 送达链全部建筑在 UIKit 私有 API 上（insertFilteredText: /
// replaceRangeWithTextWithoutClosingTyping: / setAttributedMarkedText:）
// ——多年版本一直回肩，但 iOS 26+ 引入 UIAsyncTextInput 异步输入管线后，
// 部分键盘提交不再经过这些私有入口，直接走公有 UIKeyInput.insertText:，
// 于是提交文本（拼音候选上屏、联想词、普通键入）永远到不了游戏。
//
// 兑底策略：override 公有 insertText:（UIKit 对 first responder 的键入
// 提交路径）——私有路径未在短窗内送过同文本时补发。两路径共存时
// 80ms 同文本去重防双发；私有路径已死时这里是唯一送达通道。
//
// ★ [HWKBD-IME]（妙控键盘没法输中文）：insertText: 现在是【硬件键盘中文提交的
//   主通道】—— 系统输入法组好字后把已定字符串交给它。组字(marked text)本身
//   不再镜像给游戏(见下 setAttributedMarkedText: 的改动)。
// ============================================================================
- (void)insertText:(NSString *)text {
    if (text.length > 0 && ![self ame156_recentlyDelivered:text]) {
        NSLog(@"[HWKBD-IME] commit insertText: \"%@\" (len=%lu) -> game",
              text, (unsigned long)text.length);
        [self sendText:text];
        [self ame156_recordDelivery:text];
    } else {
        NSLog(@"[HWKBD-IME] commit insertText suppressed (dup/empty): \"%@\"", text ?: @"");
    }
    [super insertText:text];
    self.lastTextPos = (int)self.text.length;
    ameIMEHostSetComposing(NO);
}

- (void)setAttributedMarkedText:(NSAttributedString *)markedText selectedRange:(NSRange)selectedRange {
    // ========================================================================
    // ★ [HWKBD-IME] 组字(marked text)阶段【不再】把候选拼字送进游戏。
    //
    // 旧实现把 marked text 镜像进游戏、并在组字更新时用退格回退旧拼字
    // (Task156 已为它打过「markedTextRange 为 nil ⇒ 百万级退格风暴」的补丁)。
    // 这条路既是暂态语义、又很脆弱，并且会和硬件键盘的原始字符转发叠加成
    // 重复输入 —— 正是「妙控键盘没法输中文」的一半成因。
    //
    // 现在只登记组字状态：拼字留在宿主内部(供候选栏/光标定位)，游戏侧只认
    // 已提交文本(insertText: / insertFilteredText: / replaceRange…)。
    //
    // Task156 加固保留：offsetFromPosition:toPosition: 对 nil/异常位置在
    // iOS 27 上返回值不可靠，故只在诊断日志里用、且做长度夹取。
    // ========================================================================
    NSInteger markedLength = 0;
    if (self.markedTextRange != nil) {
        markedLength = [self offsetFromPosition:self.markedTextRange.start
                                     toPosition:self.markedTextRange.end];
        if (markedLength < 0 || (NSUInteger)markedLength > self.text.length) {
            markedLength = 0;
        }
    }

    [super setAttributedMarkedText:markedText selectedRange:selectedRange];
    self.lastTextPos = (int)self.text.length;

    ameIMEHostSetComposing(markedText.length > 0);
    static int s_markedUpdateCount = 0;
    s_markedUpdateCount++;
    if (s_markedUpdateCount <= 20 || s_markedUpdateCount % 50 == 0) {
        NSLog(@"[HWKBD-IME] composing(prev=%ld): markedText=\"%@\" len=%lu -> NOT sent to game",
              (long)markedLength, markedText.string, (unsigned long)markedText.length);
    }
}

// ★ [HWKBD-IME] 组字取消/结束(系统 unmark)。此时【不】发送任何东西给游戏：
//   未提交的候选要么已被 insertText: 提交，要么被丢弃。
- (void)unmarkText {
    [super unmarkText];
    ameIMEHostSetComposing(NO);
    NSLog(@"[HWKBD-IME] unmarkText -- composition cleared (nothing sent to game)");
}

- (void)setText:(NSString *)text {
    [super setText:text];
    self.lastTextPos = text.length;
    ameIMEHostSetComposing(NO);
}

@end
