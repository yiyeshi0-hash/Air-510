#import <SafariServices/SafariServices.h>

#include "jni.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <math.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <string.h>
#include <setjmp.h>
#include <signal.h>
#include <fcntl.h>                    // ★ [JIT-EXEC-2] 文件背衬 JIT 探针（open/ftruncate/unlink）
#include <sys/mman.h>
#include <sys/stat.h>                 // ★ [JIT-EXEC-2] 同上（fchmod/stat）
#include <sys/sysctl.h>
#include <libkern/OSCacheControl.h>   // ★ [JIT-CACHE] sys_icache_invalidate（执行式 JIT 探针）
#include <spawn.h>                    // ★ [JIT-ENV] 巨魔自开 JIT（posix_spawn）
#include <sys/wait.h>                 // ★ [JIT-ENV] 同上（waitpid/wait）
// ★ [JIT-ENV] iOS SDK 不暴露 <sys/ptrace.h>（main.m 亦自带声明）⇒ 照 main.m 的做法
//   自带 PT_* 常量与 ptrace 原型，供"子进程 PT_TRACE_ME + 父进程 PT_DETACH"自开 JIT 用。
#ifndef PT_TRACE_ME
#define PT_TRACE_ME 0
#endif
#ifndef PT_DETACH
#define PT_DETACH 11
#endif
extern int ptrace(int, pid_t, caddr_t, int);
extern char **environ;   // ★ [JIT-ENV] posix_spawnp 的 envp（部分 SDK 下未随 unistd.h 暴露）

#include "utils.h"

// ★ [VER-ISOLATE-PCL] 版本隔离解析需要读全局偏好键 general.version_isolation，
// 故引入偏好访问层（LauncherPreferences.h 不反向包含 utils.h，无循环依赖风险）。
#import "LauncherPreferences.h"

CFTypeRef SecTaskCopyValueForEntitlement(void* task, NSString* entitlement, CFErrorRef  _Nullable *error);
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);

BOOL getEntitlementValue(NSString *key) {
    // ★ [JIT-FLOW] 本函数修两个缺陷（原实现见 git 历史）：
    //  (1) use-after-free：原实现先 CFRelease(value) 再对同一个 value 发
    //      isKindOfClass:/boolValue ⇒ 悬垂读（可能崩，也可能取到垃圾值 ⇒
    //      hasTrollStoreJIT 之类的判定时真时假，排查时无法复现）。改为先算后放。
    //  (2) 恒真口径：原实现把任何非 NSNumber 值（含字符串）一律当 YES。侧载
    //      模板 entitlements.sideload.xml 预写了
    //      jb.pmap_cs.custom_trust="PMAP_CS_APP_STORE" ⇒ 每个侧载包都恒真，
    //      被送进 apple-magnifier:// 那条无校验分支。字符串改为按真值判定
    //      （非空且非 false/0/no 才算 YES），并把 TrollStore 判定收到
    //      isTrollStoreInstall()（entitlement AND 磁盘标记）里。
    void *secTask = SecTaskCreateFromSelf(NULL);
    if (secTask == NULL) {
        return NO;
    }
    // 注意：只创建一次 SecTask，并以它做查询（原实现另建一个 task 查询、
    // 却释放了第一个 ⇒ 查询用的 task 泄漏）。
    CFTypeRef value = SecTaskCopyValueForEntitlement(secTask, key, nil);
    CFRelease(secTask);
    if (value == nil) {
        return NO;
    }
    BOOL result = NO;
    id obj = (__bridge id)value;
    if ([obj isKindOfClass:NSNumber.class]) {
        result = [obj boolValue];
    } else if ([obj isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)obj lowercaseString];
        result = (s.length > 0) &&
                 ![s isEqualToString:@"false"] &&
                 ![s isEqualToString:@"0"] &&
                 ![s isEqualToString:@"no"];
    } else {
        // 其余非空非布尔值（数组/字典/日期…）保持旧口径：视为已授予。
        result = YES;
    }
    CFRelease(value);
    return result;
}

// ★ [JIT-FLOW] TrollStore 装机判定：entitlement 标记【且】磁盘标记。
//   侧载模板给每个包都预写了 jb.pmap_cs.custom_trust，所以单看 entitlement
//   会让【每个侧载包】都被判成 TrollStore 机，被送进 apple-magnifier:// 这条
//   【没有 urlOK 校验】的分支（未装对应工具时静默失败）。加磁盘标记后只有真
//   TrollStore 安装才为真，普通侧载包走 stikjit:// + urlOK 校验那条可靠分支。
BOOL isTrollStoreInstall(void) {
    if (!getEntitlementValue(@"jb.pmap_cs.custom_trust")) {
        return NO;
    }
    // TrollStore 把 App 放在 <...>/Application/<uuid>/ 下，并在同一层放一个
    // _TrollStore 标记文件 ⇒ 相对 bundle 即 "../_TrollStore"。
    NSString *marker = [[[NSBundle.mainBundle.bundlePath
                          stringByAppendingPathComponent:@".."]
                         stringByAppendingPathComponent:@"_TrollStore"]
                        stringByStandardizingPath];
    if ([NSFileManager.defaultManager fileExistsAtPath:marker]) {
        return YES;
    }
    // 兼容：部分 TrollStore/变体把标记放在 bundle 内或上一层的 _TrollStore。
    NSString *markerInBundle = [NSBundle.mainBundle.bundlePath
                                stringByAppendingPathComponent:@"_TrollStore"];
    return [NSFileManager.defaultManager fileExistsAtPath:markerInBundle];
}

// ★ [JB-ADAPT] ============================================================
// 越狱环境多证据探测（实现与设计约束见 utils.h 顶部 [JB-ADAPT] 注释块）。
// 只读、一次性（dispatch_once）、结果缓存；不做任何写操作、不改进程状态。
//
// 证据优先级：dyld 镜像（沙盒下最可靠） > 磁盘标记（沙盒下多为不可达，尽力而为）
//   > CS 平台位（rootful 越狱 App 常见） 。
// ⚠ 本探测**绝不**参与 isJITEnabled 判定：越狱 ≠ 本 App 被授予 JIT。
// ============================================================================
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_PLATFORM_BINARY
#define CS_PLATFORM_BINARY 0x4000000
#endif

static AMEJBEnvironment gAmeJBEnvironment = AMEJBEnvironmentUnknown;
static NSString *gAmeJBRootTag = nil;       // rootful / rootless / roothide
static NSString *gAmeJBFrameworkTag = nil;  // ElleKit / libhooker / Substitute / CydiaSubstrate
static NSString *gAmeJBFamilyTag = nil;     // Dopamine / palera1n / unc0ver / checkra1n / …
static NSString *gAmeJBSummary = nil;
static dispatch_once_t gAmeJBDetectOnce = 0;

// dyld 已加载镜像名（小写全路径）是否包含任一 needle。镜像注入是沙盒下最可靠的越狱证据：
// 越狱的 tweak 注入库一定出现在本进程镜像表里（RootHide 隐藏名单里的 App 除外）。
static BOOL ameJBAnyLoadedImageContains(NSArray<NSString *> *needles) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *ip = _dyld_get_image_name(i);
        if (ip == NULL) continue;
        NSString *full = [@(ip) lowercaseString];
        for (NSString *nd in needles) {
            if ([full containsString:nd]) return YES;
        }
    }
    return NO;
}

static BOOL ameJBFileExists(NSString *path) {
    return path.length > 0 && access(path.fileSystemRepresentation, F_OK) == 0;
}

// RootHide 随机 jbroot 目录扫描（.jbroot-<hex>）。仅无沙盒进程可列，列不到不算失败
// （dyld 证据已足以判定）。同时扫 /var（IOSSecuritySuite 记录过的落点）。
static BOOL ameJBFindRandomJBROOT(void) {
    const char *parents[] = { "/var/containers/Bundle/Application", "/var" };
    for (size_t p = 0; p < sizeof(parents) / sizeof(parents[0]); p++) {
        DIR *d = opendir(parents[p]);
        if (d == NULL) continue;
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (strncmp(ent->d_name, ".jbroot-", 8) == 0) { closedir(d); return YES; }
        }
        closedir(d);
    }
    return NO;
}

static void ameJBDetectEnvironmentOnce(void) {
    // ① RootHide：随机 jbroot 注入库 / 环境库（roothide 系）。名字被随机化的
    //    systemhook.dylib 不作判据，改认 .jbroot- 路径段与 roothideinit/libroothide/libvroot。
    if (ameJBAnyLoadedImageContains(@[@".jbroot-", @"roothideinit.dylib", @"libroothide", @"libvroot"])) {
        gAmeJBRootTag = @"roothide";
    }

    // ② 注入框架（四类）：ElleKit（Dopamine/palera1n/roothide 现代默认）/
    //    libhooker（Taurine/Odyssey）/ Substitute / CydiaSubstrate（unc0ver/checkra1n）。
    if (ameJBAnyLoadedImageContains(@[@"libellekit.dylib", @"/ellekit/"])) {
        gAmeJBFrameworkTag = @"ElleKit";
    } else if (ameJBAnyLoadedImageContains(@[@"libhooker.dylib"])) {
        gAmeJBFrameworkTag = @"libhooker";
    } else if (ameJBAnyLoadedImageContains(@[@"libsubstitute", @"substitute-inserter",
                                             @"substitute-loader"])) {
        gAmeJBFrameworkTag = @"Substitute";
    } else if (ameJBAnyLoadedImageContains(@[@"mobilesubstrate", @"cydiasubstrate", @"libsubstrate",
                                             @"substrateinserter", @"substrateloader",
                                             @"substratebootstrap", @"substrate-inserter"])) {
        gAmeJBFrameworkTag = @"CydiaSubstrate";
    } else if (ameJBAnyLoadedImageContains(@[@"systemhook.dylib", @"libblackjack.dylib"])) {
        // Dopamine 自有注入（某些机型/配置下 ElleKit 不可见时兜底；非 Substrate 系）。
        gAmeJBFrameworkTag = @"Dopamine(systemhook)";
    }

    // ③ 磁盘证据（沙盒下可能 EPERM/ENOENT，命中即用，未命中不否决）。
    BOOL diskRootless =
        ameJBFileExists(@"/var/jb") || ameJBFileExists(@"/var/jb/usr/bin") ||
        ameJBFileExists(@"/var/jb/usr/lib/libellekit.dylib") ||
        ameJBFileExists(@"/var/jb/Library/LaunchDaemons");
    BOOL diskRootHide =
        ameJBFileExists(@"/var/mobile/Library/Preferences/com.roothide.pref.plist") ||
        ameJBFindRandomJBROOT();
    BOOL diskRootful =
        ameJBFileExists(@"/Library/MobileSubstrate/MobileSubstrate.dylib") ||
        ameJBFileExists(@"/Applications/Cydia.app") ||
        ameJBFileExists(@"/Applications/Sileo.app") ||
        ameJBFileExists(@"/Applications/Zebra.app") ||
        ameJBFileExists(@"/var/binpack") ||
        ameJBFileExists(@"/.installed_unc0ver") ||
        ameJBFileExists(@"/.bootstrapped_electra");
    BOOL platformBit = NO;
    uint32_t csFlags = 0;
    if (csops(0, CS_OPS_STATUS, &csFlags, sizeof(csFlags)) == 0) {
        platformBit = (csFlags & CS_PLATFORM_BINARY) != 0;
    }

    // ④ 越狱根形态归类。
    if (gAmeJBRootTag == nil) {
        if (diskRootHide) {
            gAmeJBRootTag = @"roothide";
        } else if (diskRootless || (gAmeJBFrameworkTag != nil && !diskRootful)) {
            // 有注入框架但无固定 /var/jb 也归 rootless（现代越狱注入即越狱）。
            gAmeJBRootTag = @"rootless";
        } else if (diskRootful || platformBit) {
            gAmeJBRootTag = @"rootful";
        }
    }

    // ⑤ 越狱家族（尽力而为，仅用于日志/诊断）。
    if (ameJBFileExists(@"/Applications/Dopamine.app") ||
        ameJBFileExists(@"/var/mobile/Library/Preferences/com.opa334.Dopamine.plist") ||
        ameJBAnyLoadedImageContains(@[@"libblackjack.dylib", @"systemhook.dylib"])) {
        gAmeJBFamilyTag = @"Dopamine";
    } else if (ameJBFileExists(@"/Applications/palera1nLoader.app") ||
               ameJBFileExists(@"/usr/bin/palera1n-helper") ||
               ameJBFileExists(@"/cores/payload")) {
        gAmeJBFamilyTag = @"palera1n";
    } else if (ameJBFileExists(@"/.installed_unc0ver")) {
        gAmeJBFamilyTag = @"unc0ver";
    } else if (ameJBFileExists(@"/var/binpack")) {
        gAmeJBFamilyTag = @"checkra1n";
    } else if (ameJBFileExists(@"/.bootstrapped_electra")) {
        gAmeJBFamilyTag = @"Electra";
    } else if ([gAmeJBFrameworkTag isEqualToString:@"libhooker"]) {
        gAmeJBFamilyTag = @"Taurine/Odyssey";
    }

    if ([gAmeJBRootTag isEqualToString:@"roothide"]) {
        gAmeJBEnvironment = AMEJBEnvironmentRootHide;
    } else if ([gAmeJBRootTag isEqualToString:@"rootless"]) {
        gAmeJBEnvironment = AMEJBEnvironmentRootless;
    } else if ([gAmeJBRootTag isEqualToString:@"rootful"]) {
        gAmeJBEnvironment = AMEJBEnvironmentRootful;
    } else {
        gAmeJBEnvironment = AMEJBEnvironmentNone;
    }

    if (gAmeJBEnvironment == AMEJBEnvironmentNone) {
        gAmeJBSummary = @"None";
    } else {
        NSString *rootDesc =
            [gAmeJBRootTag isEqualToString:@"roothide"] ? @"RootHide(random jbroot)"
          : [gAmeJBRootTag isEqualToString:@"rootless"] ? @"rootless(/var/jb)"
          : @"rootful";
        NSMutableString *s = [NSMutableString stringWithString:rootDesc];
        if (gAmeJBFrameworkTag) [s appendFormat:@" + %@", gAmeJBFrameworkTag];
        if (gAmeJBFamilyTag)     [s appendFormat:@" (%@)", gAmeJBFamilyTag];
        gAmeJBSummary = s.copy;
    }
    // 可辨识日志：越狱环境分类（env=1 None / 2 Rootful / 3 Rootless / 4 RootHide）。
    NSLog(@"[JB-ADAPT] jailbreak env detect: env=%ld root=%@ framework=%@ family=%@ -> %@",
          (long)gAmeJBEnvironment, gAmeJBRootTag ?: @"none",
          gAmeJBFrameworkTag ?: @"none", gAmeJBFamilyTag ?: @"none", gAmeJBSummary);
}

AMEJBEnvironment AMEJailbreakEnvironment(void) {
    dispatch_once(&gAmeJBDetectOnce, ^{ ameJBDetectEnvironmentOnce(); });
    return gAmeJBEnvironment;
}

NSString *AMEJailbreakEnvSummary(void) {
    dispatch_once(&gAmeJBDetectOnce, ^{ ameJBDetectEnvironmentOnce(); });
    return gAmeJBSummary ?: @"None";
}

BOOL isJITEnabled(BOOL checkCSFlags) {
    // ★ [JB-ADAPT] 收紧 JIT 判据：JIT 能力只认**真实证据**（dynamic-codesigning
    //   entitlement / CS_DEBUGGED）。原实现把 `isJailbroken` 当 JIT 能力代理 ——
    //   越狱【不等于】本 App 被授予 JIT：越狱机上本 App 若未开 JIT，该代理会误报
    //   可用，导致启动闸门跳过 JIT 获取 ⇒ 游戏 SIGILL。
    //   越狱环境改由启动闸门走「原生 JIT + 真能力自检」策略
    //   （AMEJailbreakNativeJITPathApplies / AMEJailbreakNativeJITReady），
    //   绝不预先声明 JIT 已开 —— 满足 [ROOTHIDE] 线「环境识别不得放宽 isJITEnabled」。
    if (!checkCSFlags && getEntitlementValue(@"dynamic-codesigning")) {
        return YES;
    }

    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
}

void openLink(UIViewController* sender, NSURL* link) {
    if (NSClassFromString(@"SFSafariViewController") == nil) {
        NSData *data = [link.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        UIImage *image = [UIImage imageWithCIImage:filter.outputImage scale:1.0 orientation:UIImageOrientationUp];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(300, 300), NO, 0.0);
        CGRect frame = CGRectMake(0, 0, 300, 300);
        [image drawInRect:frame];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:frame];
        imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
            message:link.absoluteString
            preferredStyle:UIAlertControllerStyleAlert];

        UIViewController *vc = UIViewController.new;
        vc.view = imageView;
        [alert setValue:vc forKey:@"contentViewController"];

        UIAlertAction* doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil) style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:doneAction];
        [sender presentViewController:alert animated:YES completion:nil];
    } else {
        SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:link];
        [sender presentViewController:vc animated:YES completion:nil];
    }
}

NSMutableDictionary* parseJSONFromFile(NSString *path) {
    NSError *error;

    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"[ParseJSON] Error: could not read %@: %@", path, error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"[ParseJSON] Error: could not parse JSON: %@", error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }
    return dict;
}

NSError* saveJSONToFile(NSDictionary *dict, NSString *path) {
    // TODO: handle rename
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData == nil) {
        return error;
    }
    BOOL success = [jsonData writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!success) {
        return error;
    }
    return nil;
}

// ★ [I18N] 启动器界面语言覆盖：持久化键。
// 刻意与系统的 AppleLanguages 分开——那是全局键，会牵动 App 内所有 bundle 的语言
// 选择，也不适合作为「跟随系统 / 指定语言」这种应用内偏好的保存位置。
NSString * const AmeLauncherLanguageDefaultsKey = @"ame_launcher_language";

#pragma mark - ★ [I18N] 语言解析核心（单一事实源）

// ★ [I18N] 语言解析缓存：'生效语言' 结果缓存 + 代数号（写入覆盖时自增使其失效）。
static NSInteger sAmeLanguageGeneration = 0;
static NSInteger sAmeEffectiveCodeGeneration = -1;
static NSString *sAmeEffectiveCodeCache = nil;
// 已加载的 <code>.lproj 包缓存（NSNull 表示"查过、没有"）。
static NSMutableDictionary<NSString *, id> *sAmeLangBundleCache = nil;
static NSString *sAmeResolvedLanguageCode = nil;
static NSBundle *sAmeResolvedLanguageBundle = nil;

