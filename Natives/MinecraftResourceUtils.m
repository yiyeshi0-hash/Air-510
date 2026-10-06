#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "PLMirrorCenter.h"
#import "UZKArchive.h"

@implementation MinecraftResourceUtils

#pragma mark - Forge/NeoForge 启动修复（参照 ZL2 Install.ForgeLike.progressIgnoreList）

/// 判断点分版本号 a 是否 >= b（仅用于 bootstraplauncher 版本判断）
+ (BOOL)pl_version:(NSString *)a isBiggerOrEqualTo:(NSString *)b {
    NSArray<NSString *> *aParts = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger aValue = i < aParts.count ? aParts[i].integerValue : 0;
        NSInteger bValue = i < bParts.count ? bParts[i].integerValue : 0;
        if (aValue != bValue) return aValue > bValue;
    }
    return YES;
}

+ (void)applyBootstrapLauncherIgnoreListFix:(NSMutableDictionary *)json {
    NSArray *libraries = json[@"libraries"];
    if (![libraries isKindOfClass:[NSArray class]]) libraries = @[];

    NSDictionary *arguments = json[@"arguments"];
    if (![arguments isKindOfClass:[NSDictionary class]]) return;
    NSArray *jvm = arguments[@"jvm"];
    if (![jvm isKindOfClass:[NSArray class]]) return;

    // -DignoreList= 只出现在 Forge/NeoForge 的 bootstrap 版本 JSON 里，
    // 找不到就没有 bootstraplauncher 的 JPMS 构建步骤，无需处理。
    NSInteger ignoreListIndex = NSNotFound;
    for (NSInteger i = (NSInteger)jvm.count - 1; i >= 0; i--) {
        id arg = jvm[(NSUInteger)i];
        if ([arg isKindOfClass:[NSString class]] && [arg hasPrefix:@"-DignoreList="]) {
            ignoreListIndex = i;
            break;
        }
    }
    if (ignoreListIndex == NSNotFound) return;

    // 识别 bootstrap 类库。groupId 不固定（cpw.mods / net.minecraftforge /
    // net.neoforged 都出现过），因此只按 artifactId 判定，不再写死 cpw.mods。
    BOOL hasBootstrap = NO;
    for (id item in libraries) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = item[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
        if (parts.count < 3) continue;
        NSString *artifactId = parts[1];
        if ([artifactId rangeOfString:@"bootstrap" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        // cpw.mods:bootstraplauncher 0.1.17 以下不支持按名忽略，跳过
        if ([parts[0] isEqualToString:@"cpw.mods"] &&
            [artifactId isEqualToString:@"bootstraplauncher"] &&
            ![self pl_version:parts[2] isBiggerOrEqualTo:@"0.1.17"]) {
            continue;
        }
        hasBootstrap = YES;
        break;
    }
    if (!hasBootstrap) {
        NSLog(@"[MCDL] 检测到 -DignoreList= 但未匹配到 bootstrap 库，仍按 Forge/NeoForge 处理");
    }

    NSMutableArray *mutableJvm = [jvm mutableCopy];
    NSString *updatedArg = mutableJvm[(NSUInteger)ignoreListIndex];

    // iOS 特有：JavaApp/Makefile 在合成 lwjgl-<ver>.jar 时把 launcher 的
    // com/apple/ios/audio/*.class 一并复制进去，导致 launcher.jar 与 lwjgl.jar
    // 两个自动模块导出同一个包。Forge/NeoForge 的 bootstrap 走 JPMS
    // (Configuration.resolveAndBind) 时直接失败：
    //   java.lang.module.ResolutionException:
    //   Modules launcher and lwjgl export package com.apple.ios.audio to module brigadier
    // 把 lwjgl 加入 ignoreList：它仍留在 classpath 上供游戏正常调用，但不再被
    // 当作模块解析，重复导出消失，模块图得以构建（幂等）。
    if ([updatedArg rangeOfString:@"lwjgl" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        updatedArg = [updatedArg stringByAppendingString:@",lwjgl"];
    } else {
        return;
    }

    mutableJvm[(NSUInteger)ignoreListIndex] = updatedArg;
    NSMutableDictionary *mutableArguments = [arguments mutableCopy];
    mutableArguments[@"jvm"] = mutableJvm;
    json[@"arguments"] = mutableArguments;
    NSLog(@"[MCDL] Forge/NeoForge: 已向 -DignoreList 追加 lwjgl（消除 launcher/lwjgl 重复导出 com.apple.ios.audio 导致的 JPMS ResolutionException）");
}

#pragma mark - OptiFine launchwrapper（参照 ZL2 Install.OptiFine.checkOFLaunchWrapper）

+ (NSArray *)optifineLaunchWrapperLibrariesWithOptiFineJarPath:(NSString *)optifineJarPath
                                                  librariesDir:(NSString *)librariesDir {
    // 1. OptiFine 1.13+：安装包内嵌 launchwrapper-of（OptiFine 自带的 launchwrapper 分支）
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:optifineJarPath error:&archiveError];
    if (archive && !archiveError) {
        NSData *versionData = [archive extractDataFromFile:@"launchwrapper-of.txt" error:nil];
        if (versionData) {
            NSString *lwVersion = [[[NSString alloc] initWithData:versionData encoding:NSUTF8StringEncoding]
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (lwVersion.length > 0 &&
                [lwVersion rangeOfString:@"^[0-9]+(\\.[0-9]+)*$" options:NSRegularExpressionSearch].location != NSNotFound) {
                NSString *fileName = [NSString stringWithFormat:@"launchwrapper-of-%@.jar", lwVersion];
                NSData *lwData = [archive extractDataFromFile:fileName error:nil];
                if (lwData.length > 0) {
                    NSString *relativePath = [NSString stringWithFormat:@"optifine/launchwrapper-of/%@/%@", lwVersion, fileName];
                    NSString *absolutePath = [librariesDir stringByAppendingPathComponent:relativePath];
                    [[NSFileManager defaultManager] createDirectoryAtPath:[absolutePath stringByDeletingLastPathComponent]
                                              withIntermediateDirectories:YES attributes:nil error:nil];
                    [lwData writeToFile:absolutePath options:NSDataWritingAtomic error:nil];
                    NSLog(@"[MCDL] OptiFine launchwrapper-of %@ -> %@", lwVersion, relativePath);
                    return @[@{
                        @"name": [NSString stringWithFormat:@"optifine:launchwrapper-of:%@", lwVersion],
                        @"downloads": @{@"artifact": @{
                            @"path": relativePath,
                            @"url": @"",
                            @"size": @(lwData.length),
                            @"sha1": @""
                        }}
                    }];
                }
            }
        }
    }

    // 2. 旧版 OptiFine（1.12 及以下）：net.minecraft:launchwrapper:1.12
    NSString *relativePath = @"net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar";
    NSString *absolutePath = [librariesDir stringByAppendingPathComponent:relativePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath]) {
        NSURL *officialURL = [NSURL URLWithString:@"https://libraries.minecraft.net/net/minecraft/launchwrapper/1.12/launchwrapper-1.12.jar"];
        NSData *data = nil;
        for (NSURL *candidate in [PLMirrorCenter candidateURLsForOriginalURL:officialURL
                                                                resourceType:PLMirrorResourceTypeModLoader]) {
            data = [self pl_synchronousDownload:candidate];
            if (data.length > 0) break;
        }
        if (data.length == 0) {
            NSLog(@"[MCDL] OptiFine launchwrapper 1.12 下载失败");
            return nil;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:[absolutePath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [data writeToFile:absolutePath options:NSDataWritingAtomic error:nil];
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:absolutePath error:nil];
    return @[@{
        @"name": @"net.minecraft:launchwrapper:1.12",
        @"downloads": @{@"artifact": @{
            @"path": relativePath,
            @"url": @"",
            @"size": attributes[NSFileSize] ?: @(0),
            @"sha1": @""
        }}
    }];
}

/// 同步下载（带移动端浏览器 UA，BMCLAPI 镜像校验 UA）
+ (NSData *)pl_synchronousDownload:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 120;
    __block NSData *result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]] &&
            ((NSHTTPURLResponse *)response).statusCode == 200) {
            result = data;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)));
    return result;
}

