#import "KeyboardInput.h"
#import "../utils.h"
#import "KeyboardIMEHost.h"

#include "../glfw_keycodes.h"

// ============================================================================
// ★ [HWKBD-KEYMAP] 外置/妙控键盘整表补齐 + 修饰组合（对齐 PC Java 版手感）
//
// 本文件是硬件键盘的第一段漏斗：
//   SurfaceViewController.pressesBegan/Ended (:2294/:2312)
//     → +[KeyboardInput sendKeyEvent:down:]                    ← 本文件
//       → CallbackBridge_nativeSendKey(key, 0, action, mods)   (input_bridge_v3.m)
//         → Path A(GLFW 回调) / Path B(SDL3 事件注入 + SDL 键态镜像)
//
// 本次一并做齐两件事（缺任何一件，PC 上的组合键手感都出不来）：
//   ① 键位表补齐：所有“能出键码”的 HID usage 都要有 GLFW 键码，
//      否则该键在 sendKeyEvent 里 keycode==0 → 被静默丢弃（只剩一行 Unhandled）。
//      实测缺过：'（Quote 0x34）、End、Insert、PrintScreen、Pause、小键盘小数点、
//      Application/Menu、F13–F24、以及 ★ 左右 ⌘(GUI 0xE3/0xE7)。
//   ② 修饰位语义：modifierFlags 的【按下/抬起】边沿要变成自洽的 GLFW mods，
//      并随每个 key 事件下发 —— 游戏侧靠它判 F3+Shift / Shift+点击 这类组合。
//
// ★ 本文件【不动】两条既有硬约束：
//   - #106（键盘崩溃）：pressesBegan 不跳过 super、keyDownBuffer 兜底 → 在 bridge 内；
//   - [HWKBD-IME]：组字期只抑制【字符】转发，keycode 一律照发。
//
// 日志判据（一眼验证）：
//   [HWKBD-KEYMAP] down F3       glfw=292 hid=0x3C mods=0x0
//   [HWKBD-KEYMAP] down LShift   glfw=340 hid=0xE1 mods=0x1(SHIFT) <mods-edge>
//   [HWKBD-KEYMAP][COMBO] F3+A   glfw=65  mods=0x0   ← F3 按住时按 A，必有此行
//   [HWKBD-KEYMAP][COMBO] F3+F4  glfw=293            ← MC: 切换游戏模式
//   [HWKBD-KEYMAP] UNMAPPED key hid=0x??             ← 仅剩“有意不映射”的键
// ============================================================================

@implementation KeyboardInput

int keycodeTable[UIKeyboardHIDUsageKeyboardRightGUI+1];

#pragma mark - ★ [HWKBD-KEYMAP] 日志辅助（只读、无副作用）