// ★ [I18N] 启动器真正支持的语言（curated 白名单）。
// 依据：对 Natives/resources/*.lproj/Localizable.strings 的键集合盘点（见
// D:\CTF\_I18N_FIX.md「覆盖度表」）：只有 zh-Hans / zh-Hant / en / ja
// 这 4 个的翻译覆盖率 ≥95%；其余 48 个（de/ar/fr/ru…）覆盖率 ≤12%（上游 Pojav
// 遗留的旧键集合），选它们等于大面积回退英文 ⇒ 是"选了没用的壳子"，一律不列。
// zh-CN 与 zh-Hans 同为简体且被变体映射到 zh-Hans，不单独作为一项。
// ★ [AUDIT-DECIDE] E-2/A-8：km（高棉语）已从本白名单移除。km.lproj 实测是**中文内容**
//   （值里 14762 个 CJK 字 vs 仅 140 个高棉字），把它当"可选语言"列进选单 = 把中文界面
//   谎称成高棉语交给用户（违反「不能把中文当高棉语送出去」）。既然没有真实高棉语翻译，
//   就从"可选语言"里拿掉：选单不再列出它（AmeLauncherAvailableLanguageCodes 只回本表），
//   系统首选语言是 km-KH 时也不再命中它（AmeLauncherMatchLanguageCode 的第 3/4 步只在
//   本表内匹配），并会把旧用户存过的 km 偏好当"已不支持"清掉、安全回退到「跟随系统 / en」
//   （见 AmeLauncherPreferredLanguageOverride）。Info.plist 的 CFBundleLocalizations 同步去 km。
//   注：km.lproj 文件本身保留在包内（无引用、不可达），以免覆盖并发子代理在该文件上的改动。
NSArray<NSString *> *AmeLauncherSupportedLanguageCodes(void) {
    static NSArray<NSString *> *codes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        codes = @[@"zh-Hans", @"zh-Hant", @"en", @"ja"];
    });
    return codes;
}

// ★ [I18N] 系统语言代码 → 我们实际使用的 .lproj 代码（含变体映射）。
// 处理 zh-Hans-CN / zh-Hant-TW / en-GB / ja-JP 这类带脚本或地区后缀的代码，
// 以及 iOS 常见的"裸语言"（zh / en / ja）。匹配不到返回 nil（调用方回退 en）。
// ★ [AUDIT-DECIDE] km 已不在支持表内 ⇒ km-KH 也走不进任何分支，最终返回 nil ⇒ 回退 en。
NSString *AmeLauncherMatchLanguageCode(NSString *systemCode) {
    if (systemCode.length == 0) return nil;

    NSArray<NSString *> *supported = AmeLauncherSupportedLanguageCodes();
    NSString *lower = systemCode.lowercaseString;
    NSArray<NSString *> *parts = [lower componentsSeparatedByString:@"-"];
    NSString *lang = parts.count ? parts.firstObject : lower;
    NSString *script = nil;   // 4 字母脚本子标签：hans / hant / latn…
    NSString *region = nil;   // 2 字母或 3 位数字地区：cn / tw / us…
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *p = parts[i];
        if (p.length == 0) continue;
        BOOL hasDigit = [p rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound;
        if (p.length == 4 && !hasDigit) {
            script = p;
        } else if ((p.length == 2 && !hasDigit) || p.length == 3) {
            region = p;
        }
    }

    // 1) 精确命中我们的代码（zh-Hans / zh-Hant / en / ja，大小写不敏感；km 已移除）
    for (NSString *code in supported) {
        if ([code.lowercaseString isEqualToString:lower]) return code;
    }
    // 2) 中文：按脚本 / 地区判定简繁，其余一律简体
    if ([lang isEqualToString:@"zh"]) {
        if ([script isEqualToString:@"hant"]) return @"zh-Hant";
        if ([script isEqualToString:@"hans"]) return @"zh-Hans";
        static NSSet *tradRegions;
        static dispatch_once_t onceTrad;
        dispatch_once(&onceTrad, ^{
            tradRegions = [NSSet setWithArray:@[@"tw", @"hk", @"mo"]];
        });
        if (region && [tradRegions containsObject:region]) return @"zh-Hant";
        return @"zh-Hans";   // zh / zh-CN / zh-SG / zh-MY …
    }
    // 3) 其它语言：语言码直接对应（en-US→en, ja-JP→ja, …；km-KH 已不命中）
    for (NSString *code in supported) {
        if ([code.lowercaseString isEqualToString:lang]) return code;
    }
    // 4) 兜底：交给 Apple 的匹配器在"我们支持的语言"里挑（处理未覆盖的变体）
    NSArray<NSString *> *best = [NSBundle preferredLocalizationsFromArray:supported
                                                          forPreferences:@[systemCode]];
    if (best.count > 0 && [supported containsObject:best.firstObject]) {
        return best.firstObject;
    }
    return nil;
}

// ★ [I18N] 当前"实际生效"的界面语言代码。
// 语义：用户明确选择的语言 → 系统偏好语言最佳匹配 → 开发语言 en。
// 设置页显示与实际渲染都用它 ⇒ 显示与内容永远一致，不再"系统是英文却显示中文"。
NSString *AmeLauncherEffectiveLanguageCode(void) {
    if (sAmeEffectiveCodeCache.length > 0 && sAmeEffectiveCodeGeneration == sAmeLanguageGeneration) {
        return sAmeEffectiveCodeCache;
    }
    NSString *result = nil;
    NSString *override = AmeLauncherPreferredLanguageOverride();
    if (override.length > 0) {
        result = override;
    } else {
        for (NSString *pref in [NSLocale preferredLanguages]) {
            NSString *m = AmeLauncherMatchLanguageCode(pref);
            if (m.length > 0) { result = m; break; }
        }
    }
    if (result.length == 0) result = @"en";
    sAmeEffectiveCodeCache = result;
    sAmeEffectiveCodeGeneration = sAmeLanguageGeneration;
    return result;
}

// ★ [I18N] 读取用户选择；空串 / nil / 已不支持的旧值一律视为「跟随系统」。
// "已不支持"（旧版可能存过 de/ar 等空壳语言，以及本次移除的 km）会被当作未选择并顺手清理，
// 避免出现"切了却大面积英文"的破碎界面（幂等迁移）。
// ★ [AUDIT-DECIDE] E-2/A-8：旧用户若把界面语言设成 km，这里因 km 已不在支持表而
//   removeObjectForKey ⇒ 返回 nil ⇒ AmeLauncherEffectiveLanguageCode 回退到系统首选语言
//   的匹配，匹配不到再回退 en。即"安全回退到跟随系统/en"，不会卡在已移除的语言上。
NSString *AmeLauncherPreferredLanguageOverride(void) {
    NSString *code = [[NSUserDefaults standardUserDefaults] stringForKey:AmeLauncherLanguageDefaultsKey];
    if (code.length == 0) return nil;
    if (![AmeLauncherSupportedLanguageCodes() containsObject:code]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:AmeLauncherLanguageDefaultsKey];
        return nil;
    }
    return code;
}

// ★ [I18N] 写入/清除覆盖。code 为 nil 或空串时清除（回到跟随系统）。
void AmeLauncherSetPreferredLanguageOverride(NSString *code) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (code.length > 0) {
        [defaults setObject:code forKey:AmeLauncherLanguageDefaultsKey];
    } else {
        [defaults removeObjectForKey:AmeLauncherLanguageDefaultsKey];
    }
    [defaults synchronize];
    sAmeLanguageGeneration++;   // ★ [I18N] 使缓存的"生效语言"失效，下次 localize 重新解析
}

// ★ [I18N] 语言代码 → 人读显示名（用系统当前语言本地化）。取不到时回退返回代码本身。
// 例：系统中文时 zh-Hans → 「简体中文」；系统英文时 → 「Chinese, Simplified」。
NSString *AmeLauncherDisplayNameForLanguageCode(NSString *code) {
    if (code.length == 0) return @"";
    NSString *name = [[NSLocale currentLocale] localizedStringForLanguageCode:code];
    return name.length > 0 ? name : code;
}

#pragma mark - ★ [I18N-PARTIAL] 「部分翻译」语言（单一事实源 + 展示标注）

// ★ [I18N-PARTIAL] **单一事实源**：只有这一个地方列出"部分翻译"的语言代码。
// 背景（用户拍板）：ja.lproj 里 1608/1955 个键与 zh-Hans **逐字相同**（假名 2648 字 vs
// 汉字 13479 字）⇒ 日语界面里有大量内容其实是中文；但它又确实含真实日语翻译，比 km 那种
// "整包中文冒充外语"好 ⇒ **保留**日语、不撤其语言地位，只在用户能看到语言的地方如实标注
// 「部分翻译」。以后要追加别的"部分翻译"语言，只改这一个集合即可
// （展示层统一走 AmeLauncherDisplayNameAnnotatedForLanguageCode /
//  AmeLauncherPartiallyTranslatedNoteForLanguageCode）。
NSSet<NSString *> *AmeLauncherPartiallyTranslatedLanguageCodes(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"ja"]];
    });
    return set;
}

// ★ [I18N-PARTIAL] 是否被标为"部分翻译"。
BOOL AmeLauncherIsPartiallyTranslatedLanguage(NSString *code) {
    if (code.length == 0) return NO;
    return [AmeLauncherPartiallyTranslatedLanguageCodes() containsObject:code];
}

// ★ [I18N-PARTIAL] 展示名 = 语言名 +（部分翻译时）本地化的「（部分翻译）」后缀。
// 后缀文案随界面语言本地化（preference.lang.partial_suffix，四语齐全）。
NSString *AmeLauncherDisplayNameAnnotatedForLanguageCode(NSString *code) {
    NSString *name = AmeLauncherDisplayNameForLanguageCode(code);
    if (!AmeLauncherIsPartiallyTranslatedLanguage(code)) return name;
    return [NSString stringWithFormat:@"%@%@", name,
            localize(@"preference.lang.partial_suffix", @"部分翻译标注后缀")];
}

// ★ [I18N-PARTIAL] 部分翻译语言的补充说明（如「部分界面仍为中文」）；非部分翻译返回 nil。
NSString *AmeLauncherPartiallyTranslatedNoteForLanguageCode(NSString *code) {
    if (!AmeLauncherIsPartiallyTranslatedLanguage(code)) return nil;
    return localize(@"preference.lang.partial_note", @"部分界面仍为中文");
}

// ★ [I18N] 语言选单要列出的语言（= 真正支持的白名单，按显示名排序）。
// 保留旧函数名以兼容调用方；语义从"枚举包内所有 .lproj"收窄为白名单：
// 只列 AmeLauncherSupportedLanguageCodes()，绝不把空壳语言摆进选单。
NSArray<NSString *> *AmeLauncherAvailableLanguageCodes(void) {
    NSArray<NSString *> *codes = AmeLauncherSupportedLanguageCodes();
    return [codes sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [AmeLauncherDisplayNameForLanguageCode(a) localizedCaseInsensitiveCompare:
                AmeLauncherDisplayNameForLanguageCode(b)];
    }];
}

#pragma mark - ★ [I18N] 翻译覆盖率（选单标"部分翻译"用）

// ★ [I18N] 解析 <code>.lproj/Localizable.strings 为 键→值（仅用于覆盖率统计；
// 运行时取词仍走 bundle）。解析失败返回 nil ⇒ 上层按 100% 处理，统计绝不砸界面。
static NSDictionary<NSString *, NSString *> *AmeLauncherParseStrings(NSString *code) {
    if (code.length == 0) return nil;
    NSString *dir = [code stringByAppendingPathExtension:@"lproj"];
    NSString *path = [[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:dir]
                      stringByAppendingPathComponent:@"Localizable.strings"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text.length == 0) return nil;
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![line hasPrefix:@"\""]) continue;   // 跳过注释与空行
        NSRange kOpen = [line rangeOfString:@"\""];
        if (kOpen.location == NSNotFound) continue;
        NSRange kClose = [line rangeOfString:@"\"" options:0
                                       range:NSMakeRange(kOpen.location + 1, line.length - kOpen.location - 1)];
        if (kClose.location == NSNotFound) continue;
        NSString *key = [line substringWithRange:NSMakeRange(kOpen.location + 1, kClose.location - kOpen.location - 1)];
        NSRange eq = [line rangeOfString:@"=" options:0 range:NSMakeRange(kClose.location, line.length - kClose.location)];
        if (eq.location == NSNotFound) continue;
        NSRange vOpen = [line rangeOfString:@"\"" options:0 range:NSMakeRange(eq.location, line.length - eq.location)];
        if (vOpen.location == NSNotFound) continue;
        NSRange vClose = [line rangeOfString:@"\"" options:NSBackwardsSearch
                                       range:NSMakeRange(vOpen.location + 1, line.length - vOpen.location - 1)];
        if (vClose.location == NSNotFound) continue;
        NSString *val = [line substringWithRange:NSMakeRange(vOpen.location + 1, vClose.location - vOpen.location - 1)];
        if (key.length > 0) map[key] = val;
    }
    return map.count ? map : nil;
}

// ★ [I18N-ORDER] 某语言的"人工翻译率"（0.0~1.0）。以【英文】为基准键集：
// 值存在且与英文逐字不同 ⇒ 计为已翻译。
// ✗ 旧版以 zh-Hans 为基准、并对所有 zh* 直接返回 1.0；而 zh-Hans.lproj 当时是"英文占位
//   文件"，于是这个基准本身是错的，且永远报 100%，把"渲染成英文"的缺陷整个掩盖掉。
double AmeLauncherLanguageTranslatedRatio(NSString *code) {
    if (code.length == 0) return 1.0;
    if ([code isEqualToString:@"en"]) return 1.0;   // 英文即基准
    static NSDictionary<NSString *, NSString *> *en;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        en = AmeLauncherParseStrings(@"en");
    });
    NSDictionary<NSString *, NSString *> *tgt = AmeLauncherParseStrings(code);
    if (en.count == 0 || tgt.count == 0) return 1.0;   // 统计失败：不标百分比
    NSUInteger total = 0, localized = 0;
    for (NSString *k in en) {
        NSString *tv = tgt[k];
        if (tv.length == 0) continue;                    // 缺键 = 未翻译
        total++;
        if ([tv isEqualToString:en[k]]) continue;        // 与英文逐字相同 = 占位/未译
        localized++;
    }
    if (total == 0) return 1.0;
    return (double)localized / (double)total;
}

// ★ [I18N] 取词：在指定 <code>.lproj> 包里查 key；命中失败返回 nil。
static NSString *AmeLocalizedValue(NSBundle *bundle, NSString *key) {
    if (bundle == nil || key.length == 0) return nil;
    NSString *value = [bundle localizedStringForKey:key value:nil table:nil];
    if (value.length > 0 && ![value isEqualToString:key]) return value;
    return nil;
}

// ★ [I18N] <code>.lproj 包查询（带缓存）；找不到返回 nil。
static NSBundle *AmeBundleForLanguageCode(NSString *code) {
    if (code.length == 0) return nil;
    if (sAmeLangBundleCache == nil) sAmeLangBundleCache = [NSMutableDictionary dictionary];
    id cached = sAmeLangBundleCache[code];
    if (cached == (id)[NSNull null]) return nil;
    if ([cached isKindOfClass:[NSBundle class]]) return cached;
    NSString *path = [[NSBundle mainBundle] pathForResource:code ofType:@"lproj"];
    NSBundle *bundle = path.length ? [NSBundle bundleWithPath:path] : nil;
    sAmeLangBundleCache[code] = bundle ?: (id)[NSNull null];
    return bundle;
}

// ★ [I18N-ORDER] 启动最早期(任何 UI 构建之前)调用一次:解析并缓存"生效语言"、预热
// <code>.lproj 包缓存,并打印【自证日志】——生效语言 / 实际使用的 .lproj / 该语言的
// 真实翻译覆盖率 / Bundle.main 首选本地化 / 系统首选语言。
// 目的:让"设置显示中文、界面却渲染英文"这类【显示与渲染分叉】在日志里一眼可见
// (根因即:生效语言=zh-Hans,而 zh-Hans.lproj 曾是英文占位文件)。
void AmeLauncherPrimeLanguage(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *code = AmeLauncherEffectiveLanguageCode();   // 解析 + 缓存(单一事实源)
        NSBundle *bundle = AmeBundleForLanguageCode(code);     // 预热 bundle 缓存
        BOOL hasOverride = (AmeLauncherPreferredLanguageOverride().length > 0);
        double coverage = AmeLauncherLanguageTranslatedRatio(code);
        NSLog(@"[i18n][I18N-ORDER] effective=%@ followSystem=%@ bundle=%@ coverage=%.2f bundlePref=%@ systemPref=%@",
              code,
              hasOverride ? @"NO" : @"YES",
              bundle.bundlePath ?: @"(nil)",
              coverage,
              [[NSBundle mainBundle] preferredLocalizations].firstObject ?: @"(nil)",
              [NSLocale preferredLanguages].firstObject ?: @"(nil)");
        if (bundle == nil) {
            NSLog(@"[i18n][I18N-ORDER] ★ 警告:生效语言 %@ 没有对应 .lproj ⇒ 界面会整体回退英文", code);
        }
    });
}

// ★ [I18N] 统一取词入口（全启动器 2093 处调用都经此）。
// 单一事实源 = AmeLauncherEffectiveLanguageCode()（用户选择 → 系统最佳匹配 → en）：
// 不再依赖 NSLocalizedString 的"系统 bundle 解析"，因此改语言后只要重跑一次文案
// 就真的换过来；设置页显示的语言与这里实际渲染的语言永远一致。
// 回退链：当前语言 → en → 系统 UIKit 内建（"OK"/"Cancel" 等）→ key 本身。
NSString* localize(NSString* key, NSString* comment) {
    if (key.length == 0) return key ?: @"";
    NSString *code = AmeLauncherEffectiveLanguageCode();
    if (![code isEqualToString:sAmeResolvedLanguageCode] || sAmeResolvedLanguageBundle == nil) {
        sAmeResolvedLanguageCode = code;
        sAmeResolvedLanguageBundle = AmeBundleForLanguageCode(code);
    }
    NSString *value = AmeLocalizedValue(sAmeResolvedLanguageBundle, key);
    if (value) return value;
    if (![code isEqualToString:@"en"]) {
        value = AmeLocalizedValue(AmeBundleForLanguageCode(@"en"), key);
        if (value) return value;
    }
    value = AmeLocalizedValue([NSBundle bundleWithIdentifier:@"com.apple.UIKit"], key);
    if (value) return value;
    return key;
}

// 该错误是否意味着设备根本连不上网。值得穷举：原来只认
// NSURLErrorDataNotAllowed（应用被关蜂窝数据这一种窄形态），而最常见的离线
// 形态——飞行模式、无 Wi-Fi——是 NSURLErrorNotConnectedToInternet。
BOOL isConnectivityError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:   // 飞行模式、无 Wi-Fi、无信号
        case NSURLErrorDataNotAllowed:           // 应用被关蜂窝数据
        case NSURLErrorNetworkConnectionLost:    // 请求中途掉线
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:          // captive portal 与坏 DNS
        case NSURLErrorTimedOut:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorResourceUnavailable:
            return YES;
        default:
            return NO;
    }
}