// Handle inheritsFrom
+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom {
    [self insertSafety:inheritsFrom from:json arr:@[
        @"assetIndex", @"assets", @"id",
        @"inheritsFrom",
        @"mainClass", @"minecraftArguments",
        @"optifineLib", @"releaseTime", @"time", @"type"
    ]];
    // 合并 arguments 而非覆盖（参照 HMCL 的合并逻辑）
    // 修复：原代码 inheritsFrom[@"arguments"] = json[@"arguments"] 会无条件用子版本 arguments
    //   覆盖父版本，当子版本没有 arguments 字段时会把父版本的 arguments 清空为 nil，
    //   导致父版本的 arguments.jvm（可能包含 26.x 新增强制 --add-opens/--add-exports）被完全忽略，
    //   引发反射访问失败崩溃。
    if (json[@"arguments"]) {
        NSMutableDictionary *mergedArgs = [NSMutableDictionary dictionary];
        // 先保留父版本的 arguments
        if (inheritsFrom[@"arguments"]) {
            [mergedArgs addEntriesFromDictionary:inheritsFrom[@"arguments"]];
        }
        // 再用子版本的 arguments 覆盖（但保留父版本中子版本没有的键）
        if ([json[@"arguments"] isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in json[@"arguments"]) {
                mergedArgs[key] = json[@"arguments"][key];
            }
        }
        inheritsFrom[@"arguments"] = mergedArgs;
    }

    for (NSMutableDictionary *lib in json[@"libraries"]) {
        // ★ [DEMINE] 原为 name 直接 rangeOfString:@":" 取 location 再 substringToIndex：
        //   库名不含冒号(非标准 Maven 坐标 / 异常 version json)时 location==NSNotFound
        //   ⇒ substringToIndex 越界 NSRangeException 崩 App。缺冒号则跳过该库。
        NSString *libRawName = lib[@"name"];
        NSRange libColonRange = [libRawName rangeOfString:@":" options:NSBackwardsSearch];
        if (libColonRange.location == NSNotFound) continue;
        NSString *libName = [libRawName substringToIndex:libColonRange.location];
        int i;
        for (i = 0; i < [inheritsFrom[@"libraries"] count]; i++) {
            NSMutableDictionary *libAdded = inheritsFrom[@"libraries"][i];
            // ★ [DEMINE] 同上：libAdded 名字无冒号时 substringToIndex 越界崩 App。
            NSString *libAddedRawName = libAdded[@"name"];
            NSRange libAddedColonRange = [libAddedRawName rangeOfString:@":" options:NSBackwardsSearch];
            if (libAddedColonRange.location == NSNotFound) continue;
            NSString *libAddedName = [libAddedRawName substringToIndex:libAddedColonRange.location];

            if ([libAdded[@"name"] hasPrefix:libName]) {
                inheritsFrom[@"libraries"][i] = lib;
                i = -1;
                break;
            }
        }

        if (i != -1) {
            [inheritsFrom[@"libraries"] addObject:lib];
        }
    }

    //inheritsFrom[@"inheritsFrom"] = nil;
}