// GLFW 键码 → 可读键名（日志/判据用；未收录的打印十进制）。
static NSString *hwKBDKeyName(int glfwKey) {
    if (glfwKey >= GLFW_KEY_A && glfwKey <= GLFW_KEY_Z) {
        return [NSString stringWithFormat:@"%c", (char)('A' + (glfwKey - GLFW_KEY_A))];
    }
    if (glfwKey >= GLFW_KEY_0 && glfwKey <= GLFW_KEY_9) {
        return [NSString stringWithFormat:@"%c", (char)('0' + (glfwKey - GLFW_KEY_0))];
    }
    if (glfwKey >= GLFW_KEY_F1 && glfwKey <= GLFW_KEY_F25) {
        return [NSString stringWithFormat:@"F%d", glfwKey - GLFW_KEY_F1 + 1];
    }
    if (glfwKey >= GLFW_KEY_NUMPAD_0 && glfwKey <= GLFW_KEY_NUMPAD_9) {
        return [NSString stringWithFormat:@"KP%d", glfwKey - GLFW_KEY_NUMPAD_0];
    }
    switch (glfwKey) {
        case GLFW_KEY_SPACE:           return @"Space";
        case GLFW_KEY_APOSTROPHE:      return @"'";
        case GLFW_KEY_COMMA:           return @",";
        case GLFW_KEY_MINUS:           return @"-";
        case GLFW_KEY_PERIOD:          return @".";
        case GLFW_KEY_SLASH:           return @"/";
        case GLFW_KEY_SEMICOLON:       return @";";
        case GLFW_KEY_EQUAL:           return @"=";
        case GLFW_KEY_LEFT_BRACKET:    return @"[";
        case GLFW_KEY_BACKSLASH:       return @"\\";
        case GLFW_KEY_RIGHT_BRACKET:   return @"]";
        case GLFW_KEY_GRAVE_ACCENT:    return @"`";
        case GLFW_KEY_ESCAPE:          return @"Esc";
        case GLFW_KEY_ENTER:           return @"Enter";
        case GLFW_KEY_TAB:             return @"Tab";
        case GLFW_KEY_BACKSPACE:       return @"Backspace";
        case GLFW_KEY_INSERT:          return @"Insert";
        case GLFW_KEY_DELETE:          return @"Delete";
        case GLFW_KEY_DPAD_RIGHT:      return @"Right";
        case GLFW_KEY_DPAD_LEFT:       return @"Left";
        case GLFW_KEY_DPAD_DOWN:       return @"Down";
        case GLFW_KEY_DPAD_UP:         return @"Up";
        case GLFW_KEY_PAGE_UP:         return @"PageUp";
        case GLFW_KEY_PAGE_DOWN:       return @"PageDown";
        case GLFW_KEY_HOME:            return @"Home";
        case GLFW_KEY_END:             return @"End";
        case GLFW_KEY_CAPS_LOCK:       return @"CapsLock";
        case GLFW_KEY_SCROLL_LOCK:     return @"ScrollLock";
        case GLFW_KEY_NUM_LOCK:        return @"NumLock";
        case GLFW_KEY_PRINT_SCREEN:    return @"PrintScreen";
        case GLFW_KEY_PAUSE:           return @"Pause";
        case GLFW_KEY_LEFT_SHIFT:      return @"LShift";
        case GLFW_KEY_LEFT_CONTROL:    return @"LCtrl";
        case GLFW_KEY_LEFT_ALT:        return @"LOpt";
        case GLFW_KEY_LEFT_SUPER:      return @"LCmd";
        case GLFW_KEY_RIGHT_SHIFT:     return @"RShift";
        case GLFW_KEY_RIGHT_CONTROL:   return @"RCtrl";
        case GLFW_KEY_RIGHT_ALT:       return @"ROpt";
        case GLFW_KEY_RIGHT_SUPER:     return @"RCmd";
        case GLFW_KEY_MENU:            return @"Menu";
        case GLFW_KEY_NUMPAD_DECIMAL:  return @"KP.";
        case GLFW_KEY_NUMPAD_DIVIDE:   return @"KP/";
        case GLFW_KEY_NUMPAD_MULTIPLY: return @"KP*";
        case GLFW_KEY_NUMPAD_SUBTRACT: return @"KP-";
        case GLFW_KEY_NUMPAD_ADD:      return @"KP+";
        case GLFW_KEY_NUMPAD_ENTER:    return @"KPEnter";
        case GLFW_KEY_NUMPAD_EQUAL:    return @"KP=";
        case GLFW_KEY_WORLD_1:         return @"WORLD_1";
        case GLFW_KEY_WORLD_2:         return @"WORLD_2";
        default:                       return [NSString stringWithFormat:@"glfw%d", glfwKey];
    }
}

// GLFW 修饰位 → 可读名字（判据里要能一眼看出 SHIFT/CTRL/OPT/CMD 是否带上）
static NSString *hwKBDModsName(int mods) {
    if (mods == 0) return @"0x0";
    NSMutableArray *parts = [NSMutableArray array];
    if (mods & GLFW_MOD_SHIFT)     [parts addObject:@"SHIFT"];
    if (mods & GLFW_MOD_CONTROL)   [parts addObject:@"CTRL"];
    if (mods & GLFW_MOD_ALT)       [parts addObject:@"OPT"];
    if (mods & GLFW_MOD_SUPER)     [parts addObject:@"CMD"];
    if (mods & GLFW_MOD_CAPS_LOCK) [parts addObject:@"CAPS"];
    if (mods & GLFW_MOD_NUM_LOCK)  [parts addObject:@"NUM"];
    return [NSString stringWithFormat:@"0x%X(%@)", (unsigned)mods,
            [parts componentsJoinedByString:@"|"]];
}