void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...)
{
    va_list ap; 
    va_start (ap, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:ap];
    printf("%s", [body UTF8String]);
    if (![format hasSuffix:@"\n"]) {
        printf("\n");
    }
    va_end (ap);
}

CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    const CGFloat x = (x2 - x1);
    const CGFloat y = (y2 - y1);
    return (CGFloat) hypot(x, y);
}

//Ported from https://www.arduino.cc/reference/en/language/functions/math/map/
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max) {
    return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

CGFloat dpToPx(CGFloat dp) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return dp * screenScale;
}

CGFloat pxToDp(CGFloat px) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return px / screenScale;
}

void setButtonPointerInteraction(UIButton *button) {
    button.pointerInteractionEnabled = YES;
    button.pointerStyleProvider = ^ UIPointerStyle* (UIButton* button, UIPointerEffect* proposedEffect, UIPointerShape* proposedShape) {
        UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:button];
        return [NSClassFromString(@"UIPointerStyle") styleWithEffect:[NSClassFromString(@"UIPointerHighlightEffect") effectWithPreview:preview] shape:proposedShape];
    };
}

__attribute__((noinline,optnone,naked))
void* JIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}
// ★ [POCKETJ-JIT] Universal JIT 协议第 0 号调用:显式请求调试器脱离。
//   参考:EricoEC/PocketJLauncher · Vendor/StikJIT/Resources/universal.js(commands[0])
//   与 Vendor/StikJIT/INTEGRATION.md「Implement the universal protocol」给出的签名:
//     void JIT26Detach(void) { mov x16, #0; brk #0xf00d; ret }
//   x16=0 ⇒ universal.js 的 JIT26Detach() ⇒ 向 debugserver 发 "D" 并结束脚本循环。
//   ⚠ 调用时机(INTEGRATION.md 强制):必须先对【所有】初始 RX 区完成
//     JIT26PrepareRegion、建好可写别名,再调本函数;脚本一旦脱离,后加入的 RX 区
//     就无法再被服务。本仓库现有启动流程靠 universal.js 的 detachAfterFirstBr
//     在 dyld 补丁阶段的 JIT26PrepareRegion / JIT26PrepareRegionForPatching 之后
//     隐式脱离,故这里只补齐协议原语,不在启动路径上另加调用点 —— 擅自提前脱离会让
//     后续 brk 落在"无人服务"的窗口里,从而整体降级(★ [JIT-NOCRASH] 起,各调用
//     点已走 Safe 包装,不再硬崩,但 JIT 功能会因此退化)。详见
//     Natives/pocketj_jit/PORTING_NOTES.md。
__attribute__((noinline,optnone,naked))
void JIT26Detach(void) {
    asm("mov x16, #0 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void* JIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
   asm("mov x16, #2 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26SetDetachAfterFirstBr(BOOL value) {
   asm("mov x16, #3 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
   asm("mov x16, #4 \n"
       "brk #0xf00d \n"
       "ret");
}
void JIT26SendJITScript(NSString* script) {
    NSCAssert(script, @"Script must not be nil");
    BreakSendJITScript((char*)script.UTF8String, script.length);
}

// ★ [JIT-NOCRASH] ============================================================
// JIT26 brk 协议的统一 SIGTRAP 安全网
//
// universal 协议的每一步都靠 `brk` 与调试器握手（legacy 建区为 brk #0x69；其余
// 全部为 brk #0xf00d）。**调试器未就岗时执行 brk ⇒ SIGTRAP ⇒ 进程直接死**，
// 连"优雅放弃"的机会都没有（议题 #133「开启 JIT 后闪退」）。这里在调用窗口内
// 布一层 SIGTRAP handler + sigsetjmp/siglongjmp：无人应答时把"必死崩溃"转成
// "函数返回失败/降级"，由调用方跳过该步；调试器在岗时 brk 由调试器例外端口/
// ptrace 现场服务（Mach 例外优先于信号转换），本 handler 根本不会触发，成功
// 路径与裸调用逐字节一致 —— 安全网只在"无人应答"时兜底，不干扰正常 JIT。
//
// 嵌套/可重入（硬约束 5）：裸协议函数全是叶子（naked asm，只 brk+ret，不再调用
// 别人），单次窗口不会自嵌套；但调用方可能嵌套（外层窗口未退出时又走进另一个
// [JIT-NOCRASH] 包装）。旧的单缓冲 g_jit26TrapEnv 一旦被内层 sigsetjmp 覆盖，
// 外层的 siglongjmp 目标即失效 —— 故这里改成【按深度索引的 sigjmp_buf 槽位
// 栈】：第 0 层复用 g_jit26TrapEnv（保留旧名），更深层用 g_jit26TrapNestEnv[]；
// handler 永远跳到最内层活动窗口，最内层在跳回后把 depth 回退到自己的槽位，
// 外层窗口继续存活。g_jit26TrapArmed 保留为"是否有窗口在等 brk 应答"的兼容标志。
// ============================================================================
#define JIT26_TRAP_MAX_DEPTH 8

static sigjmp_buf g_jit26TrapEnv;                            // 第 0 层窗口缓冲（复用旧名）
static sigjmp_buf g_jit26TrapNestEnv[JIT26_TRAP_MAX_DEPTH];  // 更深层窗口槽位
static volatile sig_atomic_t g_jit26TrapDepth = 0;           // 活动窗口层数（0=未布网）
static volatile sig_atomic_t g_jit26TrapArmed = 0;           // 兼容标志：>0 即有窗口在等 brk

// 取 depth 对应的窗口缓冲。返回值恒非 NULL（depth 已被 push/pop 约束在 [0,MAX)）。
static sigjmp_buf *JIT26TrapSlotForDepth(int depth) {
    if (depth <= 0) return &g_jit26TrapEnv;
    if (depth < JIT26_TRAP_MAX_DEPTH) return &g_jit26TrapNestEnv[depth];
    return &g_jit26TrapNestEnv[JIT26_TRAP_MAX_DEPTH - 1];
}

static void JIT26TrapCatch(int sig) {
    if (!g_jit26TrapArmed || g_jit26TrapDepth <= 0) {
        // 不属于本安全网的 SIGTRAP：恢复默认语义原样致死，不吞异常
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    // 跳到最内层活动窗口；depth 与 sigaction 由该窗口自己回退。
    sigjmp_buf *env = JIT26TrapSlotForDepth((int)g_jit26TrapDepth - 1);
    siglongjmp(*env, 1);
}

// 进入窗口：安装 handler、登记本层槽位。返回本层索引；<0 = 深度超限无法布网，
// 调用方【必须】据此直接降级，绝不能再调用裸 brk 函数。
static int JIT26TrapWindowPush(struct sigaction *oldsa, sigjmp_buf **outEnv) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = JIT26TrapCatch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    if (oldsa) memset(oldsa, 0, sizeof(*oldsa));   // sigaction 万一失败也不回装垃圾
    sigaction(SIGTRAP, &sa, oldsa);

    int idx = (int)g_jit26TrapDepth;
    if (idx < 0 || idx >= JIT26_TRAP_MAX_DEPTH) {
        sigaction(SIGTRAP, oldsa, NULL);   // 回滚，保持环境原样
        if (outEnv) *outEnv = NULL;
        return -1;
    }
    if (outEnv) *outEnv = JIT26TrapSlotForDepth(idx);
    g_jit26TrapDepth = idx + 1;
    g_jit26TrapArmed = 1;
    return idx;
}

// 退出窗口：把 depth 回退到本层（处理"从 handler 跳回时更内层已被解开"的情形），
// 恢复原 SIGTRAP 处置。idx<0（未曾布网成功）时不动 depth。
static void JIT26TrapWindowPop(int idx, struct sigaction *oldsa) {
    if (idx >= 0 && g_jit26TrapDepth > idx) {
        g_jit26TrapDepth = idx;
    }
    if (g_jit26TrapDepth <= 0) {
        g_jit26TrapArmed = 0;
    }
    sigaction(SIGTRAP, oldsa, NULL);
}

// 布网失败（深度超限）时的统一降级日志。
static void JIT26LogWindowOverflow(const char *op) {
    NSLog(@"[JIT26] [JIT-NOCRASH] %s: trap-window depth overflow (%d) -- skipping raw brk (degrade)",
          op, (int)JIT26_TRAP_MAX_DEPTH);
}

// ★ [SHADER-SIGBUS] ============================================================
// 已 PrepareRegion 的 JIT 区登记表（纯旁路：只记录，不改变任何行为）。
//
// 为什么需要：SIGBUS 那一类崩溃的归属判定卡在"地址落在匿名 JIT 区"还是
// "落在真实 dylib 镜像"上（上一轮只有 `pc − region_base == dylib 偏移` 这一
// 条算式，两种解释都成立）。这张表让崩溃取证能直接标注每一帧的类别。
// 容量 32 已远超实际（启动期 PrepareRegion 调用不超过十余次）；满了就丢弃
// 最早的记录并计数，绝不分配内存（崩溃路径只读，写入点也在 JIT 握手路径上）。
// ============================================================================
#define JIT26_REGION_MAX 32
static struct { void *addr; size_t len; } g_jit26PreparedRegions[JIT26_REGION_MAX];
static volatile sig_atomic_t g_jit26PreparedCount = 0;   // 已登记条数（<= MAX）
static volatile sig_atomic_t g_jit26PreparedDropped = 0; // 溢出丢弃计数

void JIT26RecordPreparedRegion(void *addr, size_t len) {
    if (addr == NULL || len == 0) return;
    int n = (int)g_jit26PreparedCount;
    if (n < 0) n = 0;
    if (n >= JIT26_REGION_MAX) {
        g_jit26PreparedDropped = (sig_atomic_t)(g_jit26PreparedDropped + 1);
        return;
    }
    g_jit26PreparedRegions[n].addr = addr;
    g_jit26PreparedRegions[n].len  = len;
    g_jit26PreparedCount = (sig_atomic_t)(n + 1);
}

BOOL JIT26AddressInPreparedRegion(const void *p) {
    uintptr_t a = (uintptr_t)p;
    int n = (int)g_jit26PreparedCount;
    if (n > JIT26_REGION_MAX) n = JIT26_REGION_MAX;
    for (int i = 0; i < n; i++) {
        uintptr_t base = (uintptr_t)g_jit26PreparedRegions[i].addr;
        uintptr_t end  = base + g_jit26PreparedRegions[i].len;
        if (a >= base && a < end) return YES;
    }
    return NO;
}

// brk #0x69（legacy 建区）安全网：无人应答返回 NULL；调试器在岗返回裸函数值。
void* JIT26CreateRegionLegacySafe(size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26CreateRegionLegacySafe");
        return NULL;
    }
    void *result = NULL;
    if (sigsetjmp(*env, 1) == 0) {
        result = JIT26CreateRegionLegacy(len);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0x69 NOT serviced (no debugger) -- degraded, returning NULL");
        result = NULL;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return result;
}

// ★ [POCKETJ-JIT] brk #0xf00d cmd=0（显式请求调试器脱离）安全网：与
//   JIT26CreateRegionLegacySafe 同款。调试器已脱离时 brk 无人应答，捕获后返回
//   NO 而不使进程致死；调试器在岗时 brk 由调试器例外端口服务，行为与裸函数一致。
BOOL JIT26DetachSafe(void) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26DetachSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26Detach();
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=0 detach) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=1（准备可写别名）安全网。裸函数返回值无调用方
//   使用，这里只报"是否被调试器服务"；降级返回 NO。
BOOL JIT26PrepareRegionSafe(void *addr, size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26PrepareRegionSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        (void)JIT26PrepareRegion(addr, len);
        // ★ [SHADER-SIGBUS] 登记本区（只记录），供崩溃取证区分"匿名 JIT 区"与"真实 dylib"。
        JIT26RecordPreparedRegion(addr, len);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] PrepareRegion serviced (addr=%p len=%lu)", addr, (unsigned long)len);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=1 PrepareRegion) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=4（小区域、保留内容）安全网；降级返回 NO。
BOOL JIT26PrepareRegionForPatchingSafe(void *addr, size_t len) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26PrepareRegionForPatchingSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26PrepareRegionForPatching(addr, len);
        // ★ [SHADER-SIGBUS] 同 PrepareRegionSafe：登记本区供崩溃取证。
        JIT26RecordPreparedRegion(addr, len);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] PrepareRegionForPatching serviced (addr=%p len=%lu)", addr, (unsigned long)len);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=4 PrepareRegionForPatching) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=2（下发 UniversalJIT26 script）安全网；降级返回 NO。
BOOL JIT26SendJITScriptSafe(NSString *script) {
    if (script == nil) {
        NSLog(@"[JIT26] [JIT-NOCRASH] SendJITScript skipped: script is nil");
        return NO;
    }
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26SendJITScriptSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26SendJITScript(script);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] SendJITScript serviced");
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=2 SendJITScript) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ★ [JIT-NOCRASH] brk #0xf00d cmd=3（首次 brk 后是否自动脱离）安全网；降级返回 NO。
BOOL JIT26SetDetachAfterFirstBrSafe(BOOL value) {
    struct sigaction oldsa;
    sigjmp_buf *env = NULL;
    int idx = JIT26TrapWindowPush(&oldsa, &env);
    if (idx < 0) {
        JIT26LogWindowOverflow("JIT26SetDetachAfterFirstBrSafe");
        return NO;
    }
    BOOL serviced = YES;
    if (sigsetjmp(*env, 1) == 0) {
        JIT26SetDetachAfterFirstBr(value);
        NSDebugLog(@"[JIT26] [JIT-NOCRASH] SetDetachAfterFirstBr(%d) serviced", (int)value);
    } else {
        NSLog(@"[JIT26] [JIT-NOCRASH] brk #0xf00d(cmd=3 SetDetachAfterFirstBr) NOT serviced -- degraded");
        serviced = NO;
    }
    JIT26TrapWindowPop(idx, &oldsa);
    return serviced;
}

// ============================================================================
// ★ [POCKETJ-JIT] PocketJ 内置 JIT 前置门禁
//   (EricoEC/PocketJLauncher · Vendor/StikJIT/INTEGRATION.md
//    「Built-in StikJIT: Gate every entry point」)
//
//   内置 StikJIT 需要同时满足:iOS ≥ 17.4 · 宿主进程 get-task-allow ·
//   可读配对文件。注意 get-task-allow 属于宿主进程,必须在宿主侧检查。
//
//   ⚠ 本仓库暂未接入 Helper 扩展(进程不能自附加调试器 —— 见 PocketJ
//     Natives/stikdebug/StikDebugEngine.m 顶部同款注释),因此这里【只检测、
//     只记日志/供 UI 展示】,不做任何 vAttach 动作。等 Helper 扩展落地后,
//     这三个门禁就是启动 Helper 前的 guard。
// ============================================================================

BOOL AMEJITDeviceSupportsBuiltInStikJIT(void) {
    if (@available(iOS 17.4, *)) {
        return YES;
    }
    return NO;
}

// 宿主进程是否带 get-task-allow。使用 Security 框架 SPI(SecTask*),
// 原型见本文件顶部的 extern 声明;与 INTEGRATION.md 的 ObjC 示例同构,
// 但按文档写法释放正确(不复用本文件既有 getEntitlementValue —— 它有一处
// 释放后使用)。
BOOL AMEJITHasGetTaskAllow(void) {
    void *task = SecTaskCreateFromSelf(NULL);
    if (task == NULL) {
        return NO;
    }
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, @"get-task-allow", NULL);
    BOOL result = (value == kCFBooleanTrue);
    if (value != NULL) {
        CFRelease(value);
    }
    CFRelease(task);
    return result;
}

// 配对文件推荐位置(INTEGRATION.md「Store and import the pairing file」):
//   Documents/StikJIT/pairingFile.plist
// Info.plist 已置 UIFileSharingEnabled=true,用户可经 Finder/AFC 拷入。
// ★ [JIT-PAIRING] 配对文件在实战里会放在不同位置(用户按不同教程导入的):
//   以前只认 Documents/StikJIT/pairingFile.plist 一条 ⇒ 明明装了也报 pairing=NO
//   (用户实测:日志说"没装",但他确实装了)。故改为【多候选】逐个查,并记住命中的那条。
static NSString *gAmeJITPairingFoundPath = nil;

NSArray<NSString *> *AMEJITPairingFileCandidates(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSURL *documents = [NSFileManager.defaultManager
        URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask
       appropriateForURL:nil create:YES error:nil];
    NSURL *support = [NSFileManager.defaultManager
        URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
       appropriateForURL:nil create:YES error:nil];
    if (documents) {
        NSArray<NSString *> *subs = @[@"StikJIT", @"StikDebug", @"pairing", @""];
        NSArray<NSString *> *names = @[@"pairingFile.plist", @"pairingFile",
                                       @"mobiledevicepairing.plist", @"pairing_record.plist"];
        for (NSString *sub in subs) {
            NSURL *dir = sub.length ? [documents URLByAppendingPathComponent:sub isDirectory:YES] : documents;
            for (NSString *n in names) {
                [out addObject:[[dir URLByAppendingPathComponent:n] path]];
            }
        }
    }
    if (support) {
        for (NSString *sub in @[@"StikJIT", @"StikDebug", @""]) {
            NSURL *dir = sub.length ? [support URLByAppendingPathComponent:sub isDirectory:YES] : support;
            [out addObject:[[dir URLByAppendingPathComponent:@"pairingFile.plist"] path]];
        }
    }
    return out;
}

/// 返回【实际存在】的配对文件路径;都没有则返回推荐路径(供日志展示“应该放哪”)。
NSString *AMEJITPairingFilePath(void) {
    if (gAmeJITPairingFoundPath && [NSFileManager.defaultManager fileExistsAtPath:gAmeJITPairingFoundPath]) {
        return gAmeJITPairingFoundPath;
    }
    for (NSString *p in AMEJITPairingFileCandidates()) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
            gAmeJITPairingFoundPath = p;
            return p;
        }
    }
    return AMEJITPairingFileCandidates().firstObject;
}

BOOL AMEJITHasPairingFile(void) {
    for (NSString *p in AMEJITPairingFileCandidates()) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
            gAmeJITPairingFoundPath = p;
            return YES;
        }
    }
    return NO;
}

/// ★ [JIT-PAIRING] 单独探测“使能工具是否已装”——用 URL scheme 探,与配对文件无关。
///   避免把“没找到配对文件”误读成“工具没装”。
BOOL AMEJITEnablerAppInstalled(void) {
    NSArray<NSString *> *schemes = @[@"stikdebug", @"stikjit", @"sidestore", @"stosdebug"];
    for (NSString *sc in schemes) {
        NSURL *u = [NSURL URLWithString:[sc stringByAppendingString:@"://"]];
        if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
            return YES;
        }
    }
    return NO;
}