+ (void)insertSafety:(NSMutableDictionary *)targetVer from:(NSDictionary *)fromVer arr:(NSArray *)arr {
    for (NSString *key in arr) {
        if (([fromVer[key] isKindOfClass:NSString.class] && [fromVer[key] length] > 0) || targetVer[key] == nil) {
            targetVer[key] = fromVer[key];
        } else {
            // ★ [PREDL] 该键未从子版本继承到父版本时打印，便于排查“合并后 metadata 缺字段”
            //   导致的意外启动期补件（属正常安全回退，不是错误）。
            NSLog(@"[MCDL] insertSafety: how to insert %@?", key);
        }
    }
}

+ (NSInteger)numberOfArgsToSkipForArg:(NSString *)arg {
    if (![arg isKindOfClass:NSString.class]) {
        // Skip non-string arg
        return 1;
    } else if ([arg hasPrefix:@"-cp"]) {
        // Skip "-cp <classpath>"
        return 2;
    } else if ([arg hasPrefix:@"-Djava.library.path="]) {
        return 1;
    } else if ([arg hasPrefix:@"-XX:HeapDumpPath"]) {
        return 1;
    } else if ([arg hasPrefix:@"-XstartOnFirstThread"]) {
        // 已由启动器硬编码设置，跳过避免重复
        return 1;
    } else if ([arg hasPrefix:@"-Djava.system.class.loader="]) {
        // 已由启动器硬编码设置
        return 1;
    } else {
        return 0;
    }
}