// 判据键：这些键【每次】都打（量小但决定验收），其余限流。
static BOOL hwKBDIsJudgeKey(int glfwKey) {
    if (glfwKey >= GLFW_KEY_F1 && glfwKey <= GLFW_KEY_F12) return YES;
    switch (glfwKey) {
        case GLFW_KEY_ESCAPE:
        case GLFW_KEY_ENTER:
        case GLFW_KEY_TAB:
        case GLFW_KEY_SPACE:
        case GLFW_KEY_NUMPAD_ENTER:
        case GLFW_KEY_LEFT_SHIFT:
        case GLFW_KEY_RIGHT_SHIFT:
        case GLFW_KEY_LEFT_CONTROL:
        case GLFW_KEY_RIGHT_CONTROL:
        case GLFW_KEY_LEFT_ALT:
        case GLFW_KEY_RIGHT_ALT:
        case GLFW_KEY_LEFT_SUPER:
        case GLFW_KEY_RIGHT_SUPER:
            return YES;
        default:
            return NO;
    }
}

// 组合判据状态：F3/F4 是否按住（“F3+任意键”组合行与 F3+F4 专行靠它）
static BOOL sHWKBD_f3Down = NO;
static int  sHWKBD_keymapLogCount = 0;

+ (void)initKeycodeTable {
    for (int i = UIKeyboardHIDUsageKeyboardA; i <= UIKeyboardHIDUsageKeyboardZ; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardA + GLFW_KEY_A;
    }

    // 0-9 keys
    keycodeTable[UIKeyboardHIDUsageKeyboard0] = GLFW_KEY_0;
    for (int i = UIKeyboardHIDUsageKeyboard1; i <= UIKeyboardHIDUsageKeyboard9; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboard1 + GLFW_KEY_1;
    }

    // Arrow keys
    keycodeTable[UIKeyboardHIDUsageKeyboardUpArrow] = GLFW_KEY_DPAD_UP;
    keycodeTable[UIKeyboardHIDUsageKeyboardDownArrow] = GLFW_KEY_DPAD_DOWN;
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftArrow] = GLFW_KEY_DPAD_LEFT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightArrow] = GLFW_KEY_DPAD_RIGHT;

    keycodeTable[UIKeyboardHIDUsageKeyboardComma] = GLFW_KEY_COMMA;
    keycodeTable[UIKeyboardHIDUsageKeyboardPeriod] = GLFW_KEY_PERIOD;

    // Alt keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftAlt] = GLFW_KEY_LEFT_ALT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightAlt] = GLFW_KEY_RIGHT_ALT;

    // Control keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftControl] = GLFW_KEY_LEFT_CONTROL;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightControl] = GLFW_KEY_RIGHT_CONTROL;

    // Shift keys
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftShift] = GLFW_KEY_LEFT_SHIFT;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightShift] = GLFW_KEY_RIGHT_SHIFT;

    // ★ [HWKBD-KEYMAP] Command(⌘) 键 —— 此前整表缺失（keycode==0 ⇒ 静默丢弃）。
    //   iOS 是否把 ⌘ 交给 App 取决于系统保留快捷键（⌘+Q/⌘+Tab/⌘+Space/⌘+H 被系统吃掉），
    //   但 ⌘+字母 这类组合必须由我们把 GUI 键送进游戏，游戏侧才能判 CMD 组合。
    keycodeTable[UIKeyboardHIDUsageKeyboardLeftGUI] = GLFW_KEY_LEFT_SUPER;
    keycodeTable[UIKeyboardHIDUsageKeyboardRightGUI] = GLFW_KEY_RIGHT_SUPER;

    // Bracket keys
    keycodeTable[UIKeyboardHIDUsageKeyboardOpenBracket] = GLFW_KEY_LEFT_BRACKET;
    keycodeTable[UIKeyboardHIDUsageKeyboardCloseBracket] = GLFW_KEY_RIGHT_BRACKET;

    // Slash keys
    keycodeTable[UIKeyboardHIDUsageKeyboardSlash] = GLFW_KEY_SLASH;
    keycodeTable[UIKeyboardHIDUsageKeyboardBackslash] = GLFW_KEY_BACKSLASH;

    // ★ [HWKBD-KEYMAP] 单/双引号键（HID 0x34 Quote）—— 此前缺失，
    //   表现为「聊天里打不出 '」「/give @p … 引号敲不出来」。
    keycodeTable[UIKeyboardHIDUsageKeyboardQuote] = GLFW_KEY_APOSTROPHE;

    // ★ [HWKBD-KEYMAP] ISO 键位的两个“非 US”符号键（GLFW 只给了 WORLD_1/WORLD_2）：
    //   0x64 在 Apple ISO 键盘上就是 §/±（与 GLFW cocoa 的 WORLD_1 同义），
    //   0x32 是 ISO 的 #/~。二者 MC 无默认绑定，但补齐后不再是“未知键”。
    keycodeTable[UIKeyboardHIDUsageKeyboardNonUSBackslash] = GLFW_KEY_WORLD_1;
    keycodeTable[UIKeyboardHIDUsageKeyboardNonUSPound] = GLFW_KEY_WORLD_2;

    // Page keys
    keycodeTable[UIKeyboardHIDUsageKeyboardPageUp] = GLFW_KEY_PAGE_UP;
    keycodeTable[UIKeyboardHIDUsageKeyboardPageDown] = GLFW_KEY_PAGE_DOWN;

    // Some other keys
    keycodeTable[UIKeyboardHIDUsageKeyboardHome] = GLFW_KEY_HOME;
    keycodeTable[UIKeyboardHIDUsageKeyboardEscape] = GLFW_KEY_ESCAPE;
    keycodeTable[UIKeyboardHIDUsageKeyboardTab] = GLFW_KEY_TAB;
    keycodeTable[UIKeyboardHIDUsageKeyboardReturnOrEnter] = GLFW_KEY_ENTER;
    keycodeTable[UIKeyboardHIDUsageKeyboardSpacebar] = GLFW_KEY_SPACE;
    keycodeTable[UIKeyboardHIDUsageKeyboardDeleteOrBackspace] = GLFW_KEY_BACKSPACE;
    keycodeTable[UIKeyboardHIDUsageKeyboardDeleteForward] = GLFW_KEY_DELETE;
    keycodeTable[UIKeyboardHIDUsageKeyboardGraveAccentAndTilde] = GLFW_KEY_GRAVE_ACCENT;

    keycodeTable[UIKeyboardHIDUsageKeyboardHyphen] = GLFW_KEY_MINUS;
    keycodeTable[UIKeyboardHIDUsageKeyboardEqualSign] = GLFW_KEY_EQUAL;
    keycodeTable[UIKeyboardHIDUsageKeyboardSemicolon] = GLFW_KEY_SEMICOLON;

    // ★ [HWKBD-KEYMAP] End / Insert / PrintScreen / Pause —— 此前缺失。
    //   End = MC 里“光标到行尾 / 列表滚到底”；Insert 在聊天框里是覆盖模式；
    //   PrintScreen/Pause 无默认绑定，但补齐后 F 键区不再有“死键”。
    keycodeTable[UIKeyboardHIDUsageKeyboardEnd] = GLFW_KEY_END;
    keycodeTable[UIKeyboardHIDUsageKeyboardInsert] = GLFW_KEY_INSERT;
    keycodeTable[UIKeyboardHIDUsageKeyboardPrintScreen] = GLFW_KEY_PRINT_SCREEN;
    keycodeTable[UIKeyboardHIDUsageKeyboardPause] = GLFW_KEY_PAUSE;

    // Lock keys
    keycodeTable[UIKeyboardHIDUsageKeyboardCapsLock] = GLFW_KEY_CAPS_LOCK;
    keycodeTable[UIKeyboardHIDUsageKeypadNumLock] = GLFW_KEY_NUM_LOCK;
    keycodeTable[UIKeyboardHIDUsageKeyboardScrollLock] = GLFW_KEY_SCROLL_LOCK;

    // Numpad keys
    keycodeTable[UIKeyboardHIDUsageKeypadSlash] = GLFW_KEY_NUMPAD_DIVIDE;
    keycodeTable[UIKeyboardHIDUsageKeypadAsterisk] = GLFW_KEY_NUMPAD_MULTIPLY;
    keycodeTable[UIKeyboardHIDUsageKeypadHyphen] = GLFW_KEY_NUMPAD_SUBTRACT;
    keycodeTable[UIKeyboardHIDUsageKeypadPlus] = GLFW_KEY_NUMPAD_ADD;
    keycodeTable[UIKeyboardHIDUsageKeypadEnter] = GLFW_KEY_NUMPAD_ENTER;
    keycodeTable[UIKeyboardHIDUsageKeypadEqualSign] = GLFW_KEY_NUMPAD_EQUAL;
    // ★ [HWKBD-KEYMAP] 小键盘小数点（HID 0x63）—— 此前缺失（小键盘只有它点不出来）。
    keycodeTable[UIKeyboardHIDUsageKeypadPeriod] = GLFW_KEY_NUMPAD_DECIMAL;
    keycodeTable[UIKeyboardHIDUsageKeypad0] = GLFW_KEY_NUMPAD_0;
    for (int i = UIKeyboardHIDUsageKeypad1; i <= UIKeyboardHIDUsageKeypad9; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeypad1 + GLFW_KEY_NUMPAD_1;
    }

    // Function keys
    for (int i = UIKeyboardHIDUsageKeyboardF1; i <= UIKeyboardHIDUsageKeyboardF12; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardF1 + GLFW_KEY_F1;
    }

    // ★ [HWKBD-KEYMAP] F13–F24 —— 此前缺失（GLFW_KEY_F13..F24 = 302..313）。
    //   注意桥内 glfwKeyToSDLScancode 的旧公式会把 F13 误算成 SDL_PrintScreen(70)；
    //   本次已按 SDL 真值修正为 104..115（F1–F12 仍为 58..69，未动）。
    for (int i = UIKeyboardHIDUsageKeyboardF13; i <= UIKeyboardHIDUsageKeyboardF24; i++) {
        keycodeTable[i] = i - UIKeyboardHIDUsageKeyboardF13 + GLFW_KEY_F13;
    }

    // ★ [HWKBD-KEYMAP] Application/Menu 键（HID 0x65）—— 此前缺失。
    keycodeTable[UIKeyboardHIDUsageKeyboardApplication] = GLFW_KEY_MENU;

    // 有意不映射（GLFW 无对应键、MC 亦无默认绑定；记在报告里，避免“以为漏了”）：
    //   International1–9 (0x87–0x8F) / LANG1–9 (0x90–0x98) / Locking* (0x82–0x84) /
    //   KeypadComma (0x85) / 多媒体键 Mute/VolumeUp/VolumeDown (0x7F–0x81) /
    //   Power (0x66) / 各类 Execute/Help/Select/Again… (0x74–0x7E)。
    //   这些键在 sendKeyEvent 里会打 [HWKBD-KEYMAP] UNMAPPED 一行，便于日后按需补。
}