// 在一次 JIT 获取动作前把门禁状态打到日志(只读,无副作用)。
void AMEJITLogPocketJReadiness(NSString *context) {
    BOOL hasPairing = AMEJITHasPairingFile();
    NSLog(@"[JIT] [POCKETJ-JIT] readiness(%@): ios17_4=%@ get-task-allow=%@ "
          @"enabler-app-installed=%@ pairing-file=%@ found=%@ (推荐位置=%@)",
          context ?: @"?",
          AMEJITDeviceSupportsBuiltInStikJIT() ? @"YES" : @"NO",
          AMEJITHasGetTaskAllow() ? @"YES" : @"NO",
          AMEJITEnablerAppInstalled() ? @"YES" : @"NO",
          hasPairing ? @"YES" : @"NO",
          hasPairing ? (AMEJITPairingFilePath() ?: @"(?)") : @"(未找到,已试多路径)",
          AMEJITPairingFileCandidates().firstObject ?: @"(nil)");
}

// ★ [JIT-ADAPT] ============================================================
// 「市面上能开 JIT 的工具」统一适配层（声明/设计说明见 utils.h）。
// 唯一目的：让主游戏启动路径也能像 headless 一样「按 debug.jit_enabler 调起/引导」，
// 而不是永远走 stikjit://；并且「工具没装」时立刻给可辨识提示，不白等一整个超时窗口。
// 判定「已开」仍由调用方统一走 AMEJITWaitReadyVerified()（真拿到可写 JIT 区）。
// ============================================================================
// showDialog 定义在 ios_uikit_bridge.m（避免为一个原型引入整份 UIKit 桥接头）。
extern void showDialog(NSString* title, NSString* message);

// 本层负责的 enabler 取值（auto / stikjit 交回调用方既有分支，保持默认行为）。
static BOOL ameJITAdapt_handlesEnabler(NSString *e) {
    if (![e isKindOfClass:NSString.class] || e.length == 0) return NO;
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"stikdebug", @"stosdebug", @"jitstreamer",
                                    @"sidejitserver", @"sidestore", @"trollstore",
                                    @"altstore", @"sideloadly", @"jailbreak", @"manual"]];
    });
    return [set containsObject:e];
}

// 该 enabler 是否「本机无 URL 可调、必须由用户手动开」。
static BOOL ameJITAdapt_isManualEnabler(NSString *e) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"sidejitserver", @"altstore", @"sideloadly",
                                    @"jailbreak", @"manual"]];
    });
    return e != nil && [set containsObject:e];
}

// canOpenURL 只对 LSApplicationQueriesSchemes 里登记过的 scheme 可信（与 Info.plist 一致）。
static BOOL ameJITAdapt_schemeProbeable(NSString *scheme) {
    static NSSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"stikjit", @"stikdebug", @"sidestore", @"stosdebug"]];
    });
    return scheme != nil && [set containsObject:scheme];
}

NSString *AMEJITConfiguredEnablerKey(void) {
    id e = getPrefObject(@"debug.jit_enabler");
    if (![e isKindOfClass:NSString.class] || [(NSString *)e length] == 0) return @"auto";
    return (NSString *)e;
}

BOOL AMEJITConfiguredExternalEnablerIsActive(void) {
    return ameJITAdapt_handlesEnabler(AMEJITConfiguredEnablerKey());
}

NSString *AMEJITConfiguredEnablerDisplayName(void) {
    NSString *e = AMEJITConfiguredEnablerKey();
    if ([e isEqualToString:@"stikdebug"])      return @"StikDebug (stikdebug://)";
    if ([e isEqualToString:@"stosdebug"])      return @"StosDebug";
    if ([e isEqualToString:@"jitstreamer"])    return @"JitStreamer (EB)";
    if ([e isEqualToString:@"sidejitserver"])  return @"SideJITServer";
    if ([e isEqualToString:@"sidestore"])      return @"SideStore (SideJIT)";
    if ([e isEqualToString:@"trollstore"])     return @"TrollStore";
    if ([e isEqualToString:@"altstore"])       return @"AltStore (AltServer / AltJIT)";
    if ([e isEqualToString:@"sideloadly"])     return @"Sideloadly (Sideloadly Daemon)";
    // manual / jailbreak：没有可安装的“工具 App”，返回 nil 让调用方用通用文案。
    return nil;
}

NSString *AMEJITConfiguredEnablerGuidanceKey(void) {
    NSString *e = AMEJITConfiguredEnablerKey();
    if (!ameJITAdapt_isManualEnabler(e)) return nil;
    return [NSString stringWithFormat:@"jit.wait.%@", e];
}