// 评估 Mojang 版本 JSON 中的 OS 规则。
// iOS 视作 osx（Apple 平台），因为 JVM 在 iOS 上以 macOS 兼容方式运行。
+ (BOOL)evaluateRules:(NSArray *)rules {
    if (rules.count == 0) return YES;
    BOOL allowed = NO;
    for (NSDictionary *rule in rules) {
        NSString *action = rule[@"action"];
        NSDictionary *os = rule[@"os"];
        NSDictionary *features = rule[@"features"];
        // 带 features 的规则（如 is_demo_user）本启动器不支持，跳过
        if (features.count > 0) {
            allowed = NO;
            continue;
        }
        BOOL match = YES;
        if (os[@"name"]) {
            // iOS 上 JVM 视为 osx 环境
            match = [os[@"name"] isEqualToString:@"osx"];
        }
        if (match) {
            allowed = [action isEqualToString:@"allow"];
        }
    }
    return allowed;
}

// 将规则化的 JVM 参数项展开为字符串数组
+ (NSArray<NSString *> *)flattenJvmArg:(id)arg {
    if ([arg isKindOfClass:NSString.class]) {
        return @[arg];
    } else if ([arg isKindOfClass:NSDictionary.class]) {
        if (![self evaluateRules:arg[@"rules"]]) return @[];
        id value = arg[@"value"];
        if ([value isKindOfClass:NSString.class]) return @[value];
        if ([value isKindOfClass:NSArray.class]) return value;
    }
    return @[];
}

#pragma mark - ★ [MISS] 启动所需文件清单（下载器 ⇄ 启动准入门禁 共用唯一真源）

+ (NSDictionary *)resolvedLibraryArtifactForLaunch:(NSDictionary *)library {
    if (![library isKindOfClass:[NSDictionary class]]) return nil;

    // ① skip：tweakVersionJson 已按「natives / downloads.classifiers / org.lwjgl / OS rules 不适用」置位。
    //   iOS 视作 osx，rules 只 allow windows/linux（或 disallow osx）的库在这里被排除 ⇒ 不再去下、
    //   也不会被启动准入门禁算作「必需件」。这就是「正常安装却报缺件」那类假阳性的堵点。
    if ([library[@"skip"] boolValue]) return nil;

    NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
    NSDictionary *artifact = library[@"downloads"][@"artifact"];

    if (artifact == nil && [name containsString:@":"]) {
        // ★ [PREDL] 与下载器同一分支：Fabric/Quilt 的 meta profile 库条目【没有 downloads 块】，
        //   只有顶层 sha1/size（如 org.ow2.asm:asm:9.7.1、net.fabricmc:sponge-mixin）。
        //   旧代码只有下载器会生成伪 artifact，门禁则跳过 ⇒ 两边清单不一致。现在两边都走本函数。
        NSLog(@"[LIB-LIST] Unknown artifact object for %@, attempting to generate one", name);
        NSArray *libParts = [name componentsSeparatedByString:@":"];
        // ★ [DEMINE] 非标准 Maven 名（<3 段）无法生成 path：下载器同样下不了 ⇒ 返回 nil
        if (libParts.count < 3) {
            NSLog(@"[LIB-LIST] skip non-3-part lib name '%@' (下载器同样无法生成 artifact，门禁不计为缺件)", name);
            return nil;
        }
        NSString *prefix = library[@"url"] == nil
            ? @"https://libraries.minecraft.net/"
            : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
        NSMutableDictionary *gen = [NSMutableDictionary dictionary];
        gen[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar",
                        [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
        gen[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, gen[@"path"]];
        // 顶层 sha1/size（缺则保持无 —— intermediary / fabric-loader 在 meta 里确实不带 sha1，
        // 只能走「仅存在性」兜底）；★ 兼容 checksums 是数组（Forge）或字符串两种写法。
        id csum = library[@"checksums"];
        id sha1 = nil;
        if ([csum isKindOfClass:[NSArray class]]) {
            sha1 = [(NSArray *)csum firstObject];
        } else if ([csum isKindOfClass:[NSString class]]) {
            sha1 = csum;
        }
        if (sha1 == nil) sha1 = library[@"sha1"];
        if (sha1 != nil) gen[@"sha1"] = sha1;
        if (library[@"size"] != nil) gen[@"size"] = library[@"size"];
        artifact = gen;
    }

    if (![artifact isKindOfClass:[NSDictionary class]]) return nil;
    id path = artifact[@"path"];
    if (![path isKindOfClass:[NSString class]] || [(NSString *)path length] == 0) return nil;
    return artifact;
}

+ (BOOL)assetObjectExcludedOnThisPlatform:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) return NO;
    // ★ 1.19+ 起不下载 macOS 窗口图标 minecraft.icns（下载器会把它删掉）。
    //   iOS 上它毫无用处 ⇒ 永不下载 ⇒ 门禁不得把它算作缺件。
    return [name isEqualToString:@"minecraft.icns"] || [name hasSuffix:@"/minecraft.icns"];
}

