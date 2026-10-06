#import <Foundation/Foundation.h>

// ============================================================================
// ★ [HWKBD-IME] 硬件键盘输入法(IME)文本宿主状态
//
// 背景(用户报的 bug)：「妙控键盘(硬件键盘)没法输中文」。
//
// iOS 上硬件键盘的 CJK 输入必须走系统输入法的【组字链路】：第一响应者要实现
// UITextInput(至少 UIKeyInput)，系统才会驱动
//     setMarkedText:/setAttributedMarkedText:   —— 组字(暂态候选)
//     insertText:                               —— 提交(已定字符串)
// 若 App 只把硬件键盘当「按键 + 原始字符」转发
// (pressesBegan → UIKey.characters)，拿到的永远是按键的 ASCII 原字符
// ("n" / "i" …)，中文/日文等需要组字的输入法永远组不出来。
//
// 本模块只保存两件事实，供两条链路共用：
//   1. ameIMEHostActive()    —— 有没有 IME 文本宿主在岗(first responder)；
//   2. ameIMEHostComposing() —— 该宿主此刻是否正在组字(marked text 非空)。
// 用途：
//   - TrackedTextField(宿主自身)：登记/注销状态，注册 flush 回调；
//   - KeyboardInput(按键转发)：据此【抑制原始字符转发】，避免与 IME 提交重复，
//     并把回车/Esc 在组字时解释为「取消组字」。
//
// 线程：全部状态只在主线程读写(UI 事件与 first-responder 变化都在主线程)，
// 故用普通静态变量，不加锁。
// ============================================================================

/// 是否有 IME 文本宿主处于 first responder（系统输入法正文由它接管）。
BOOL ameIMEHostActive(void);

/// 该宿主当前是否正在组字（marked text 非空）。
BOOL ameIMEHostComposing(void);

/// 宿主 first responder 状态变化（由 TrackedTextField 调用）。
void ameIMEHostBecameActive(void);
void ameIMEHostResigned(void);

/// 组字状态变化（由 TrackedTextField 调用）。
void ameIMEHostSetComposing(BOOL composing);

/// 注册/注销「取消(丢弃)组字」回调（宿主实现；传 NULL 注销）。
void ameIMEHostSetFlushHandler(void (^handler)(void));

/// 请求宿主立即 flush/unmark 组字。返回 YES 表示确有宿主处理。
BOOL ameIMEHostFlushComposition(void);