+ (BOOL)sendKeyEvent:(UIKey *)key down:(BOOL)isDown {
    char modifiers = 0;

    // convert UIKey's modifiers to GLFW
    if (key.modifierFlags & UIKeyModifierAlphaShift) {
        modifiers |= GLFW_MOD_CAPS_LOCK;
    }
    if (key.modifierFlags & UIKeyModifierShift) {
        modifiers |= GLFW_MOD_SHIFT;
    }
    if (key.modifierFlags & UIKeyModifierAlternate) {
        modifiers |= GLFW_MOD_ALT;
    }
    if (key.modifierFlags & UIKeyModifierControl) {
        modifiers |= GLFW_MOD_CONTROL;
    }
    if (key.modifierFlags & UIKeyModifierCommand) {
        modifiers |= GLFW_MOD_SUPER;
    }
    // ★ [HWKBD-KEYMAP] 小键盘的 NumLock 语义：Keypad* 键与 NumLock 本身置 NUM 位。
    //   GLFW 只在 GLFW_LOCK_KEY_MODS 开启时才带这两位，但带上属于“正确且超集”；
    //   桥内会翻成 SDL_KMOD_NUM（= MC 26.3 的 InputConstants.MOD_NUM_LOCK=0x1000）。
    if ((key.modifierFlags & UIKeyModifierNumericPad) ||
        (NSUInteger)key.keyCode == UIKeyboardHIDUsageKeypadNumLock) {
        modifiers |= GLFW_MOD_NUM_LOCK;
    }

    // send the keycode
    NSUInteger hidUsage = (NSUInteger)key.keyCode;

    // ★ [HWKBD-IME] 组字中按回车/Esc ⇒ 先 flush/unmark 组字(取消本次候选拼字)，
    //   再照常把按键转发给游戏(回车=发送聊天、Esc=关界面)。组字是暂态，
    //   绝不能当成正文留在游戏里。
    if (isDown && ameIMEHostComposing()) {
        if (hidUsage == UIKeyboardHIDUsageKeyboardReturnOrEnter ||
            hidUsage == UIKeyboardHIDUsageKeyboardEscape) {
            NSLog(@"[HWKBD-IME] %@ while composing -> flush/unmark composition before forwarding to game",
                  hidUsage == UIKeyboardHIDUsageKeyboardEscape ? @"Esc" : @"Enter");
            ameIMEHostFlushComposition();
        }
    }

    int keycode = hidUsage <= UIKeyboardHIDUsageKeyboardRightGUI
        ? keycodeTable[hidUsage]
        : 0;
    if (keycode != 0) {
        // issue #27 修复（参照 FCL commit 08c0716）：
        // MC 1.21.9+ 不再仅依赖 key 回调中的 mods 参数，而是通过
        // InputConstants.isKeyDown() 查询 modifier 状态，该状态由 MC 自己
        // 维护在独立缓存中，必须显式 setModifiers 才能更新。
        //
        // 关键修复 1：release 事件中 iOS 的 modifierFlags 仍包含被释放的键，
        // 导致 mods 与 action 自相矛盾。这里对 modifier 键本身做修正：
        // 释放时从 mods 中移除该键对应的位，让事件语义自洽。
        if (!isDown) {
            switch (keycode) {
                case GLFW_KEY_LEFT_SHIFT:
                case GLFW_KEY_RIGHT_SHIFT:
                    modifiers &= ~GLFW_MOD_SHIFT;
                    break;
                case GLFW_KEY_LEFT_CONTROL:
                case GLFW_KEY_RIGHT_CONTROL:
                    modifiers &= ~GLFW_MOD_CONTROL;
                    break;
                case GLFW_KEY_LEFT_ALT:
                case GLFW_KEY_RIGHT_ALT:
                    modifiers &= ~GLFW_MOD_ALT;
                    break;
                case GLFW_KEY_LEFT_SUPER:
                case GLFW_KEY_RIGHT_SUPER:
                    modifiers &= ~GLFW_MOD_SUPER;
                    break;
                case GLFW_KEY_CAPS_LOCK:
                    modifiers &= ~GLFW_MOD_CAPS_LOCK;
                    break;
                case GLFW_KEY_NUM_LOCK:
                    modifiers &= ~GLFW_MOD_NUM_LOCK;
                    break;
                default:
                    break;
            }
        }

        // ★ [HWKBD-KEYMAP] F3/F4 组合判定状态（判据行靠它；只读本地标志，无副作用）
        BOOL wasF3Down = sHWKBD_f3Down;
        if (keycode == GLFW_KEY_F3) sHWKBD_f3Down = isDown;
        BOOL comboF3F4   = isDown && keycode == GLFW_KEY_F4 && wasF3Down;
        BOOL comboWithF3 = isDown && keycode != GLFW_KEY_F3 && wasF3Down;

        // ★ [HWKBD-KEYMAP] 修饰边沿：判据行要能看出 mods 何时变化
        static char sHWKBD_lastMods = 0;
        BOOL modsChanged = ((char)modifiers != sHWKBD_lastMods);
        if (modsChanged) sHWKBD_lastMods = (char)modifiers;

        CallbackBridge_nativeSendKey(keycode, 0 /* scancode */, isDown, modifiers);

        // 关键修复 2：显式同步 MC 1.21.9+ 内部的 modifier 缓存。
        // 即便某些版本 MC 不使用 setModifiers，调用也是安全的（旧版本无此方法
        // 会直接 no-op）。这能确保物理键盘的 Shift/Ctrl/Alt 在游戏内生效。
        CallbackBridge_queueModifierSync(modifiers);

        // ★ [HWKBD-KEYMAP] 取证：判据键/修饰边沿/组合键【必打】，其余限流。
        sHWKBD_keymapLogCount++;
        if (hwKBDIsJudgeKey(keycode) || modsChanged || comboWithF3 || comboF3F4 ||
            sHWKBD_keymapLogCount <= 40 || sHWKBD_keymapLogCount % 25 == 0) {
            NSLog(@"[HWKBD-KEYMAP] %@ %-10s glfw=%d hid=0x%02lX mods=%@%@%@",
                  isDown ? @"down" : @"up  ",
                  [hwKBDKeyName(keycode) UTF8String], keycode, (unsigned long)hidUsage,
                  hwKBDModsName(modifiers),
                  modsChanged ? @" <mods-edge>" : @"",
                  wasF3Down ? @" <F3-held>" : @"");
        }
        if (comboF3F4) {
            NSLog(@"[HWKBD-KEYMAP][COMBO] F3+F4 glfw=%d mods=%@ -- MC: 切换游戏模式"
                  @"（F3 调试组合里最常被点名的一个）", keycode, hwKBDModsName(modifiers));
        } else if (comboWithF3) {
            NSLog(@"[HWKBD-KEYMAP][COMBO] F3+%s glfw=%d mods=%@ -- MC 的 F3 全部调试组合都走这一条",
                  [hwKBDKeyName(keycode) UTF8String], keycode, hwKBDModsName(modifiers));
        }
    } else {
        // ★ [HWKBD-KEYMAP] 未映射的 HID usage：显式打点，别再静默丢弃。
        //   补齐后这里只剩 International/LANG/多媒体等“有意不映射”的键（见映射表注释）。
        NSLog(@"[HWKBD-KEYMAP] UNMAPPED key hid=0x%02lX (chars=\"%@\") -- 见 KeyboardInput.m 映射表",
              (unsigned long)hidUsage, key.characters);
    }

    // key.characters.length < 11: skip sending characters if the string starts with UIKeyInput
    if (isDown && key.characters.length < 11) {
        // ★ [HWKBD-IME] IME 宿主在岗(first responder) ⇒ 系统输入法接管了字符正文，
        //   提交文本会经 TrackedTextField.insertText: → CallbackBridge_nativeSendChar
        //   走 GLFW char / SDL text-input 送给游戏。
        //   这里再发一遍 key.characters(= 按键的原始字符，中文只会是 "n"/"i"…)
        //   会 ① 与 IME 提交重复 ② 永远组不出中文 —— 正是「妙控键盘没法输中文」的另一半成因。
        //   注意：只抑制「字符」转发；上面的 keycode 已照常发出，
        //   所以 WASD/空格/快捷/回车/Esc 等按键控制完全不受影响，也与 #106 的
        //   keyDownBuffer 兜底无关(那条在 CallbackBridge_nativeSendKey 内)。
        if (ameIMEHostActive()) {
            static int s_imeSuppressedCharLogs = 0;
            s_imeSuppressedCharLogs++;
            if (s_imeSuppressedCharLogs <= 10 || s_imeSuppressedCharLogs % 100 == 0) {
                NSLog(@"[HWKBD-IME] raw char forward suppressed (#%d, IME host active): \"%@\" (keycode still forwarded)",
                      s_imeSuppressedCharLogs, key.characters);
            }
        } else if (modifiers & (GLFW_MOD_CONTROL | GLFW_MOD_ALT | GLFW_MOD_SUPER)) {
            // ★ [HWKBD-KEYMAP] 与 PC Java 版一致：Ctrl/Option/⌘ 按住时【不产生文本】。
            //   桌面 GLFW 在 Ctrl/Alt/Super 按下时不会给出 char 回调；iOS 这边
            //   UIKey.characters 却照样带字母。若照发，Ctrl+W（冲刺+前进）之类组合
            //   会在聊天框/告示牌/书里灌字符，手感与 PC 明显不同。
            //   Shift 不受影响（大写与符号仍需转发），CapsLock 也不受影响。
            static int s_modsCharSuppressedLogs = 0;
            s_modsCharSuppressedLogs++;
            if (s_modsCharSuppressedLogs <= 10 || s_modsCharSuppressedLogs % 100 == 0) {
                NSLog(@"[HWKBD-KEYMAP] char forward suppressed (#%d, mods=%@): \"%@\" -- PC 语义: 修饰组合不产文本",
                      s_modsCharSuppressedLogs, hwKBDModsName(modifiers), key.characters);
            }
        } else {
            for (int i = 0; i < key.characters.length; i++) {
                int keychar = [key.characters characterAtIndex:i];
                CallbackBridge_nativeSendCharMods(keychar, modifiers);
                CallbackBridge_nativeSendChar(keychar);
            }
        }
    }

    return keycode != 0 || isDown;
}

@end