AMEJITEnablerActionResult AMEJITOpenConfiguredExternalEnabler(void) {
    NSString *enabler = AMEJITConfiguredEnablerKey();
    if (!ameJITAdapt_handlesEnabler(enabler)) {
        return AMEJITEnablerActionResultNotHandled;   // auto / stikjit → 调用方既有分支
    }

    // ① 手动/外部-attach 类：本机没有 URL 可调。交调用方：给引导 + 进入可验证等待。
    if (ameJITAdapt_isManualEnabler(enabler)) {
        NSLog(@"[JIT-ADAPT] enabler=%@ -> manual/guidance only (no on-device URL); user enables "
              @"JIT externally, we wait & self-check", enabler);
        return AMEJITEnablerActionResultManual;
    }

    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"";
    BOOL noScript = getPrefBool(@"debug.jit26_script_disable");

    // ② URL 类：按各工具官方交接机制构造（与 headless ame139_requestJIT 同源同形）。
    NSURL *url = nil;
    if ([enabler isEqualToString:@"trollstore"]) {
        // TrollStore（apple-magnifier://，v2.0.12+ 的“open with JIT”）
        url = [NSURL URLWithString:[NSString stringWithFormat:
            @"apple-magnifier://enable-jit?bundle-id=%@", bundleId]];
    } else if ([enabler isEqualToString:@"sidestore"]) {
        // SideStore / SideJIT（复用仓库既有 <17.4 分支同款 URL，避免猜未验证的形式）
        url = [NSURL URLWithString:[NSString stringWithFormat:
            @"sidestore://sidejit-enable?pid=%d", getpid()]];
    } else if ([enabler isEqualToString:@"stosdebug"]) {
        // StosDebug：stosdebug://enableJIT?bundleId=&appName=&script=<b64>
        NSString *appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Amethyst";
        NSMutableString *u = [NSMutableString stringWithFormat:
            @"stosdebug://enableJIT?bundleId=%@&appName=%@", bundleId, appName];
        if (!noScript) {
            NSData *script = [NSData dataWithContentsOfFile:
                [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            if (script) [u appendFormat:@"&script=%@", [script base64EncodedStringWithOptions:0]];
        }
        url = [NSURL URLWithString:u];
    } else if ([enabler isEqualToString:@"jitstreamer"]) {
        // JitStreamer-EB：WireGuard 隧道（服务器地址 fd00::）+ HTTP :9172/launch_app/<bundle>
        url = [NSURL URLWithString:[NSString stringWithFormat:
            @"http://[fd00::]:9172/launch_app/%@", bundleId]];
    } else if ([enabler isEqualToString:@"stikdebug"]) {
        // 只注册 stikdebug:// 的 StikDebug 版本（PocketJ/StikJIT INTEGRATION.md 形式）。
        NSString *scriptDataString = @"";
        if (!noScript) {
            NSData *script = [NSData dataWithContentsOfFile:
                [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            if (script) {
                scriptDataString = [@"&script-data=" stringByAppendingString:
                    [script base64EncodedStringWithOptions:0]];
            }
        }
        if (scriptDataString.length > 0) {
            url = [NSURL URLWithString:[NSString stringWithFormat:
                @"stikdebug://enable-jit?bundle-id=%@&pid=%d%@", bundleId, getpid(), scriptDataString]];
        } else {
            // 无脚本（用户禁用脚本 / 非 TXM 机型）：退化为 script-name 形式。
            url = [NSURL URLWithString:[NSString stringWithFormat:
                @"stikdebug://enable-jit?bundle-id=%@&pid=%d&script-name=universal.js", bundleId, getpid()]];
        }
    }

    if (url == nil) {
        NSLog(@"[JIT-ADAPT] enabler=%@ -> no URL built (treated as manual)", enabler);
        return AMEJITEnablerActionResultManual;
    }

    // ③ 预检（仅对已登记 scheme 可信）：探不到即工具没装 ⇒ 立刻回 MissingTool，不白等。
    if (ameJITAdapt_schemeProbeable(url.scheme) &&
        ![UIApplication.sharedApplication canOpenURL:url]) {
        NSLog(@"[JIT-ADAPT] canOpenURL(%@) == NO -- JIT enabler app not installed", url.scheme);
        return AMEJITEnablerActionResultMissingTool;
    }

    // ④ 调起；回执失败时给一次可辨识提示（工具未装 / scheme 未启用）。
    void (^ameJITAdapt_fireURL)(void) = ^{
        [UIApplication.sharedApplication openURL:url options:@{}
            completionHandler:^(BOOL success) {
                NSLog(@"[JIT-ADAPT] openURL scheme=%@ -> %d", url.scheme, success);
                if (!success) {
                    NSString *tool = AMEJITConfiguredEnablerDisplayName() ?: enabler;
                    showDialog(localize(@"jit.wait.abort.title", nil),
                        [NSString stringWithFormat:localize(@"jit.wait.missing.tool", nil), tool]);
                }
            }];
    };
    if ([NSThread isMainThread]) {
        ameJITAdapt_fireURL();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ameJITAdapt_fireURL);
    }
    NSLog(@"[JIT-ADAPT] enabler=%@ -> opened %@ (will verify with brk #0x69 before launch)",
          enabler, url.scheme);
    return AMEJITEnablerActionResultOpened;
}

#ifndef P_TRACED
#define P_TRACED 0x00000800 /* process is being traced by a debugger (ptrace) */
#endif

// 向内核查询当前进程是否存在活的 ptrace 关系。P_TRACED 在调试器附加的
// 整个生命周期内置位、脱离瞬间清零，是"调试器还在"的准确信号。
BOOL JIT26DebuggerAttachedViaPtrace(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return NO;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// 检测通过 Mach 异常端口持有本任务的调试器。lldb/debugserver 以
// ptrace(PT_ATTACH) 拿到任务端口后 PT_DETACH 但保留端口——此后 P_TRACED
// 为 0 而调试器完全存活、持续服务 EXC_BREAKPOINT（JIT26 的 brk #0x69 /
// brk #0xf00d 正是这样被服务的）。任务级 BREAKPOINT/SOFTWARE 非空
// handler 即"JIT26 调试器就位"的可靠信号。
BOOL JIT26DebuggerViaExceptionPorts(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t kr = task_get_exception_ports(mach_task_self(),
                                                EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE,
                                                masks, &count, handlers, behaviors, flavors);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (handlers[i] != MACH_PORT_NULL) {
            return YES;
        }
    }
    return NO;
}

BOOL JIT26IsLikelyDebuggerKeepAttached(void) {
    // 调试器 spawn 的进程 ppid != 1（launchd 为 1）。
    if (getppid() != 1) {
        return YES;
    }
    // StikJIT/SideJIT 对已运行进程按 pid 附加，ppid 恒为 1；且启用工具可能
    // 退出导致进程被重挂到 launchd（ppid 回 1）而 CS_DEBUGGED 残留——单看
    // ppid 会把完全可用的会话误判为"无调试器"。回退到活的 ptrace 标志：
    // 附加期间恒置位，脱离即清零，既不错过附加流，也不漏掉真脱离。
    if (JIT26DebuggerAttachedViaPtrace()) {
        return YES;
    }
    // lldb/debugserver PT_DETACH 后 P_TRACED 回 0，但仍通过任务级异常端口
    // 服务 EXC_BREAKPOINT。把活的任务级 BREAKPOINT/SOFTWARE handler 视为
    // "调试器在岗"——它正是必须服务 brk #0x69 的实体。
    return JIT26DebuggerViaExceptionPorts();
}

// ★ [JIT-FLOW] ============================================================
// 「JIT 是否真的可用」的**可验证能力**判据（回答实机 <2s「jit complete」假成功）。
//
// 为什么必须自己做、不能信外部工具：StikDebug 的「jit complete」是**它自己**弹的，
// 它是外部 App，可能 1~2 秒就报完成而实际没把服务 `brk #0x69` 的调试器留给我们
// （attach 即退、脚本没装、或没给任何 RX 映射）。而现有 UI 闸门/等待条件用的是
// `isJITEnabled(false)`，它只反映：
//   (a) dynamic-codesigning entitlement / 越狱（**能力声明**，非实测）；
//   (b) CS_DEBUGGED —— 一个**粘滞**标志：任何一次 ptrace 附加都会置位，调试器随后
//       立刻脱离/脚本没装也一样置位 ⇒ 等待条件在 attach 那一刻（可 <2s）即被满足。
// `JIT26IsLikelyDebuggerKeepAttached()` 同理：它只看 ppid / P_TRACED / 异常端口，
// 即「调试器进程还在」，而**调试器在岗 ≠ 它在服务 brk #0x69**。
//
// 唯一权威信号（复用仓里既有的 JIT26 建区链）：真的发一次 `brk #0x69` 向调试器
// 要一块 JIT 区，并尽力验证其可写。拿到 ⇒ `[JIT-FLOW] verified`；拿不到 ⇒
// `[JIT-FLOW] false-positive guard triggered`，调用方必须当「未开」处理并给明确提示。
// 结论缓存：成功一次即记住，避免重复 brk（legacy 脚本只服务一次断点）。
// ============================================================================
static void *gAmeJITVerifiedRegion = NULL;
static BOOL   gAmeJITVerified = NO;
static NSTimeInterval gAmeJITLastVerifyAttempt = 0;
static int    gAmeJITVerifyAttempts = 0;

// 主动申请并（尽力）写入一块 JIT 区，作为「真能力」判据。失败限流 2s
// （等待循环 200ms 一轮，若不限流会每轮发一次 brk）。
BOOL AMEJITVerifyWritableJITRegion(void) {
    if (gAmeJITVerified) {
        return YES;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gAmeJITLastVerifyAttempt > 0 && (now - gAmeJITLastVerifyAttempt) < 2.0) {
        return NO;
    }
    gAmeJITLastVerifyAttempt = now;
    gAmeJITVerifyAttempts++;

    size_t len = (size_t)getpagesize();
    void *r = JIT26CreateRegionLegacySafe(len);   // brk #0x69；无人服务时返回 NULL 不致死
    if (r == NULL) {
        NSLog(@"[JIT-FLOW] false-positive guard triggered (#%d): brk #0x69 NOT serviced -- NOT counting JIT as "
              @"enabled (isJITEnabled=%d keepAttached=%d traced=%d exn=%d)",
              gAmeJITVerifyAttempts, isJITEnabled(false), JIT26IsLikelyDebuggerKeepAttached(),
              JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
        return NO;
    }
    // 尽力证明可写：先把这一段改成可写再写读，随后恢复 RX。mprotect 失败也不否决——
    // 「调试器服务了 brk #0x69 并返回了映射」本身已是权威信号。
    BOOL writable = NO;
    if (mprotect(r, len, PROT_READ | PROT_WRITE) == 0) {
        volatile unsigned char *p = (volatile unsigned char *)r;
        p[0] = 0xA5;
        p[len - 1] = 0x5A;
        writable = (p[0] == 0xA5 && p[len - 1] == 0x5A);
        // 恢复为可执行的 JIT 区，避免影响调试器/脚本对该区的后续用途。
        mprotect(r, len, PROT_READ | PROT_EXEC);
    }
    gAmeJITVerifiedRegion = r;   // 留驻（只一页），供后续复用/诊断
    gAmeJITVerified = YES;
    NSLog(@"[JIT-FLOW] verified: debugger serviced brk #0x69 -> JIT region @%p (%zu bytes, writable=%d) -- real JIT capability confirmed",
          r, len, writable);
    return YES;
}

// 等待就绪谓词（供 UI 闸门/headless 的等待循环使用）：
//   · 非镜像路径：JVM 直接执行自产代码 ⇒ **唯一**可信判据是「执行式探针真的跑过」
//     （两型 mapping：匿名私有 + 文件背衬 COW）。★ [JIT-STATUS] 不再用裸
//     isJITEnabled(false) —— CS_DEBUGGED / entitlement 只是"能力声明"，巨魔
//     TrollStore 上 JIT 被关/未生效时仍可能粘滞置位 ⇒ 会假绿并"一启动就闪退"。
//   · Universal/镜像路径：先要调试器在岗（便宜，挡掉连 attach 都没有的情形），再用
//     「真能拿到并写入一块 JIT 区」定案（挡掉 attach-即成功的 <2s 假阳性）。
BOOL AMEJITWaitReadyVerified(void) {
    if (!DeviceNeedsDebugJITMapping()) {
        return AMEJITBothMappingKindsExecutable();
    }
    if (!JIT26IsLikelyDebuggerKeepAttached()) {
        return NO;
    }
    return AMEJITVerifyWritableJITRegion();
}

// ★ [JIT-STATUS] ============================================================
// 当前进程「JIT 到底能不能用」的三态判据（状态栏显示 + 启动门禁共用）。
//
// 设计要点（对齐用户诉求「自动判断环境，然后申请权限（如果不是开了 JIT 才进的）」）：
//   · 能力 C（这台设备/这个安装方式**有能力**提供 JIT）≠ 实际可用 A（本次进程现在
//     真的能执行自产代码）。巨魔 TrollStore 装机自带 JIT 能力，但用户把 JIT 关掉/
//     未生效时进程仍不可用 —— 此时绝不能显示"已开启"，也绝不允许直接启动（否则
//     JVM 首帧 JIT 取指 KERN_PROTECTION_FAILURE/SIGBUS 闪退）。
//   · 唯一可信的"可用"A 判据 = **真的试一次**：执行式探针（真 mmap + 写一条指令 +
//     mprotect RX + 执行 + 回读，含文件背衬 COW 型），或调试器服务 brk #0x69 拿到
//     可写 JIT 区。CS_DEBUGGED / entitlement / TrollStore 装机都只是"能力声明"。
// ============================================================================

// 两型 mapping 的执行式探针（2s 限流缓存）。状态显示与门禁共用，避免每帧 mmap。
static os_unfair_lock gAmeJITStatusProbeLock = OS_UNFAIR_LOCK_INIT;
static int gAmeJITStatusProbe = 0;              // 0=未知 / 1=两型都OK / -1=否
static NSTimeInterval gAmeJITStatusProbeTs = 0;

static void ameJITInvalidateStatusProbe(void) {
    os_unfair_lock_lock(&gAmeJITStatusProbeLock);
    gAmeJITStatusProbe = 0;
    gAmeJITStatusProbeTs = 0;
    os_unfair_lock_unlock(&gAmeJITStatusProbeLock);
}

BOOL AMEJITBothMappingKindsExecutable(void) {
    os_unfair_lock_lock(&gAmeJITStatusProbeLock);
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gAmeJITStatusProbe == 0 || (now - gAmeJITStatusProbeTs) > 2.0) {
        AMEJITExecProbeResult rAnon = AMEDeviceProbeJITExecCapability();
        AMEJITExecProbeResult rFile = AMEDeviceProbeFileBackedJITExecCapability();
        BOOL ok = (rAnon == AMEJITExecProbeExecOK) && (rFile == AMEJITExecProbeExecOK);
        gAmeJITStatusProbe = ok ? 1 : -1;
        gAmeJITStatusProbeTs = now;
        NSLog(@"[JIT-STATUS] both-kinds exec-probe: anon=%ld file-backed=%ld -> %@ "
              @"(1=exec-OK 2=mprotect-denied 3=exec-FAULTED 4=inconclusive)",
              (long)rAnon, (long)rFile, ok ? @"EXECUTABLE" : @"NOT-executable");
    }
    BOOL ok = (gAmeJITStatusProbe > 0);
    os_unfair_lock_unlock(&gAmeJITStatusProbeLock);
    return ok;
}

// 可用性三态缓存（1s），避免状态刷新/等待循环里反复重探。
static os_unfair_lock gAmeJITUsabilityLock = OS_UNFAIR_LOCK_INIT;
static NSTimeInterval gAmeJITUsabilityTs = 0;
static AMEJITUsability gAmeJITUsabilityCache = AMEJITUsabilityUnavailable;
static NSString *gAmeJITUsabilityWhy = nil;
static NSString *gAmeJITUsabilityKey = nil;

void AMEJITInvalidateUsabilityCache(void) {
    os_unfair_lock_lock(&gAmeJITUsabilityLock);
    gAmeJITUsabilityTs = 0;
    gAmeJITUsabilityWhy = nil;
    os_unfair_lock_unlock(&gAmeJITUsabilityLock);
}

NSString *AMEJITUsabilityDisplayKey(AMEJITUsability u) {
    switch (u) {
        case AMEJITUsabilityVerified:       return @"i18n_str_421";             // JIT: 已开启
        case AMEJITUsabilityPermissionOnly: return @"ame_jit_status_perm_only"; // 权限已给，未验证
        case AMEJITUsabilityUnavailable:
        default:                            return @"i18n_str_422";             // JIT: 未开启
    }
}

AMEJITUsability AMEJITCurrentUsability(NSString **whyOut, NSString **keyOut) {
    os_unfair_lock_lock(&gAmeJITUsabilityLock);
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (gAmeJITUsabilityTs > 0 && (now - gAmeJITUsabilityTs) < 1.0 && gAmeJITUsabilityWhy) {
        if (whyOut) *whyOut = gAmeJITUsabilityWhy;
        if (keyOut) *keyOut = gAmeJITUsabilityKey;
        AMEJITUsability cached = gAmeJITUsabilityCache;
        os_unfair_lock_unlock(&gAmeJITUsabilityLock);
        return cached;
    }

    // (1) 能力声明信号（C）：证明"有办法提供 JIT"，但不代表本次可用。
    BOOL realEnt    = AMEDeviceHasRealJITEntitlement();          // dynamic-codesigning / allow-jit
    BOOL declared   = isJITEnabled(NO);                          // 上面两条 + CS_DEBUGGED
    BOOL tsInstall  = isTrollStoreInstall();                     // 巨魔装机（entitlement AND 磁盘标记）
    BOOL noSandbox  = getEntitlementValue(@"com.apple.private.security.no-sandbox");
    BOOL jbPath     = AMEJailbreakNativeJITPathApplies();
    BOOL capability = (declared || realEnt || tsInstall || noSandbox || jbPath);

    // (2) 实际可用（A）：只有"真跑过的证据"才算。
    BOOL verified = NO;
    NSString *how = nil;
    if (gAmeJITVerified) {
        verified = YES;
        how = @"verified JIT region (brk #0x69 serviced)";
    } else if (DeviceNeedsDebugJITMapping()) {
        // 镜像/Universal 路径：JIT 只能由在场调试器代映射。显示层不主动发 brk
        // （避免消耗 legacy 脚本唯一次断点）⇒ 只给"权限已给但不保证可用"，
        // 真正的 brk 验证放到启动等待里（AMEJITWaitReadyVerified）。
        verified = NO;
        how = JIT26IsLikelyDebuggerKeepAttached()
            ? @"mirror: live debugger present (brk #0x69 verify deferred to launch)"
            : @"mirror: permission/CS_DEBUGGED present but NO live debugger";
    } else {
        // 非镜像：JVM 直接执行自产代码 ⇒ 执行式探针即最终判据（巨魔上自建
        // CS_DEBUGGED 生效则通过；JIT 关掉/未生效则失败 ⇒ 绝不假绿）。
        verified = AMEJITBothMappingKindsExecutable();
        how = verified ? @"exec-probe(map+write+exec+readback) OK"
                       : @"exec-probe FAILED (declared capability is NOT usable right now)";
    }

    AMEJITUsability u = verified ? AMEJITUsabilityVerified
                       : (capability ? AMEJITUsabilityPermissionOnly : AMEJITUsabilityUnavailable);

    NSString *why = [NSString stringWithFormat:
        @"%@ | capability(declared=%d ent=%d trollstore=%d no-sandbox=%d jb=%@) "
        @"verifiedRegion=%p mirror=%d debugger=%d %@",
        how, declared, realEnt, tsInstall, noSandbox, AMEJailbreakEnvSummary(),
        gAmeJITVerifiedRegion, DeviceNeedsDebugJITMapping(),
        JIT26IsLikelyDebuggerKeepAttached(), AMEJITCapabilitySummary()];
    NSLog(@"[JIT-STATUS] usability=%ld (%@) %@",
          (long)u, u == AMEJITUsabilityVerified ? @"verified/可用"
                : (u == AMEJITUsabilityPermissionOnly ? @"permission-only/权限已给未验证" : @"unavailable/不可用"),
          why);

    gAmeJITUsabilityCache = u;
    gAmeJITUsabilityWhy = why;
    gAmeJITUsabilityKey = AMEJITUsabilityDisplayKey(u);
    gAmeJITUsabilityTs = now;
    os_unfair_lock_unlock(&gAmeJITUsabilityLock);
    if (whyOut) *whyOut = why;
    if (keyOut) *keyOut = AMEJITUsabilityDisplayKey(u);
    return u;
}

// ★ [JIT-ENV] 环境分类（多证据；进程内缓存一次）。
AMEJITEnvKind AMEJITEnvironmentKind(void) {
    static AMEJITEnvKind cached = AMEJITEnvKindUnknown;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        AMEJBEnvironment jb = AMEJailbreakEnvironment();
        BOOL ts = isTrollStoreInstall();
        if (ts) {
            cached = AMEJITEnvKindTrollStore;
        } else if (jb == AMEJBEnvironmentRootful || jb == AMEJBEnvironmentRootless ||
                   jb == AMEJBEnvironmentRootHide) {
            cached = AMEJITEnvKindJailbroken;
        } else if (getEntitlementValue(@"get-task-allow")) {
            // 侧载（AltStore/Sideloadly/SideStore 等）通常带 get-task-allow，
            // JIT 需外部工具（StikDebug 等）attach。
            cached = AMEJITEnvKindSideload;
        } else {
            cached = AMEJITEnvKindPlain;
        }
        NSLog(@"[JIT-ENV] detected env=%@ (trollstore=%d jb=%@ get-task-allow=%d no-sandbox=%d)",
              AMEJITEnvironmentName(cached), ts, AMEJailbreakEnvSummary(),
              getEntitlementValue(@"get-task-allow") ? 1 : 0,
              getEntitlementValue(@"com.apple.private.security.no-sandbox") ? 1 : 0);
    });
    return cached;
}

NSString *AMEJITEnvironmentName(AMEJITEnvKind kind) {
    switch (kind) {
        case AMEJITEnvKindTrollStore: return @"trollstore";
        case AMEJITEnvKindJailbroken: return @"jailbreak";
        case AMEJITEnvKindSideload:   return @"sideload";
        case AMEJITEnvKindPlain:      return @"plain";
        default:                      return @"unknown";
    }
}

// 巨魔自开 JIT：no-sandbox 安装下本 App 可用「子进程 PT_TRACE_ME + 父进程 PT_DETACH」
// 让**父进程（本进程）**获得 CS_DEBUGGED（= 与 main.m 启动期同一机制，可重入）。
// 返回 YES = 本次调用后拿到了 CS_DEBUGGED（真可用性仍由执行式探针复核）。
static BOOL ameJITTrollStoreSelfEnable(NSString **reasonOut) {
    if (!getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        if (reasonOut) *reasonOut = @"no-sandbox entitlement absent (not a TrollStore/self-managed install)";
        return NO;
    }
    const char *exe = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    if (exe == NULL || exe[0] == '\0') {
        if (reasonOut) *reasonOut = @"main bundle executable path unavailable";
        return NO;
    }
    int pid = 0;
    int ret = posix_spawnp(&pid, exe, NULL, NULL, (char *[]){(char *)exe, (char *)"", NULL}, environ);
    if (ret != 0) {
        if (reasonOut) *reasonOut = [NSString stringWithFormat:@"posix_spawn failed ret=%d errno=%d", ret, errno];
        return NO;
    }
    waitpid(pid, NULL, WUNTRACED);
    ptrace(PT_DETACH, pid, NULL, 0);
    kill(pid, SIGTERM);
    wait(NULL);
    return isJITEnabled(true);   // CS_DEBUGGED（与 main.m 同判据）
}

AMEJITEnsureResult AMEJITEnsureJITUsable(NSString **reasonOut) {
    AMEJITEnvKind env = AMEJITEnvironmentKind();
    NSString *envName = AMEJITEnvironmentName(env);

    NSString *why0 = nil;
    AMEJITUsability u0 = AMEJITCurrentUsability(&why0, NULL);
    NSLog(@"[JIT-ENV] env=%@ | jit_at_launch=%@ (usability=%ld) %@",
          envName, (u0 == AMEJITUsabilityVerified) ? @"YES" : @"NO", (long)u0, why0);

    if (u0 == AMEJITUsabilityVerified) {
        if (reasonOut) *reasonOut = @"already usable (exec-probe/brk verified)";
        AMEJITAppendCrashNote([NSString stringWithFormat:
            @"[JIT-ENV] env=%@ jit_at_launch=YES effective=available", envName]);
        return AMEJITEnsureResultAlreadyUsable;
    }

    NSLog(@"[JIT-ENV] env=%@ jit not usable yet ⇒ requesting JIT permission", envName);
    AMEJITEnsureResult res = AMEJITEnsureResultFailed;
    NSString *reqWhy = nil;

    switch (env) {
        case AMEJITEnvKindTrollStore: {
            BOOL ok = ameJITTrollStoreSelfEnable(&reqWhy);
            if (ok) {
                res = AMEJITEnsureResultNowUsable;
            } else {
                // 自开不行 ⇒ 引导一次（用户点 TrollStore/工具里的开关），
                // 由 UI 的使能器流程去 apple-magnifier:// 申请。
                res = AMEJITEnsureResultNeedsExternal;
            }
            break;
        }
        case AMEJITEnvKindJailbroken:
            res = AMEJITEnsureResultNeedsExternal;
            reqWhy = [NSString stringWithFormat:
                @"jailbreak native JIT not usable; enable 'Allow JIT in Apps' (Dopamine) / platform JIT (%@)",
                AMEJailbreakEnvSummary()];
            break;
        case AMEJITEnvKindSideload:
            res = AMEJITEnsureResultNeedsExternal;
            reqWhy = @"needs external JIT tool (StikDebug/SideStore/StosDebug/AltStore…)";
            break;
        case AMEJITEnvKindPlain:
        default:
            res = AMEJITEnsureResultNeedsExternal;
            reqWhy = @"plain-signed build: JIT needs an external tool/debugger; cannot self-enable";
            break;
    }

    // 复核实际可用性（先作废探针/可用性缓存，反映"刚申请"后的真实状态）。
    ameJITInvalidateStatusProbe();
    AMEDeviceInvalidateJITExecProbe();
    AMEJITInvalidateUsabilityCache();
    NSString *why1 = nil;
    AMEJITUsability u1 = AMEJITCurrentUsability(&why1, NULL);
    BOOL eff = (u1 == AMEJITUsabilityVerified);

    NSLog(@"[JIT-ENV] request result=%@ reason=%@",
          eff ? @"OK" : (res == AMEJITEnsureResultNeedsExternal ? @"NEEDS-EXTERNAL" : @"FAIL"),
          reqWhy ?: @"-");
    NSLog(@"[JIT-ENV] effective=%@ (usability=%ld) %@",
          eff ? @"available" : @"unavailable", (long)u1, why1);
    AMEJITAppendCrashNote([NSString stringWithFormat:
        @"[JIT-ENV] env=%@ jit_at_launch=NO ⇒ request result=%@ effective=%@ reason=%@",
        envName, eff ? @"OK" : @"FAIL", eff ? @"available" : @"unavailable", reqWhy ?: @"-"]);

    if (eff) {
        if (reasonOut) *reasonOut = @"now usable after request";
        return AMEJITEnsureResultNowUsable;
    }
    if (reasonOut) *reasonOut = reqWhy ?: why1;
    return res;
}

NSString *AMEJITLaunchGateReason(void) {
    if (AMEJITWaitReadyVerified()) {
        NSLog(@"[JIT-STATUS] pre-launch gate: ALLOW (JIT verified usable; verifiedRegion=%p)",
              AMEJITVerifiedRegionPtr());
        return nil;
    }
    NSString *why = nil;
    AMEJITUsability u = AMEJITCurrentUsability(&why, NULL);
    NSString *reason = [NSString stringWithFormat:
        @"JIT not really usable at launch (usability=%ld, env=%@): %@",
        (long)u, AMEJITEnvironmentName(AMEJITEnvironmentKind()), why ?: @"-"];
    NSLog(@"[JIT-STATUS] pre-launch gate: BLOCK -- %@", reason);
    AMEJITAppendCrashNote([NSString stringWithFormat:@"[JIT-STATUS] launch blocked: %@", reason]);
    return reason;
}

// ★ [JIT-NOLOG] 可导出崩溃日志写入（与 JavaLauncher 的 [VER-ISOLATE]/[LOG-FIX] 同路径）。
void AMEJITAppendCrashNote(NSString *note) {
    if (note.length == 0) return;
    const char *home = getenv("POJAV_HOME");
    NSString *instRoot = ameVIInstanceRoot();
    NSString *path = nil;
    if (instRoot.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:instRoot
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        path = [instRoot stringByAppendingPathComponent:@"native-crash.log"];
    } else if (home != NULL && home[0] != '\0') {
        path = [@(home) stringByAppendingPathComponent:@"native-crash.log"];
    }
    if (path.length == 0) {
        NSLog(@"[JIT-NOLOG] cannot resolve native-crash.log path (POJAV_HOME unset) -- note in main log only: %@", note);
        return;
    }
    NSString *line = [NSString stringWithFormat:@"[%lld] %@\n", (long long)time(NULL), note];
    const char *cpath = path.fileSystemRepresentation;
    int fd = open(cpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        NSLog(@"[JIT-NOLOG] open(native-crash.log=%@) failed: %s -- note in main log only: %@",
              path, strerror(errno), note);
        return;
    }
    ssize_t n = write(fd, line.UTF8String, strlen(line.UTF8String));
    close(fd);
    if (n <= 0) {
        NSLog(@"[JIT-NOLOG] write(native-crash.log) failed -- note in main log only: %@", note);
    }
    // 硬链接 <POJAV_HOME>/native-crash.log → 实例真身（与 [LOG-FIX] 同口径；
    // 目标已是同一 inode 的硬链接时，删名再建不会动到实例内那份）。
    if (instRoot.length > 0 && home != NULL && home[0] != '\0') {
        NSString *dst = [@(home) stringByAppendingPathComponent:@"native-crash.log"];
        if (![path isEqualToString:dst]) {
            ameVIHardLinkLog(path, dst);
        }
    }
}

// 已通过验证的 JIT 区（未验证过返回 NULL）。供诊断/复用。
void *AMEJITVerifiedRegionPtr(void) {
    return gAmeJITVerifiedRegion;
}

// JIT 等待轮询的有界版本：最长 timeout 秒（超时返回 NO，调用方走超时
// 重试弹窗），每 10s 一条心跳日志，挂起间隙（迭代间隔 >2s）不计入超时预算。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label) {
    NSDate *start = [NSDate date];
    NSDate *ame179_lastIter = [NSDate date];
    BOOL ame181_foreground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    int ame181_csFlags = 0;
    csops(getpid(), 0, &ame181_csFlags, sizeof(ame181_csFlags));
    NSLog(@"[JIT] %@ wait begin: startForeground=%d traced=%d exn=%d csdbg=%d",
          label ?: @"JIT", ame181_foreground, JIT26DebuggerAttachedViaPtrace(),
          JIT26DebuggerViaExceptionPorts(), (ame181_csFlags & CS_DEBUGGED) != 0);
    for (;;) {
        if (condition()) {
            NSTimeInterval ame181_waited = -[start timeIntervalSinceNow];
            NSLog(@"[JIT] %@ condition satisfied after %.1fs (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_waited, JIT26DebuggerAttachedViaPtrace(),
                  JIT26DebuggerViaExceptionPorts());
            return YES;
        }
        BOOL ame181_nowForeground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
        if (ame181_nowForeground != ame181_foreground) {
            NSLog(@"[JIT] %@ app %s while waiting (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_nowForeground ? "returned to FOREGROUND" : "went to BACKGROUND",
                  JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            ame181_foreground = ame181_nowForeground;
        }
        // 挂起间隙豁免：stikjit:// 把 App 切后台后 iOS 可能挂起进程，墙钟
        // 空转会烧穿等待预算；迭代间隔 >2s（正常节拍 0.2s）视为挂起，前推
        // start 补回预算。
        NSTimeInterval ame179_gap = -[ame179_lastIter timeIntervalSinceNow];
        if (ame179_gap > 2.0) {
            NSLog(@"[JIT] %@: suspension gap of %.0fs excluded from timeout budget",
                  label ?: @"JIT", ame179_gap);
            start = [start dateByAddingTimeInterval:ame179_gap];
        }
        ame179_lastIter = [NSDate date];
        NSTimeInterval waited = -[start timeIntervalSinceNow];
        if (waited >= timeout) {
            NSLog(@"[JIT] %@ wait TIMED OUT after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            return NO;
        }
        if (fmod(waited, 10.0) < 0.2) {
            NSLog(@"[JIT] %@: still waiting after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
        }
        usleep(1000 * 200);
    }
}

// JIT 等待成功后的自愈式主队列派发：后台被楔死的主线程上 dispatch_async
// 的续接块可能永不执行。三道防线：①常规派发；②前台激活重派；③后台看门狗
//（120s 窗口，仅前台未达时重派并钉死锚点）。delivered 只在主队列读写，
// 多重派发不会导致块双跑。
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label) {
    if (!block) return;
    __block volatile BOOL delivered = NO;
    __block id ame185_obs = nil;
    void (^ame185_cleanup)(void) = ^{
        if (ame185_obs) {
            [[NSNotificationCenter defaultCenter] removeObserver:ame185_obs];
            ame185_obs = nil;
        }
    };
    dispatch_block_t attempt = ^{
        if (delivered) return;
        delivered = YES;
        ame185_cleanup();
        block();
    };
    dispatch_async(dispatch_get_main_queue(), attempt);
    ame185_obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *ame185_note) {
        if (delivered) { ame185_cleanup(); return; }
        NSLog(@"[JIT] self-healing dispatch: refire on foreground (label=%@)", label);
        dispatch_async(dispatch_get_main_queue(), attempt);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (int ame185_i = 0; ame185_i < 60; ame185_i++) {
            if (delivered) { ame185_cleanup(); return; }
            usleep(2 * 1000 * 1000);
            if (delivered) { ame185_cleanup(); return; }
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                NSLog(@"[JIT] self-healing dispatch: watchdog redispatch #%d (label=%@)", ame185_i + 1, label);
                dispatch_async(dispatch_get_main_queue(), attempt);
            }
        }
        if (!delivered) {
            NSLog(@"[JIT] self-healing dispatch: NOT delivered after 120s -- main queue wedged (label=%@)", label);
        }
        ame185_cleanup();
    });
}