+ (void)tweakVersionJson:(NSMutableDictionary *)json {
    // Exclude some libraries
    for (NSMutableDictionary *library in json[@"libraries"]) {
        // ★ [NO-BLOCK][LIB-RULES] 库适用性判定必须与「真实会不会下/会不会被要求」
        //   三处同源（本函数 = 下载 filter、downloadClientLibraries、启动准入门禁
        //   missingRequiredLaunchFilesForMetadata 都只认这个 skip 标记）。
        //   旧实现只看 classifiers/natives/lwjgl 三条，**忽略 OS rules** ⇒ 在 iOS（视为
        //   osx）上本不适用的库（rules 只 allow windows/linux，或 disallow osx）：
        //     ① 不被 skip ⇒ downloadClientLibraries 照样去下（无 url 时还生成 404 URL）；
        //     ② 下不来就进 failedFiles；
        //     ③ 启动准入门禁把它算作「必需件」⇒ 判「缺件」⇒ 重试/放弃 ⇒ 拦住启动。
        //   这正是「正常安装却报缺件」的一类假阳性根因。Forge/NeoForge 直装器早已
        //   用 evaluateRules 处理（ForgeDirectInstaller.m / NeoForgeDirectInstaller.m），
        //   这里补齐到唯一真源，三处自动一致。
        id rulesObj = library[@"rules"];
        BOOL libraryApplicable = YES;
        if ([rulesObj isKindOfClass:[NSArray class]]) {
            libraryApplicable = [self evaluateRules:rulesObj];
        }

        library[@"skip"] = @(
            // Exclude platform-dependant libraries
            library[@"downloads"][@"classifiers"] != nil ||
            library[@"natives"] != nil ||
            // Exclude LWJGL libraries
            [library[@"name"] hasPrefix:@"org.lwjgl"] ||
            // ★ [NO-BLOCK][LIB-RULES] 排除 OS rules 在 iOS(osx) 上不适用的库
            !libraryApplicable
        );

        NSArray<NSString *> *libNameParts = [library[@"name"] componentsSeparatedByString:@":"];
        // ★ [DEMINE] 原为 componentsSeparatedByString:@":"][2] 直接下标：库名非标准三段
        //   (group:artifact:version) 时越界 NSRangeException 崩 App。缺段则跳过该库的版本改写。
        if (libNameParts.count < 3) {
            NSLog(@"[DEMINE] tweakVersionJson: non-3-part library name '%@' -- skipping version rewrite", library[@"name"]);
            continue;
        }
        NSString *versionStr = libNameParts[2];
        NSArray<NSString *> *version = [versionStr componentsSeparatedByString:@"."];
        if ([library[@"name"] hasPrefix:@"net.java.dev.jna:jna:"]) {
            // ★ [PREDL] 这是【故意】保留在启动/安装两处都会执行的兼容性改写（非漏项）：
            //   MC 26.3+ 要求 JNA 5.17.0，但其 darwin-aarch64 libjnidispatch 在 iOS 上会 native crash。
            //   改写只作用于【内存里的 metadata】（不落盘），安装与启动走同一条 downloadVersion:
            //   路径 ⇒ 两边看到的 JNA 版本一致，故不会造成“安装下了 5.17、启动又补 5.13”的重复下载。
            //   若日后改成只在启动时改写，就会出现“启动现补 jna-5.13.0.jar”——日志会打印下行的
            //   “Replacing JNA … / 现补 …”，据此可判。
            // 强制将 JNA 替换为 5.13.0 以保证 iOS 兼容性。
            // MC 26.3+ 要求 JNA 5.17.0，但其 darwin-aarch64 libjnidispatch 在 iOS 上
            // 加载 IOKit/CoreFoundation 后会导致 native crash/卡死（26.2 + JNA 5.13.0 正常）。
            // MC 不直接使用 JNA API（通过 oshi 间接使用），5.13.0 的 API 完全兼容。
            // PatchJNAAgent 会替换 Platform.class，与 JNA jar 版本无关。
            if (version.count >= 3 && version[0].intValue == 5 && version[1].intValue == 13 && version[2].intValue == 0) {
                continue;
            }
            NSLog(@"[MCDL] Replacing JNA %@ with 5.13.0 for iOS compatibility (required by %@)", versionStr, json[@"id"]);
            library[@"name"] = @"net.java.dev.jna:jna:5.13.0";
            library[@"downloads"][@"artifact"][@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
            // Flux 同款修复：size 仍是被替换掉的旧版的长度。完整性检查拿新包字节数
            // 对旧长度→判"下载截断"→重试 3 次放弃→每次启动重下→离线不可用。
            // 删掉它，以 SHA1 为准（hash 能抓住截断，长度只能有时抓住）。
            [library[@"downloads"][@"artifact"] removeObjectForKey:@"size"];
        } else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
            // Early versions of the ASM library get repalced with 5.0.4 because Pojav's LWJGL is compiled for
            // Java 8, which is not supported by old ASM versions. Mod loaders like Forge, which depend on this
            // library, often include lwjgl in their class transformations, which causes errors with old ASM versions.
            if(version[0].intValue >= 5) continue;
            library[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
            library[@"downloads"][@"artifact"][@"path"] = @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"e6244859997b3d4237a552669279780876228909";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            // 同上：继承的 size 属于被替换的版本，一并删掉。
            [library[@"downloads"][@"artifact"] removeObjectForKey:@"size"];
        }
    }

    // Add the client as a library
    NSMutableDictionary *client = [[NSMutableDictionary alloc] init];
    client[@"downloads"] = [[NSMutableDictionary alloc] init];
    if (json[@"downloads"][@"client"] == nil) {
        client[@"downloads"][@"artifact"] = [[NSMutableDictionary alloc] init];
        client[@"skip"] = @YES;
    } else {
        client[@"downloads"][@"artifact"] = json[@"downloads"][@"client"];
    }
    client[@"downloads"][@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%1$@/%1$@.jar", json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    [json[@"libraries"] addObject:client];

    // Forge/NeoForge：把 lwjgl 追加进 -DignoreList。
    // 必须在 jvm_processed 构建之前执行，否则改的是 arguments.jvm 而实际生效的是 jvm_processed。
    [self applyBootstrapLauncherIgnoreListFix:json];

    // 解析所有版本的官方 JVM Arguments（包括 vanilla 26.x）。
    // 原代码仅在 inheritsFrom 存在时解析，导致 vanilla 版本的 arguments.jvm
    // （可能包含 26.x 新增强制 --add-opens/--add-exports）被完全忽略，
    // 引发反射访问失败崩溃。
    if (json[@"arguments"][@"jvm"] == nil) {
        return;
    }
    json[@"arguments"][@"jvm_processed"] = [[NSMutableArray alloc] init];
    // ★ [158-FIX] 补全 MC 26.x 版本 JSON 里出现、但此前未被展开的占位符。
    //   原先只映射 classpath_separator/library_directory/version_name，导致下面这些
    //   JVM 参数以「字面量」落进 JVM：
    //     -Djna.tmpdir=${natives_directory}/jna
    //     -Dorg.lwjgl.system.SharedLibraryExtractPath=${natives_directory}/lwjgl
    //     -Dio.netty.native.workdir=${natives_directory}/netty
    //     -Dminecraft.launcher.brand=${launcher_name}
    //     -Dminecraft.launcher.version=${launcher_version}
    //   实证（issue #158 日志）：JNA 把 libjnidispatch 解包到
    //     <gamedir>/${natives_directory}/jna/jna*.tmp
    //   崩溃报告里也写着 "Launcher name: ${launcher_name}"。
    //   ${natives_directory} 映射到「可写的每实例目录」——上面三个键都是解包/临时目录，
    //   不能指向只读的 app 包；至于 -Djava.library.path=${natives_directory}/java，
    //   已被 numberOfArgsToSkipForArg 跳过，由启动器硬编码为 <app>/Frameworks。
    NSString *instanceNativesDir = [NSString stringWithFormat:@"%s/natives", getenv("POJAV_GAME_DIR")];
    NSString *launcherVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    NSDictionary *varArgMap = @{
        @"${classpath_separator}": @":",
        @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")],
        @"${version_name}": json[@"id"],
        @"${natives_directory}": instanceNativesDir,
        @"${launcher_name}": @"Amethyst",
        @"${launcher_version}": launcherVersion
    };
    int argsToSkip = 0;
    for (id rawArg in json[@"arguments"][@"jvm"]) {
        // 展开规则化参数（dict with rules），iOS 视为 osx
        NSArray<NSString *> *expanded = [self flattenJvmArg:rawArg];
        if (expanded.count == 0) continue;
        for (NSString *arg in expanded) {
            if (argsToSkip == 0) {
                argsToSkip = [self numberOfArgsToSkipForArg:arg];
            }
            if (argsToSkip == 0) {
                NSString *argStr = arg;
                for (NSString *key in varArgMap.allKeys) {
                    argStr = [argStr stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
                }
                [json[@"arguments"][@"jvm_processed"] addObject:argStr];
            } else {
                argsToSkip--;
            }
        }
    }
}

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list {
    return [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", version]].firstObject;
}

+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type {
    if (type != TYPE_RELEASE && type != TYPE_SNAPSHOT) {
        // Only support finding for releases and snapshot for now
        return nil;
    }

    if ([version isKindOfClass:NSString.class]){
        // Find in inheritsFrom
        NSDictionary *versionDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), version]);
        // ★ [DEMINE] 该 NSAssert 在发布包中仍生效：某个版本 JSON 尚未下载/损坏时
        //   versionDict 为 nil ⇒ 直接崩 App。紧随其后的 `versionDict[@"inheritsFrom"]`
        //   对 nil 返回 nil 并已优雅 return nil，故这里降级为记日志后走同一条路径。
        if (versionDict == nil) {
            NSLog(@"[DEMINE] findNearestVersion: version json missing/corrupt for '%@' -- returning nil", version);
            return nil;
        }
        if (versionDict[@"inheritsFrom"] == nil) {
            // How then?
            return nil; 
        }
        NSObject *inheritsFrom = [self findVersion:versionDict[@"inheritsFrom"] inList:remoteVersionList];
        if (type == TYPE_RELEASE) {
            return inheritsFrom;
        } else if (type == TYPE_SNAPSHOT) {
            return [self findNearestVersion:inheritsFrom expectedType:type];
        }
    }

    NSString *versionType = [version valueForKey:@"type"];
    int index = [remoteVersionList indexOfObject:(NSDictionary *)version];
    if ([versionType isEqualToString:@"release"] && type == TYPE_SNAPSHOT) {
        // Returns the (possible) latest snapshot for the version
        NSDictionary *result = remoteVersionList[index + 1];
        // Sometimes, a release is followed with another release (1.16->1.16.1), go lower in this case
        if ([result[@"type"] isEqualToString:@"release"]) {
            return [self findNearestVersion:result expectedType:type];
        }
        return result;
    } else if ([versionType isEqualToString:@"snapshot"] && type == TYPE_RELEASE) {
        while (remoteVersionList.count > abs(index)) {
            // In case the snapshot has yet attached to a release, perform a reverse find
            NSDictionary *result = remoteVersionList[abs(index)];
            // Returns the corresponding release for the snapshot, or latest release if none found
            if ([result[@"type"] isEqualToString:@"release"]) {
                return result;
            }
            // Continue to decrement, later abs() it
            index--;
        }
    }

    // No idea on handling everything else
    return nil;
}

@end