BOOL DeviceCanCreateRXMap(void) {
    // ★ [JIT-CACHE] 语义澄清（不要再用它当"JIT 可用"的判据）：
    //   本函数只回答「mprotect(PROT_EXEC) 这个**调用**会不会被拒」——它证明的是
    //   **权限**（entitlement/CS 标志允许把匿名页标成 RX），不是**能力**
    //   （标成 RX 之后那块页**真的能被执行**）。两者在 iOS 上不等价：
    //   arm64 + PPL/code-signing 校验发生在**取指**那一刻，mprotect 可以返回 0
    //   而页仍然不可执行 ⇒ 之后执行该页 = EXC_BAD_ACCESS/KERN_PROTECTION_FAILURE
    //   ⇒ SIGBUS（真机 db76cfb 就是这么崩的：HotSpot code cache 建好后第一帧 JIT
    //   代码取指即 SIGBUS）。
    //   真能力判据请用 AMEDeviceCanExecuteJITCode()（真写一条指令并真的执行它）。
    //   This is only guaranteed to be accurate when JIT is already enabled. Obviously this is only useful for vphone and similar internal environments where JIT is always enabled.
    uint32_t *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) {
        NSLog(@"DeviceCanCreateRXMap: mmap failed: %s", strerror(errno));
        return NO;
    }
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, getpagesize(), PROT_READ | PROT_EXEC) | mprotect(map, getpagesize(), PROT_READ | PROT_EXEC);
    munmap(map, getpagesize());
    return ret == 0;
}

// ★ [JB-ADAPT] 越狱下「原生 JIT」策略与真能力判据（设计约束见 utils.h [JB-ADAPT]）。
//   · PathApplies：环境分类可辨识出越狱（仅用于【选策略】：不走"等外部工具"那条）。
//     **不表示 JIT 已开** —— 是否真能 JIT 由下面的 Ready 用真能力说话。
//   · Ready：本进程能否【真的把一段自己写进去的指令执行掉】（见下方 [JIT-CACHE]）。
//     绝不再用 DeviceCanCreateRXMap()（那只证 mprotect 这一**调用**没被拒，
//     不证页**真的可执行**）。
BOOL AMEJailbreakNativeJITPathApplies(void) {
    return AMEJailbreakEnvironment() != AMEJBEnvironmentNone;
}

// ★ [JIT-CACHE] ==============================================================
// 「原生 JIT」的**执行式**真能力判据（修正 db76cfb 的不足判据）。
//
// 事故（iPad11,6 / iPadOS 17.2 / rootful 越狱 / build db76cfb）：
//   闸门只凭 DeviceCanCreateRXMap() 通过就打了
//     [JB-ADAPT] native JIT confirmed (env=rootful): anonymous page mprotect(RX) OK
//     -- no debugger/brk needed, launching without any external JIT tool
//   于是【跳过调试器/使能器】，直接 JLI_Launch。JVM 建好 code cache 后第一帧 JIT
//   代码取指即 EXC_BAD_ACCESS/SIGBUS（KERN_PROTECTION_FAILURE）⇒ 线程 #54 死在
//   无名镜像里，帧 16 才是 JavaCalls::call_helper。
//
// 根因（判据不等价）：**mprotect(PROT_EXEC) 成功 ≠ 该页真的可执行**。
//   · mprotect 只过"能不能把这块 vma 标成 RX"这层（jailbreak/CS_DEBUGGED 会影响）；
//   · 真正的判定在【取指】时由内核 + PPL/code-signing 复核：页不是合法的 JIT
//     mapping（缺 MAP_JIT / 无 CS_DEBUGGED / 无调试器代映射）⇒ 取指失败
//     = KERN_PROTECTION_FAILURE ⇒ SIGBUS。
//   所以「匿名页 mprotect(RX) OK」是一个**假阳性**信号，与 JVM 的真实需求无关。
//
// 本判据：写一条真指令进匿名页、标 RX、**真的调用它**；拿回预期返回值才算可用。
//   取指失败（保护失败）会被下面的 signal 安全网接住并判否 —— 这正是原探针做不到
//   的那一步（原探针从不去执行，所以永远看不到这个失败）。
//   保守方向正确：探针失败 ⇒ 不再跳过调试器链路（宁可多 attach 一次）。
// ============================================================================

#define AME_JIT_PROBE_RETVAL 42

#if defined(__arm64__) || defined(__aarch64__)
// mov x0, #42 ; ret
static const uint32_t kAmeJITProbeCode[] = { 0xD2800540u, 0xD65F03C0u };
#elif defined(__x86_64__)
// mov eax, 42 ; ret
static const uint8_t  kAmeJITProbeCode[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
#else
static const uint8_t  kAmeJITProbeCode[] = { 0 };
#endif

static sigjmp_buf gAmeJITExecProbeEnv;
static volatile sig_atomic_t gAmeJITExecProbeArmed = 0;

// 探针安全网：只在探针窗口内接管 SIGBUS/SIGSEGV；窗口外原样致死（绝不吞别人的崩溃）。
static void ameJITExecProbeSignalHandler(int sig) {
    if (!gAmeJITExecProbeArmed) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    gAmeJITExecProbeArmed = 0;
    siglongjmp(gAmeJITExecProbeEnv, 1);
}

static os_unfair_lock gAmeJITExecProbeLock = OS_UNFAIR_LOCK_INIT;

// 缓存：0=未探 1=可执行 -1=不可执行
static int  gAmeJBNativeJITProbe = 0;
static BOOL gAmeJBNativeJITReady = NO;

// 逃生开关：强制走某条 JIT 路径（env AMETHYST_JIT_PATH / 偏好 debug.jit_path）。
//   auto（默认）| native（强制认定原生 JIT 可用，跳过执行探针）| debugger（强制走
//   调试器/attach 链路，绝不由原生路径放行）| external（同 debugger，语义上由外部
//   使能器负责）。
//   用途：真机 A/B 二分 —— 怀疑哪条路径就把另一条钉死，不用重新打包。
static AMEJITPathForce gAmeJITPathForce = AMEJITPathForceUnknown;
static os_unfair_lock gAmeJITPathForceLock = OS_UNFAIR_LOCK_INIT;

AMEJITPathForce AMEJITPathForceMode(void) {
    os_unfair_lock_lock(&gAmeJITPathForceLock);
    if (gAmeJITPathForce == AMEJITPathForceUnknown) {
        NSString *v = nil;
        const char *env = getenv("AMETHYST_JIT_PATH");
        if (env != NULL && env[0] != '\0') {
            v = [NSString stringWithUTF8String:env];
        }
        if (v.length == 0) {
            id p = getPrefObject(@"debug.jit_path");
            if ([p isKindOfClass:NSString.class]) v = p;
        }
        v = [v lowercaseString];
        AMEJITPathForce f = AMEJITPathForceAuto;
        if ([v isEqualToString:@"native"]) {
            f = AMEJITPathForceNative;
        } else if ([v isEqualToString:@"debugger"] || [v isEqualToString:@"jit26"] ||
                   [v isEqualToString:@"attach"]) {
            f = AMEJITPathForceDebugger;
        } else if ([v isEqualToString:@"external"] || [v isEqualToString:@"enabler"]) {
            f = AMEJITPathForceExternal;
        } else if (v.length > 0 && ![v isEqualToString:@"auto"]) {
            NSLog(@"[JIT-CACHE] unknown AMETHYST_JIT_PATH/debug.jit_path value \"%@\" -- using auto", v);
        }
        gAmeJITPathForce = f;
        NSLog(@"[JIT-CACHE] JIT path force = %ld (0=auto 1=native 2=debugger 3=external; env AMETHYST_JIT_PATH / pref debug.jit_path)",
              (long)f);
        // ★ [JIT-EXEC-2] 把"auto 的实际含义"写清楚：本机组合下它等价于 debugger。
        //   flags==0（非 iOS26 无 MirrorMappedCodeCache 那套 / 无 TXM）+ 无真 JIT entitlement
        //   ⇒ 没有任何 Apple 支持的原生 JIT 机制 ⇒ auto 不再尝试 native（默认即 debugger 路径）。
        if (f == AMEJITPathForceAuto) {
            BOOL nativeMechanismExists = AMEDeviceHasRealJITEntitlement()
                || DeviceHasJITFlags(JIT_FLAG_IS_IOS_26)
                || DeviceHasJITFlags(JIT_FLAG_HAS_TXM);
            NSLog(@"[JIT-EXEC-2] debug.jit_path unset (auto) -> effective default = %@ on this device "
                  @"(nativeMechanismExists=%d jitFlags=0x%X %@). Native is only reconsidered when a real "
                  @"JIT mechanism exists; otherwise the debugger/enabler path is the only sound one.",
                  nativeMechanismExists ? @"auto(probe)" : @"debugger", nativeMechanismExists,
                  (unsigned)DeviceGetJITFlags(NO), AMEJITCapabilitySummary());
        }
    }
    AMEJITPathForce f = gAmeJITPathForce;
    os_unfair_lock_unlock(&gAmeJITPathForceLock);
    return f;
}

// 执行式真能力探针（**不缓存**，每次真跑；给日志/二分用）。
//   返回 1=ExecOK / 2=mprotect 被拒 / 3=mprotect 过了但取指保护失败（db76cfb 假阳性）。
AMEJITExecProbeResult AMEDeviceProbeJITExecCapability(void) {
    size_t pg = (size_t)getpagesize();
    // 与 HotSpot code cache 同型的映射：匿名 + 私有 + 先 RW。
    void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        NSLog(@"[JIT-CACHE] exec-probe: mmap(RW anon) failed: %s", strerror(errno));
        return AMEJITExecProbeMprotectFailed;
    }
    memcpy(p, kAmeJITProbeCode, sizeof(kAmeJITProbeCode));
    // 使指令缓存生效（arm64 上写代码后必须做，否则可能执行到陈旧指令）。
    sys_icache_invalidate(p, pg);
    if (mprotect(p, pg, PROT_READ | PROT_EXEC) != 0) {
        int e = errno;
        munmap(p, pg);
        NSLog(@"[JIT-CACHE] exec-probe: mprotect(RX) denied: %s -- no native JIT permission", strerror(e));
        return AMEJITExecProbeMprotectFailed;
    }

    // 装安全网（保存/恢复原处置，绝不长期占用 SIGBUS/SIGSEGV）。
    struct sigaction sa, oldBus, oldSegv;
    memset(&sa, 0, sizeof(sa));
    memset(&oldBus, 0, sizeof(oldBus));
    memset(&oldSegv, 0, sizeof(oldSegv));
    sa.sa_handler = ameJITExecProbeSignalHandler;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &oldBus);
    sigaction(SIGSEGV, &sa, &oldSegv);

    gAmeJITExecProbeArmed = 1;
    volatile int ameGot = -1;
    volatile AMEJITExecProbeResult ameRes = AMEJITExecProbeExecFaulted;
    if (sigsetjmp(gAmeJITExecProbeEnv, 1) == 0) {
        // volatile 函数指针：防止编译期把这次调用优化掉（判据的全部意义在这条 call）。
        int (*volatile ameFn)(void) = (int (*)(void))p;
        ameGot = ameFn();
        ameRes = (ameGot == AME_JIT_PROBE_RETVAL) ? AMEJITExecProbeExecOK
                                                 : AMEJITExecProbeExecFaulted;
    } else {
        // 取指/取数保护失败：内核不让我们执行这块页 —— 这正是 db76cfb 的崩溃点。
        ameRes = AMEJITExecProbeExecFaulted;
    }
    gAmeJITExecProbeArmed = 0;

    sigaction(SIGBUS, &oldBus, NULL);
    sigaction(SIGSEGV, &oldSegv, NULL);
    munmap(p, pg);

    if (ameRes != AMEJITExecProbeExecOK) {
        NSLog(@"[JIT-CACHE] exec-probe: mprotect(RX) returned 0 BUT executing the page faulted "
              @"(ret=%d) -- anonymous *permission* OK, real *execution* NOT: page is not a valid "
              @"JIT mapping (missing MAP_JIT / CS_DEBUGGED / debugger-mapped RX). This is exactly "
              @"the KERN_PROTECTION_FAILURE/SIGBUS seen on db76cfb.", ameGot);
        // 顺手记下"现在到底缺哪一项"，直接回答「越狱下还需不需要 debugger attach」：
        //   页可执行需要下列任一条成立 —— CS_DEBUGGED（调试器附着）/ 真 JIT entitlement /
        //   由调试器代映射的 RX（JIT26 协议）。三项都没有 ⇒ 必须走 attach/使能器链路。
        int ameCsFlags = 0;
        csops(getpid(), 0, &ameCsFlags, sizeof(ameCsFlags));
        NSLog(@"[JIT-CACHE] exec-probe context: dynamic-codesigning=%d allow-jit=%d get-task-allow=%d "
              @"CS_DEBUGGED=%d -- if all four are 0/NO, JIT pages can only become executable via a "
              @"debugger attach (JIT enabler) on this device.",
              getEntitlementValue(@"dynamic-codesigning"),
              getEntitlementValue(@"com.apple.security.cs.allow-jit"),
              getEntitlementValue(@"get-task-allow"),
              (ameCsFlags & CS_DEBUGGED) != 0);
    }
    return (AMEJITExecProbeResult)ameRes;
}

// 缓存版：给启动闸门/状态栏用（一次会话只探一次，避免每次刷新都 mmap + 改信号处置）。
//   注意：只把 ExecOK 当"可用"；任何其它结果都判否（保守 ⇒ 走调试器/使能器链路）。
BOOL AMEDeviceCanExecuteJITCode(void) {
    os_unfair_lock_lock(&gAmeJITExecProbeLock);
    if (gAmeJBNativeJITProbe == 0) {
        AMEJITExecProbeResult r = AMEDeviceProbeJITExecCapability();
        gAmeJBNativeJITProbe = (r == AMEJITExecProbeExecOK) ? 1 : -1;
        gAmeJBNativeJITReady = (gAmeJBNativeJITProbe > 0);
    }
    BOOL ok = gAmeJBNativeJITReady;
    os_unfair_lock_unlock(&gAmeJITExecProbeLock);
    return ok;
}

// 显式作废缓存（例：用户刚通过使能器/调试器拿到了 CS_DEBUGGED，能力可能已改变）。
void AMEDeviceInvalidateJITExecProbe(void) {
    os_unfair_lock_lock(&gAmeJITExecProbeLock);
    gAmeJBNativeJITProbe = 0;
    gAmeJBNativeJITReady = NO;
    os_unfair_lock_unlock(&gAmeJITExecProbeLock);
    // ★ [JIT-STATUS] 能力可能已变 ⇒ 三态判据与其执行式探针缓存一并作废，
    //   让下一次状态显示/启动门禁反映"此刻"的真实可用性（不假绿、也不假黄）。
    ameJITInvalidateStatusProbe();
    AMEJITInvalidateUsabilityCache();
}

// ★ [JIT-EXEC-2] ============================================================
// 1) 能力来源（Apple 层面）真值判断 + 可读摘要
// 2) 第二型 mapping（文件背衬 + 私有 COW）的执行式探针
// 3) 启动前权威闸门（AMEJITExec2LaunchBlockReason）
//
// 事实基础（13:30 新包 .ips，iPad11,6 / 17.2 / rootful）：
//   · codeSigningFlags = 0x32002004 ⇒ CS_DEBUGGED(0x10000000) 已置位、CS_GET_TASK_ALLOW 已置位，
//     进程仍在 JIT 取指上 EXC_BAD_ACCESS/SIGBUS（byProc="exc handler"）。
//     ⇒ **CS_DEBUGGED 不是"页可执行"的证明**；只有"真的执行过一次"才算。
//   · 取指失败的地址落在 `mapped file … r--/rw- SM=COW ...`（ESR=0x82000007 ⇒ Instruction Abort,
//     Translation fault L3；maxprot 里没有 X ⇒ 该页永远不可能变可执行），
//     而 [JIT-CACHE] 的探针测的是 MAP_PRIVATE|MAP_ANONYMOUS 页 ⇒ **不同型**。
// ============================================================================

// 真 JIT entitlement 只有这两条。CS_DEBUGGED 不算：13:30 的崩溃进程带着它照样 SIGBUS。
BOOL AMEDeviceHasRealJITEntitlement(void) {
    return getEntitlementValue(@"dynamic-codesigning")
        || getEntitlementValue(@"com.apple.security.cs.allow-jit");
}

static int ameJITExec2ReadCsFlags(BOOL *ok) {
    int flags = 0;
    int r = csops(getpid(), 0, &flags, sizeof(flags));
    if (ok) *ok = (r == 0);
    return flags;
}

BOOL AMEDeviceHasAppleJITCapability(void) {
    if (AMEDeviceHasRealJITEntitlement()) return YES;
    BOOL ok = NO;
    int flags = ameJITExec2ReadCsFlags(&ok);
    return (ok && (flags & CS_DEBUGGED) != 0);
}

NSString *AMEJITCapabilitySummary(void) {
    BOOL csOK = NO;
    int flags = ameJITExec2ReadCsFlags(&csOK);
    return [NSString stringWithFormat:@"dyn-cs=%d allow-jit=%d cs_debugged=%d csops=%d cs_flags=0x%X",
            getEntitlementValue(@"dynamic-codesigning") ? 1 : 0,
            getEntitlementValue(@"com.apple.security.cs.allow-jit") ? 1 : 0,
            (csOK && (flags & CS_DEBUGGED) != 0) ? 1 : 0,
            csOK ? 0 : -1,
            (unsigned)flags];
}

// 文件背衬 + 私有 COW 的执行式探针（与 13:30 崩溃点同型）。
//   · 建临时文件（NSTemporaryDirectory）→ ftruncate 一页 → mmap(PROT_READ|PROT_WRITE, MAP_PRIVATE)
//     ⇒ 得到"mapped file … SM=COW"那一型（当前 rw-，maxprot 由 vnode 决定）
//   · 写一条真指令 → sys_icache_invalidate → mprotect(RX) → **真的调用它**（同一套 SIGBUS/SIGSEGV 安全网）
//   · 任何一步做不下去（建文件/mmap 失败）⇒ 返回 Inconclusive，调用方按"不可用"处理（保守）
AMEJITExecProbeResult AMEDeviceProbeFileBackedJITExecCapability(void) {
    size_t pg = (size_t)getpagesize();
    NSString *dir = NSTemporaryDirectory();
    if (dir.length == 0) dir = @"/tmp";
    NSString *path = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ame_jit_exec2_probe_%d.bin", (int)getpid()]];
    const char *cpath = path.fileSystemRepresentation;

    int fd = open(cpath, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        NSLog(@"[JIT-EXEC-2] file-probe: open(%@) failed: %s -- inconclusive (treated as NOT executable)",
              path, strerror(errno));
        return AMEJITExecProbeInconclusive;
    }
    if (ftruncate(fd, (off_t)pg) != 0) {
        NSLog(@"[JIT-EXEC-2] file-probe: ftruncate(%zu) failed: %s -- inconclusive", pg, strerror(errno));
        close(fd);
        unlink(cpath);
        return AMEJITExecProbeInconclusive;
    }

    void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) {
        NSLog(@"[JIT-EXEC-2] file-probe: mmap(MAP_PRIVATE file) failed: %s -- inconclusive", strerror(errno));
        close(fd);
        unlink(cpath);
        return AMEJITExecProbeInconclusive;
    }

    memcpy(p, kAmeJITProbeCode, sizeof(kAmeJITProbeCode));
    sys_icache_invalidate(p, pg);

    if (mprotect(p, pg, PROT_READ | PROT_EXEC) != 0) {
        int e = errno;
        NSLog(@"[JIT-EXEC-2] file-probe: mprotect(RX) DENIED on a file-backed private COW page: %s "
              @"-- this is the mapping kind the 13:30 SIGBUS used; an anonymous-page success does NOT cover it",
              strerror(e));
        munmap(p, pg);
        close(fd);
        unlink(cpath);
        return AMEJITExecProbeMprotectFailed;
    }

    // 与匿名探针同一套安全网（保存/恢复原处置，绝不长期占用 SIGBUS/SIGSEGV）。
    struct sigaction sa, oldBus, oldSegv;
    memset(&sa, 0, sizeof(sa));
    memset(&oldBus, 0, sizeof(oldBus));
    memset(&oldSegv, 0, sizeof(oldSegv));
    sa.sa_handler = ameJITExecProbeSignalHandler;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &oldBus);
    sigaction(SIGSEGV, &sa, &oldSegv);

    gAmeJITExecProbeArmed = 1;
    volatile int ameGot = -1;
    volatile AMEJITExecProbeResult ameRes = AMEJITExecProbeExecFaulted;
    if (sigsetjmp(gAmeJITExecProbeEnv, 1) == 0) {
        int (*volatile ameFn)(void) = (int (*)(void))p;
        ameGot = ameFn();
        ameRes = (ameGot == AME_JIT_PROBE_RETVAL) ? AMEJITExecProbeExecOK
                                                 : AMEJITExecProbeExecFaulted;
    } else {
        ameRes = AMEJITExecProbeExecFaulted;
    }
    gAmeJITExecProbeArmed = 0;

    sigaction(SIGBUS, &oldBus, NULL);
    sigaction(SIGSEGV, &oldSegv, NULL);
    munmap(p, pg);
    close(fd);
    unlink(cpath);

    if (ameRes == AMEJITExecProbeExecOK) {
        NSLog(@"[JIT-EXEC-2] file-probe: file-backed private COW page EXECUTED OK -- this mapping kind "
              @"(the 13:30 crash kind) is usable on this device");
    } else {
        NSLog(@"[JIT-EXEC-2] file-probe: mprotect(RX) returned 0 BUT executing the file-backed page faulted "
              @"(ret=%d) -- same failure shape as the 13:30 SIGBUS (mapped file r--/rw- SM=COW); an "
              @"anonymous-page success cannot stand in for this", ameGot);
    }
    return (AMEJITExecProbeResult)ameRes;
}

// 逃生开关：允许"明知页不可执行也放行"（默认关；真机 A/B 或临时解围用）。
static BOOL AMEJITExec2AllowNoExec(void) {
    const char *env = getenv("AMETHYST_JIT_EXEC2_ALLOW_NOEXEC");
    if (env != NULL && env[0] == '1') return YES;
    return getPrefBool(@"debug.jit_exec2_allow_noexec");
}

// ★ [JIT-EXEC-2] 启动前权威闸门：只在"两型探针都失败 + 无活调试器 + 非 mirror 路径"时出手。
//   这个组合等价于"此刻这台机器上没有任何东西能让运行时生成的代码可执行"，
//   继续 JLI_Launch 必在首帧 JIT 代码取指上 SIGBUS（13:30 形态）⇒ 中止比崩溃好。
NSString *AMEJITExec2LaunchBlockReason(void) {
    if (AMEJITPathForceMode() == AMEJITPathForceNative) return nil;   // 显式 opt-in 旧行为
    if (AMEJITExec2AllowNoExec()) return nil;                         // 逃生开关
    if (DeviceNeedsDebugJITMapping()) return nil;                     // Universal/mirror 路径交给既有 brk 自检

    // ★ [JIT-STATUS] 非镜像路径：JVM 直接执行自产代码 ⇒ 只认"真跑过的执行式探针"。
    //   不再因 "有活调试器在岗" 就放行：巨魔 TrollStore 自建 CS_DEBUGGED / 粘滞标志会
    //   假阳性（探针全灭却"看起来 attach 了"）⇒ 一启动就在 JIT 取指 SIGBUS 闪退。
    //   （显式 opt-in：AMETHYST_JIT_PATH=native / AMETHYST_JIT_EXEC2_ALLOW_NOEXEC=1。）
    AMEJITExecProbeResult rAnon = AMEDeviceProbeJITExecCapability();
    AMEJITExecProbeResult rFile = AMEDeviceProbeFileBackedJITExecCapability();
    // 只有"确定的失败"才算失败：Inconclusive(4) = 探针本身跑不起来（临时目录不可写等），
    // 不能据此拦人（宁可少拦一次，也别把能跑的机器挡在门外；拦的重任一型出现确定失败就够）。
    BOOL anonBad = (rAnon == AMEJITExecProbeMprotectFailed || rAnon == AMEJITExecProbeExecFaulted);
    BOOL fileBad = (rFile == AMEJITExecProbeMprotectFailed || rFile == AMEJITExecProbeExecFaulted);
    if (!anonBad && !fileBad) return nil;

    return [NSString stringWithFormat:
            @"exec-probe FAILED (anon=%ld file-backed=%ld; 1=exec-OK 2=mprotect-denied 3=faulted "
            @"4=inconclusive), no live JIT debugger (ppid=%d traced=%d exn=%d), jitFlags=0x%X, %@ "
            @"-- runtime-generated code cannot be made executable right now; launching would SIGBUS "
            @"inside JIT code (the 13:30 new-build crash). Fix JIT for this app (debugger attach / JIT "
            @"enabler) or set AMETHYST_JIT_PATH=debugger.",
            (long)rAnon, (long)rFile, getppid(), JIT26DebuggerAttachedViaPtrace(),
            JIT26DebuggerViaExceptionPorts(), (unsigned)DeviceGetJITFlags(NO),
            AMEJITCapabilitySummary()];
}

BOOL AMEJailbreakNativeJITReady(void) {
    // ① 逃生开关优先：force=native 直接放行（信任用户/二分），force=debugger|external
    //    一律判否 ⇒ 落回调试器/使能器链路。
    AMEJITPathForce force = AMEJITPathForceMode();
    if (force == AMEJITPathForceNative) {
        NSLog(@"[JIT-CACHE] native JIT FORCED by escape hatch (AMETHYST_JIT_PATH=native / debug.jit_path) "
              @"-- skipping exec-probe, no debugger/enabler will be requested (env=%@)",
              AMEJailbreakEnvSummary());
        return YES;
    }
    if (force == AMEJITPathForceDebugger || force == AMEJITPathForceExternal) {
        NSLog(@"[JIT-CACHE] native JIT suppressed by escape hatch (force=%ld) -- taking the "
              @"debugger/enabler path (env=%@)", (long)force, AMEJailbreakEnvSummary());
        return NO;
    }

    // ★ [JIT-EXEC-2] ①.5 硬准入条件（**先于探针**，与 JVM 真正需要的能力对齐）：
    //   本机组合 flags==0（非 iOS26 ⇒ 无 MirrorMappedCodeCache/调试器代映射那套）+ A12 无 TXM
    //   + 无真 JIT entitlement ⇒ 本平台**不存在**任何 Apple 支持的原生 JIT 机制，页不可能可执行。
    //   实测（13:30 新包）：带着 CS_DEBUGGED 也照样在 JIT 取指上 SIGBUS ⇒ 不再允许
    //   "探针过了（或干脆没探）就放行 native"；直接判否，落回调试器/使能器链路。
    if (!AMEDeviceHasRealJITEntitlement() &&
        !DeviceHasJITFlags(JIT_FLAG_IS_IOS_26) &&
        !DeviceHasJITFlags(JIT_FLAG_HAS_TXM)) {
        NSLog(@"[JIT-EXEC-2] native JIT DISABLED: reason=no-supported-native-jit-mechanism "
              @"(no dynamic-codesigning / allow-jit entitlement, not iOS26+ (no MirrorMappedCodeCache "
              @"debugger-mapped RX), no TXM) jitFlags=0x%X %@ env=%@ -- native path would SIGBUS inside "
              @"JIT code; use the debugger/enabler path (debug.jit_path=debugger)",
              (unsigned)DeviceGetJITFlags(NO), AMEJITCapabilitySummary(), AMEJailbreakEnvSummary());
        return NO;
    }

    // ② 真·执行力判据（缓存）。DeviceCanCreateRXMap 只作【诊断对照】打日志：
    //    两者结果不一致时（canRX=1 / exec=0）正是 db76cfb 的假阳性形态，日志里要能一眼看到。
    //    ★ [JIT-EXEC-2] 现在要【两型 mapping 都过】：匿名私有页 + 文件背衬私有 COW 页
    //    （后者是 13:30 崩溃点 `mapped file … r--/rw- SM=COW` 那一型；单匿名页通过不代表它）。
    os_unfair_lock_lock(&gAmeJITExecProbeLock);
    if (gAmeJBNativeJITProbe == 0) {
        BOOL canRX = DeviceCanCreateRXMap();
        AMEJITExecProbeResult rAnon = AMEDeviceProbeJITExecCapability();
        AMEJITExecProbeResult rFile = AMEDeviceProbeFileBackedJITExecCapability();
        BOOL ok = (rAnon == AMEJITExecProbeExecOK) && (rFile == AMEJITExecProbeExecOK);
        gAmeJBNativeJITProbe = ok ? 1 : -1;
        gAmeJBNativeJITReady = ok;
        if (ok) {
            NSLog(@"[JIT-EXEC-2] native JIT executable (env=%@): BOTH mapping kinds really ran "
                  @"(anon=exec-OK file-backed=exec-OK; mprotectOnlyProbe=%d) -- no debugger/brk needed",
                  AMEJailbreakEnvSummary(), canRX);
        } else {
            NSLog(@"[JIT-EXEC-2] native JIT NOT usable (env=%@): exec-probe anon=%ld file-backed=%ld "
                  @"(1=exec-OK 2=mprotect-denied 3=exec-FAULTED 4=inconclusive) "
                  @"mprotectOnlyProbe(canCreateRXMap)=%d %@ -- FALLING BACK to the debugger/enabler path; "
                  @"launching on the native path here would SIGBUS inside JIT code",
                  AMEJailbreakEnvSummary(), (long)rAnon, (long)rFile, canRX, AMEJITCapabilitySummary());
        }
    }
    BOOL ready = gAmeJBNativeJITReady;
    os_unfair_lock_unlock(&gAmeJITExecProbeLock);
    return ready;
}

static BOOL DeviceLikelyHasTXMFromChipID(void) {
    NSUInteger (*MGGetSInt64Answer)(NSString *) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
    if (MGGetSInt64Answer == NULL) {
        // Failing closed would select the legacy mapping path on the exact
        // systems where Apple made Preboot unreadable. Prefer the TXM-safe
        // path on recent systems when MobileGestalt is unavailable.
        if (@available(iOS 19.0, *)) return YES;
        return NO;
    }

    switch (MGGetSInt64Answer(@"ChipID")) {
        case 0x8020: // A12
        case 0x8027: // A12X/Z
            return NO;
        case 0x8030: // A13
        case 0x8101: // A14
        case 0x8103: // M1
            if (@available(iOS 27.0, *)) return YES;
            return NO;
        default:
            if (@available(iOS 19.0, *)) return YES;
            return NO;
    }
}

BOOL DeviceHasTXM(void) {
    // Try the direct active-Preboot path before falling back to legacy
    // directory enumeration.
    static const char *modernTXMPath =
        "/System/Volumes/Preboot/boot/usr/standalone/firmware/FUD/"
        "Ap,TrustedExecutionMonitor.img4";
    if (access(modernTXMPath, F_OK) == 0) return YES;

    DIR *d = opendir("/private/preboot");
    if (!d) {
        // /private/preboot is no longer readable on iOS 26.6 and iOS 27.
        // Fall back to a conservative hardware/OS heuristic.
        return DeviceLikelyHasTXMFromChipID();
    }

    struct dirent *dir;
    BOOL hasTXM = NO;
    while ((dir = readdir(d)) != NULL) {
        if(strlen(dir->d_name) == 96) {
            char txmPath[PATH_MAX] = {0};
            int length = snprintf(txmPath, sizeof(txmPath),
                "/private/preboot/%s/usr/standalone/firmware/FUD/"
                "Ap,TrustedExecutionMonitor.img4", dir->d_name);
            if (length > 0 && (size_t)length < sizeof(txmPath) &&
                    access(txmPath, F_OK) == 0) {
                hasTXM = YES;
                break;
            }
        }
    }
    closedir(d);
    return hasTXM;
}

JITFlags DeviceGetJITFlags(BOOL refresh) {
    static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
    static JITFlags cachedFlags = 0;
    static BOOL cacheInitialized = NO;

    os_unfair_lock_lock(&cacheLock);
    if (refresh || !cacheInitialized) {
        JITFlags flags = 0;
        const char *s = getenv("JIT_FLAGS");
        if (s) {
            if (s[0] == '0' && tolower(s[1]) == 'b') {
                flags = strtoul(s + 2, NULL, 2);
            } else {
                flags = strtoul(s, NULL, 0);
            }
            NSLog(@"[JIT] Using overridden JIT flags: 0x%X", flags);
        } else {
            if (@available(iOS 26.0, *)) {
                flags |= JIT_FLAG_IS_IOS_26;
                if (!DeviceCanCreateRXMap()) {
                    flags |= JIT_FLAG_FORCE_MIRRORED;
                }
            }
            if (DeviceHasTXM()) {
                flags |= JIT_FLAG_HAS_TXM;
            }
        }

        cachedFlags = flags;
        cacheInitialized = YES;
    }
    JITFlags result = cachedFlags;
    os_unfair_lock_unlock(&cacheLock);
    return result;
}

BOOL DeviceHasJITFlags(JITFlags flags) {
    return (DeviceGetJITFlags(NO) & flags) == flags;
}

BOOL DeviceNeedsDebugJITMapping(void) {
    // This is a capability decision, not a TXM firmware-detection decision.
    // MirrorMappedCodeCache now means that the Universal JIT script has been
    // installed and HotSpot may request its RX mapping from the debugger.
    return DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED);
}

void dismissModalViewController(UIViewController *viewController) {
    [viewController.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - ★ [VER-ISOLATE] 完全版本隔离：实例隔离根目录

// 当前实例名（general.game_directory）。直接读全局 v2 plist，不依赖 prefs 系统，
// 因为 main.m 的日志重定向早于 loadPreferences()。读不到时回退 v1 plist 顶层键，
// 再回退 @"default"（与 init_setupMultiDir 的缺省一致）。
static NSString *ameVIInstanceName(void) {
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') return nil;
    NSString *inst = nil;

    NSString *plist = [@(home) stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
    NSDictionary *pref = [NSDictionary dictionaryWithContentsOfFile:plist];
    id v = pref[@"general"][@"game_directory"];
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) {
        inst = v;
    } else {
        // 旧版布局回退（PLPreferences 尚未迁移/保存时的极早期）
        NSString *oldPlist = [@(home) stringByAppendingPathComponent:@"launcher_preferences.plist"];
        NSDictionary *oldPref = [NSDictionary dictionaryWithContentsOfFile:oldPlist];
        id ov = oldPref[@"game_directory"];
        if ([ov isKindOfClass:NSString.class] && [(NSString *)ov length] > 0) inst = ov;
    }
    if (inst.length == 0) inst = @"default";
    // 防目录穿越：实例名只取最后一段
    return inst.lastPathComponent;
}

NSString *ameVIInstanceRoot(void) {
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') return nil;
    NSString *inst = ameVIInstanceName();
    if (inst.length == 0) return nil;
    NSString *root = [@(home) stringByAppendingPathComponent:@"instances"];
    return [root stringByAppendingPathComponent:inst];
}

NSString *ameVIInstanceSubdir(NSString *leaf) {
    if (leaf.length == 0) return nil;
    NSString *root = ameVIInstanceRoot();
    if (root.length == 0) return nil;
    NSString *dir = [root stringByAppendingPathComponent:leaf];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// 每实例日志路径：<root>/logs/latestlog.txt。实例根不可得时回退旧共享
// <POJAV_HOME>/latestlog.txt，保证永不因隔离改动而拿不到路径。
NSString *ameVILatestLogPath(void) {
    NSString *dir = ameVIInstanceSubdir(@"logs");
    if (dir.length > 0) return [dir stringByAppendingPathComponent:@"latestlog.txt"];
    const char *home = getenv("POJAV_HOME");
    return home ? [@(home) stringByAppendingPathComponent:@"latestlog.txt"] : nil;
}

NSString *ameVILatestLogRotatedPath(void) {
    NSString *dir = ameVIInstanceSubdir(@"logs");
    if (dir.length > 0) return [dir stringByAppendingPathComponent:@"latestlog.old.txt"];
    const char *home = getenv("POJAV_HOME");
    return home ? [@(home) stringByAppendingPathComponent:@"latestlog.old.txt"] : nil;
}

#pragma mark - ★ [LOG-FIX] 日志隔离兼容层（硬链接，保证 POJAV_HOME 下是普通文件）

BOOL ameVIPathIsSymlink(NSString *path) {
    if (path.length == 0) return NO;
    // 关键：attributesOfItemAtPath: 【不跟随】符号链接 —— 对 symlink 报
    // NSFileTypeSymbolicLink（size=目标串长度）。这正是旧版把 symlink 当
    // 「透明兼容」时被读方看破的地方，这里用它来识别并清理旧残留。
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [NSFileTypeSymbolicLink isEqualToString:attrs[NSFileType]];
}

BOOL ameVIHardLinkLog(NSString *srcPath, NSString *dstPath) {
    if (srcPath.length == 0 || dstPath.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:srcPath]) return NO;
    // 先删目标这一个名字：无论它是旧版残留的符号链接，还是旧共享日志普通文件，
    // 都只删名字本身 —— 若目标已是本真身的硬链接，删它也不会动到 inode 与实例内那份。
    [fm removeItemAtPath:dstPath error:nil];
    NSError *err = nil;
    if ([fm linkItemAtPath:srcPath toPath:dstPath error:&err]) return YES;
    NSLog(@"[LOG-FIX] hardlink failed: %@ -> %@ (%@)",
          srcPath, dstPath, err.localizedDescription);
    return NO;
}

#pragma mark - ★ [VER-ISOLATE-PCL] 版本隔离（对齐 PCL-CE「实例隔离」）

// 版本隔离全局默认键（对应 PCL 的 LaunchArgumentIndieV2「默认实例隔离」）。
static NSString *const kAmePCLVersionIsolationPref = @"general.version_isolation";
// 一次性迁移哨兵（对应 PCL 旧值 VersionArgumentIndie → V2 的一次性迁移）。
static NSString *const kAmePCLVersionIsolationMigrated = @"internal.version_isolation_migrated";

// 版本 id 是否「具体可隔离」：
//   排除 latest-release / latest-snapshot 之类的别名与 path 片段，并要求实例的
//   versions/<id>/ 下确有版本定义（目录或 <id>.json）。核验不过一律回退共享（"."），
//   保证「隔离改动永不阻断启动」——最坏情况只是没有隔离，而不是找不到游戏目录。
static BOOL amePCLVersionIdIsConcrete(NSString *vid) {
    if (vid.length == 0) return NO;
    if ([vid isEqualToString:@"(default)"]) return NO;
    if ([vid hasPrefix:@"latest-"]) return NO;           // latest-release / latest-snapshot
    if ([vid containsString:@"/"] || [vid containsString:@"\\"]) return NO;
    NSString *root = ameVIInstanceRoot();
    if (root.length == 0) return YES;                    // 无法核验时按可隔离处理
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[root stringByAppendingPathComponent:@"versions"]
                     stringByAppendingPathComponent:vid];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return YES;
    NSString *json = [dir stringByAppendingPathComponent:
                      [vid stringByAppendingPathExtension:@"json"]];
    if ([fm fileExistsAtPath:json]) return YES;
    return NO;
}

// 解析 profile 的版本 id：优先用调用方给的"实际启动版本"（launchTarget[@“id”]），
// 其次 profile.lastVersionId。都不可隔离则返回 nil。
static NSString *amePCLProfileVersionId(NSDictionary *prof, NSString *concreteVersionId) {
    if (amePCLVersionIdIsConcrete(concreteVersionId)) return concreteVersionId;
    id vid = prof[@"lastVersionId"];
    if ([vid isKindOfClass:NSString.class] && amePCLVersionIdIsConcrete((NSString *)vid)) {
        return (NSString *)vid;
    }
    return nil;
}

// 自动判定（对应 PCL ShouldBeIndie 第 2 步）：<实例根>/versions/<id>/ 下已有
// mods（含非隐藏文件）或 saves（含非隐藏目录）⇒ 视为已隔离。
static BOOL amePCLVersionFolderHasUserData(NSString *versionId) {
    if (versionId.length == 0) return NO;
    // ★ [VI-POLISH] 与 ameVISniffVersionFolder 同源（同一条规则，UI 说明与判定不会漂移）
    NSDictionary *s = ameVISniffVersionFolder(versionId);
    return [s[@"hasMods"] boolValue] || [s[@"hasSaves"] boolValue];
}

BOOL amePCLVersionIsolationForProfile(NSDictionary *prof, NSString *concreteVersionId) {
    if (![prof isKindOfClass:NSDictionary.class]) prof = nil;

    // 1) profile 显式值（PCL: VersionArgumentIndieV2）
    id explicit = prof[@"versionIsolation"];
    if ([explicit isKindOfClass:NSNumber.class]) return [(NSNumber *)explicit boolValue];
    if ([explicit isKindOfClass:NSString.class] && [(NSString *)explicit length] > 0) {
        return [(NSString *)explicit boolValue];
    }

    // 2) 自动判定（PCL: ShouldBeIndie 的 mods/saves 启发式）
    NSString *vid = amePCLProfileVersionId(prof, concreteVersionId);
    if (vid.length > 0 && amePCLVersionFolderHasUserData(vid)) {
        NSLog(@"★ [VER-ISOLATE-PCL] 开启版本隔离（自动）：versions/%@ 下已有 mods/saves", vid);
        return YES;
    }

    // 3) 全局默认（PCL: LaunchArgumentIndieV2 默认实例隔离策略）
    return getPrefBool(kAmePCLVersionIsolationPref);
}

NSString *amePCLVersionGameDirSubpath(NSDictionary *prof, NSString *concreteVersionId) {
    if (![prof isKindOfClass:NSDictionary.class]) prof = nil;

    // 显式 gameDir（非 "."）永远优先：保持既有"自定义游戏目录"语义不受隔离开关影响。
    id gd = prof[@"gameDir"];
    if ([gd isKindOfClass:NSString.class] && [(NSString *)gd length] > 0 &&
        ![(NSString *)gd isEqualToString:@"."]) {
        return (NSString *)gd;
    }

    if (!amePCLVersionIsolationForProfile(prof, concreteVersionId)) return @".";

    NSString *vid = amePCLProfileVersionId(prof, concreteVersionId);
    if (vid.length == 0) {
        NSLog(@"★ [VER-ISOLATE-PCL] 版本 id 不可确定，本版本回退共享目录（不隔离）");
        return @".";
    }
    return [NSString stringWithFormat:@"versions/%@", vid];
}

NSString *amePCLVersionGameDirAbsolute(NSDictionary *prof, NSString *concreteVersionId) {
    NSString *sub = amePCLVersionGameDirSubpath(prof, concreteVersionId);
    const char *env = getenv("POJAV_GAME_DIR");
    NSString *base = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
    if (sub.length == 0 || [sub isEqualToString:@"."]) return base;
    if ([sub isAbsolutePath]) return sub;
    NSString *clean = [sub hasPrefix:@"./"] ? [sub substringFromIndex:2] : sub;
    return [[base stringByAppendingPathComponent:clean] stringByStandardizingPath];
}

void amePCLMigrateVersionIsolationOnce(void) {
    if ([getPrefObject(kAmePCLVersionIsolationMigrated) boolValue]) return;  // 幂等：只跑一次

    // 迁移在 main.m 的 init_setupMultiDir() 之后调用，POJAV_GAME_DIR 已就绪；
    // 这里仍走 ameVIInstanceRoot()（直读全局 plist），不依赖该环境变量。
    NSString *root = ameVIInstanceRoot();
    if (root.length == 0) return;
    NSString *profPath = [root stringByAppendingPathComponent:@"launcher_profiles.json"];
    NSMutableDictionary *pd = parseJSONFromFile(profPath);
    NSMutableDictionary *profiles = pd[@"profiles"];

    if ([profiles isKindOfClass:NSMutableDictionary.class]) {
        BOOL changed = NO;
        for (NSString *name in profiles.allKeys) {
            NSMutableDictionary *prof = profiles[name];
            if (![prof isKindOfClass:NSMutableDictionary.class]) continue;
            if (prof[@"versionIsolation"]) continue;   // 已有显式值，绝不覆盖用户选择

            BOOL alreadyIsolated = NO;
            id gd = prof[@"gameDir"];
            if ([gd isKindOfClass:NSString.class] && [(NSString *)gd hasPrefix:@"versions/"]) {
                alreadyIsolated = YES;                 // 升级前手工把 gameDir 指到 versions/*
            }
            if (!alreadyIsolated) {
                id vid = prof[@"lastVersionId"];
                if ([vid isKindOfClass:NSString.class] && amePCLVersionFolderHasUserData((NSString *)vid)) {
                    alreadyIsolated = YES;             // 该版本目录下已有 mods/saves
                }
            }
            if (alreadyIsolated) {
                prof[@"versionIsolation"] = @"1";      // 显式落值 ⇒ 设置页可见、可回退
                changed = YES;
                NSLog(@"★ [VER-ISOLATE-PCL] 迁移：profile「%@」已存在版本隔离数据 ⇒ 显式置为开启", name);
            }
        }
        if (changed) saveJSONToFile(pd, profPath);
    }

    setPrefObject(kAmePCLVersionIsolationMigrated, @YES);
    NSLog(@"★ [VER-ISOLATE-PCL] 版本隔离一次性迁移完成（哨兵 %@）", kAmePCLVersionIsolationMigrated);
}

// ★ [VER-ISOLATE-MIGRATE] ====================================================
// 共享游戏根绝对路径解析（迁移的"源根"）。只解析路径，不做任何搬动。
// POJAV_GAME_DIR 由 init_setupMultiDir() 设置（= POJAV_HOME/instances/<实例>），
// 与 ameVIInstanceRoot() 同源；环境变量不可得时回退后者，绝不返回空。
NSString *amePCLSharedGameDirAbsolute(void) {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env && *env) return [NSString stringWithUTF8String:env];
    NSString *root = ameVIInstanceRoot();
    if (root.length > 0) return root;
    const char *home = getenv("POJAV_HOME");
    return home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
}

// ★ [VER-ISOLATE-MIGRATE] 关隔离时该 profile 实际使用的 gameDir（迁移的"源根"）。
// 唯一真相源 = 同一 resolver：显式关掉隔离后交给 amePCLVersionGameDirAbsolute 解析，
// 自己绝不另拼一套路径（约束：目标/源都必须来自隔离 resolver）。
NSString *amePCLSharedGameDirForProfile(NSDictionary *prof, NSString *concreteVersionId) {
    if (![prof isKindOfClass:NSDictionary.class]) return amePCLSharedGameDirAbsolute();
    NSMutableDictionary *off = [prof mutableCopy];
    off[@"versionIsolation"] = @"0";       // 显式关 ⇒ resolver 第 1 步直接返回共享语义
    return amePCLVersionGameDirAbsolute(off, concreteVersionId);
}

// ★ [VI-POLISH] ==============================================================
// 建议 A（三态可见化）+ B（向导门槛）的共用底座实现。
// 只读磁盘 / 只读写设置；绝不移动、复制、删除任何文件。
// ★ [VI-FLOW] 用户修正：B 的门槛＝「用户主动选『以后不再提示』才落哨兵」，未落则每次进启动器都再弹
// （哨兵读/写点各唯一，见文件末尾；弹出时不写哨兵）。

#pragma mark - ★ [VI-POLISH] A. 隔离显式三态

AmeVIExplicitState ameVIExplicitStateForProfile(NSDictionary *prof) {
    if (![prof isKindOfClass:NSDictionary.class]) return AmeVIExplicitStateAuto;
    id raw = prof[@"versionIsolation"];
    if ([raw isKindOfClass:NSNumber.class]) {
        return [(NSNumber *)raw boolValue] ? AmeVIExplicitStateIsolated : AmeVIExplicitStateShared;
    }
    if ([raw isKindOfClass:NSString.class] && [(NSString *)raw length] > 0) {
        return [(NSString *)raw boolValue] ? AmeVIExplicitStateIsolated : AmeVIExplicitStateShared;
    }
    return AmeVIExplicitStateAuto;   // 未落键 ⇒ 自动
}

void ameVISetExplicitStateForProfile(NSMutableDictionary *prof, AmeVIExplicitState state) {
    if (![prof isKindOfClass:NSMutableDictionary.class]) return;
    switch (state) {
        case AmeVIExplicitStateIsolated:
            prof[@"versionIsolation"] = @"1";    // 显式开：resolver 第 1 步立即返回 YES
            break;
        case AmeVIExplicitStateShared:
            prof[@"versionIsolation"] = @"0";    // 显式关：resolver 第 1 步立即返回 NO
            break;
        case AmeVIExplicitStateAuto:
        default:
            [prof removeObjectForKey:@"versionIsolation"];   // 自动：回到 嗅探 → 全局默认
            // 说明：这里刻意【不】写任何默认值 —— 默认仍是「关」，与既有语义完全一致。
            break;
    }
}

#pragma mark - ★ [VI-POLISH] A. 版本目录形状嗅探（只读，供 UI 说明判定依据）

NSDictionary *ameVISniffVersionFolder(NSString *versionId) {
    NSMutableDictionary *r = [@{ @"hasMods":  @NO,
                                 @"hasSaves": @NO,
                                 @"hasAny":   @NO,
                                 @"exists":   @NO,
                                 @"path":     @"" } mutableCopy];
    if (versionId.length == 0) return r;

    NSString *root = ameVIInstanceRoot();
    if (root.length == 0) return r;
    NSString *vdir = [[root stringByAppendingPathComponent:@"versions"]
                      stringByAppendingPathComponent:versionId];
    r[@"path"] = vdir;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:vdir isDirectory:&isDir] && isDir) r[@"exists"] = @YES;

    // 与 resolver 的自动判定逐字同源：非隐藏条目即算「有内容」（mods 是文件、saves 是目录，
    // 这里都按「目录下有没有非隐藏条目」判，与 amePCLVersionFolderHasUserData 一致）。
    BOOL hasMods = NO, hasSaves = NO;
    for (NSString *f in ([fm contentsOfDirectoryAtPath:[vdir stringByAppendingPathComponent:@"mods"] error:nil] ?: @[])) {
        if (![f hasPrefix:@"."]) { hasMods = YES; break; }
    }
    for (NSString *f in ([fm contentsOfDirectoryAtPath:[vdir stringByAppendingPathComponent:@"saves"] error:nil] ?: @[])) {
        if (![f hasPrefix:@"."]) { hasSaves = YES; break; }
    }
    r[@"hasMods"]  = @(hasMods);
    r[@"hasSaves"] = @(hasSaves);
    r[@"hasAny"]   = @(hasMods || hasSaves);
    return r;
}

BOOL ameVISniffShouldSuggestIsolation(NSString *versionId) {
    if (versionId.length == 0) return NO;
    return [ameVISniffVersionFolder(versionId)[@"hasAny"] boolValue];
}

#pragma mark - ★ [VI-FLOW] B. 向导「弹到用户主动说『以后都不弹』为止」哨兵

// ★ [VI-FLOW]（用户修正 1 + 补充）语义：
//   * 哨兵【只】在用户于向导里点「以后不再提示」时写一次（幂等）—— 弹出时【绝不】写；
//   * 未落哨兵 ⇒ ameVIWizardShouldPresent 返回 YES ⇒ 每次进启动器都会【再次出现】（不阻碍启动、可跳过）；
//   * 已落哨兵 ⇒ 不再【自动】弹；实例设置页的「版本隔离向导」手动入口直接 present，不受本哨兵约束
//     （否则用户想再看就没路了）。
//   静态证明：哨兵【读】点唯一（ameVIWizardShouldPresent，只读不写）；
//             哨兵【写】点唯一（ameVIWizardMarkDontShowAgain，仅由向导「以后不再提示」按钮调用）。
static NSString *const kAmeVIWizardOffKey = @"internal.version_isolation_wizard_off";

BOOL ameVIWizardShouldPresent(void) {
    return ![getPrefObject(kAmeVIWizardOffKey) boolValue];   // 只读：未落哨兵 ⇒ 该弹
}

void ameVIWizardMarkDontShowAgain(void) {
    setPrefObject(kAmeVIWizardOffKey, @YES);   // 幂等：重复调用结果一致；只在用户选择时写一次
    NSLog(@"★ [VI-FLOW] 向导：用户选「以后不再提示」⇒ 哨兵已落（%@），之后不再自动弹", kAmeVIWizardOffKey);
}

#pragma mark - ★ [NO-BLOCK] 启动门禁统一判定（仅渲染器类可阻断）

// 见 utils.h 说明。判据刻意只有一条：类别 == 渲染器。
// 这样「点启动 = 真的去启动」在代码层面可静态证明：任何非渲染器门禁调用
// AmeLaunchGateMayBlock 都拿到 NO，只能走「警告 + 继续启动」。
NSString *AmeLaunchGateKindName(AmeLaunchGateKind kind) {
    switch (kind) {
        case AmeLaunchGateKindRenderer: return @"renderer";
        case AmeLaunchGateKindDownload: return @"download";
        case AmeLaunchGateKindJIT:      return @"jit";
        case AmeLaunchGateKindAccount:  return @"account";
        case AmeLaunchGateKindInstance: return @"instance";
        case AmeLaunchGateKindFiles:    return @"files";
        case AmeLaunchGateKindNetwork:  return @"network";
        case AmeLaunchGateKindDisk:     return @"disk";
        case AmeLaunchGateKindUpdate:   return @"update";
        case AmeLaunchGateKindOther:    return @"other";
    }
    return @"other";
}

BOOL AmeLaunchGateMayBlock(AmeLaunchGateKind kind) {
    // ★ 唯一例外：渲染器选择/初始化。
    return (kind == AmeLaunchGateKindRenderer);
}

BOOL AmeLaunchGateNoteNonBlock(NSString *reason, AmeLaunchGateKind kind) {
    // 非渲染器门禁一律「警告 + 继续启动」；这里写一行可一眼检索的判据。
    NSLog(@"[NO-BLOCK] gate=%@ kind=%@ ⇒ 继续启动（非渲染器不阻止启动）",
          reason.length > 0 ? reason : @"(unspecified)", AmeLaunchGateKindName(kind));
    return YES;
}
