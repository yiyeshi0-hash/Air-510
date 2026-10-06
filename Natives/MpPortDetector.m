//
//  MpPortDetector.m
//  Amethyst
//
//  ★ [MP-PORT] 实现。见 MpPortDetector.h 顶部的「为什么需要它」。
//

#import "MpPortDetector.h"
#import "LauncherPreferences.h"   // getPrefObject（只用于读 general.game_directory；Foundation 级，避免拉 utils.h/jni.h）

#include <stdlib.h>
#include <string.h>

#pragma mark - 常量

static const uint16_t kMpPortMin = 1024;
static const uint16_t kMpPortMax = 65535;
static const unsigned long long kMpPortDefaultBudget = 96ull * 1024 * 1024;   // 96MB
static const unsigned long long kMpPortIncrementalOverlap = 8 * 1024;         // 增量读回退重叠
static const NSTimeInterval kMpPortDefaultInterval = 0.5;

#pragma mark - 结果

@implementation MpPortResult
+ (instancetype)resultWithStatus:(MpPortStatus)status port:(uint16_t)port source:(NSString *)source {
    MpPortResult *r = [[MpPortResult alloc] init];
    r.status = status;
    r.port = port;
    r.sourcePath = source;
    r.fromGenericFallback = NO;
    return r;
}
- (NSString *)description {
    NSString *s = (self.status == MpPortStatusPublished) ? @"published"
               : (self.status == MpPortStatusUnpublished) ? @"unpublished" : @"unknown";
    return [NSString stringWithFormat:@"<%@ port=%u src=%@%@>", s, self.port,
            self.sourcePath.lastPathComponent ?: @"-", self.fromGenericFallback ? @" (generic)" : @""];
}
@end

#pragma mark - 小工具

/// 只读文件的 [offset, offset+length) 区间（不整份读，避免大日志拖慢）。
static NSData *MpReadRange(NSString *path, unsigned long long offset, NSUInteger length) {
    if (length == 0) return [NSData data];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) return nil;
    NSData *d = nil;
    @try {
        [fh seekToFileOffset:offset];
        d = [fh readDataOfLength:length];
    } @catch (__unused NSException *e) {
        d = nil;
    } @finally {
        [fh closeFile];
    }
    return d;
}

/// 文件大小；文件不存在 → 0。★ 先解析符号链接（attributesOfItemAtPath: 不跟随符号链接）。
static unsigned long long MpFileSize(NSString *path) {
    NSString *real = [path stringByResolvingSymlinksInPath];
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:real error:nil];
    if (a == nil) return 0;
    if (![NSFileTypeRegular isEqualToString:a[NSFileType]]) return 0;
    return [a[NSFileSize] unsignedLongLongValue];
}

/// 修改时间；解析符号链接后取（硬链接与真身同 inode ⇒ 天然一致）。
static NSTimeInterval MpFileMTime(NSString *path) {
    NSString *real = [path stringByResolvingSymlinksInPath];
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:real error:nil];
    return [a[NSFileModificationDate] timeIntervalSince1970];
}

/// UTF-8 → ISO-Latin1 兜底（编码坏字时不至于整份丢）。
static NSString *MpDataToText(NSData *data) {
    if (data.length == 0) return @"";
    NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (t == nil) t = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return t ?: @"";
}

/// 丢弃「被截断的第一行」（分片/尾读时行首可能不完整，避免把半个端口号当端口）。
static NSString *MpDropLeadingPartialLine(NSString *text, BOOL droppedAnything) {
    if (!droppedAnything || text.length == 0) return text;
    NSRange nl = [text rangeOfString:@"\n"];
    if (nl.location == NSNotFound) return text;
    return [text substringFromIndex:nl.location + 1];
}

@implementation MpPortDetector {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSString *_lastPath;
    unsigned long long _lastSize;
    MpPortResult *_lastResult;
    MpPortStatus _reportedStatus;
    uint16_t _reportedPort;
}

#pragma mark - 单例

+ (instancetype)sharedDetector {
    static MpPortDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("mpport.detect",
                    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _backwardBudgetBytes = kMpPortDefaultBudget;
        _pollInterval = kMpPortDefaultInterval;
        _reportedStatus = MpPortStatusUnknown;
        _reportedPort = 0;
    }
    return self;
}

- (BOOL)polling {
    return _timer != nil;
}

#pragma mark - 路径

+ (NSString *)launcherHome {
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) return @(home);
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

+ (NSString *)instanceNameFromPreferences {
    NSString *name = getPrefObject(@"general.game_directory");
    return name.length > 0 ? name : nil;
}

/// 目录下子目录，按 mtime 新 → 旧（用于 versions/*）
+ (NSArray<NSString *> *)subdirsSortedByMTimeDesc:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (dir.length == 0 || ![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return @[];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *n in names) {
        NSString *full = [dir stringByAppendingPathComponent:n];
        BOOL d = NO;
        if (![fm fileExistsAtPath:full isDirectory:&d] || !d) continue;
        [entries addObject:@{ @"p": full, @"m": @(MpFileMTime(full)) }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"m"] compare:a[@"m"]];
    }];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSDictionary *e in entries) [out addObject:e[@"p"]];
    return out;
}

/// 某目录下的 *.log / *.txt（按 mtime 新→旧；剔除 .old / .gz）
+ (void)appendLogNamesUnderDir:(NSString *)dir to:(NSMutableArray<NSString *> *)paths {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (dir.length == 0 || ![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *n in names) {
        NSString *low = n.lowercaseString;
        if ([low containsString:@".old"]) continue;          // ★ 上一次会话：绝不用于「当前端口」
        NSString *ext = n.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"log"] || [ext isEqualToString:@"txt"])) continue;
        NSString *full = [dir stringByAppendingPathComponent:n];
        [entries addObject:@{ @"p": full, @"m": @(MpFileMTime(full)) }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"m"] compare:a[@"m"]];
    }];
    for (NSDictionary *e in entries) {
        NSString *p = e[@"p"];
        if (![paths containsObject:p]) [paths addObject:p];
    }
}

+ (NSArray<NSString *> *)candidateLogPathsWithInstanceName:(NSString *)instanceName {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *p) {
        if (p.length == 0) return;
        if ([p.lowercaseString containsString:@".old"]) return;   // 剔除上一次会话
        if (![paths containsObject:p]) [paths addObject:p];
    };

    NSString *home = [self launcherHome];

    /* ① 启动器 stdout（<POJAV_HOME>/latestlog.txt）：当前这次 App 运行的全部
       stdout/stderr（含 MC log4j 控制台输出）。[LOG-FIX] 下它是实例日志的【硬链接】，
       所以它既是「当前实例」也是「当前会话」——最权威。 */
    if (home.length) add([home stringByAppendingPathComponent:@"latestlog.txt"]);

    /* ② POJAV_GAME_DIR：游戏启动时写入的真实 gameDir（含 PCL 隔离子路径） */
    const char *gd = getenv("POJAV_GAME_DIR");
    if (gd && strlen(gd) > 0) {
        NSString *g = @(gd);
        add([g stringByAppendingPathComponent:@"logs/latest.log"]);       // MC log4j 当前日志
        add([g stringByAppendingPathComponent:@"logs/latestlog.txt"]);
        add([g stringByAppendingPathComponent:@"latestlog.txt"]);
        [self appendLogNamesUnderDir:[g stringByAppendingPathComponent:@"logs"] to:paths];
    }

    /* ③ 实例目录（含 [VER-ISOLATE-PCL] 的 versions/<版本 id> 子路径） */
    NSString *inst = instanceName.length > 0 ? instanceName : [self instanceNameFromPreferences];
    if (home.length && inst.length) {
        NSString *instDir = [[home stringByAppendingPathComponent:@"instances"]
                             stringByAppendingPathComponent:inst];
        NSString *versRoot = [instDir stringByAppendingPathComponent:@"versions"];
        for (NSString *vd in [self subdirsSortedByMTimeDesc:versRoot]) {
            add([vd stringByAppendingPathComponent:@"logs/latest.log"]);
            add([vd stringByAppendingPathComponent:@"logs/latestlog.txt"]);
            [self appendLogNamesUnderDir:[vd stringByAppendingPathComponent:@"logs"] to:paths];
        }
        add([instDir stringByAppendingPathComponent:@"logs/latest.log"]);
        add([instDir stringByAppendingPathComponent:@"logs/latestlog.txt"]);
        [self appendLogNamesUnderDir:[instDir stringByAppendingPathComponent:@"logs"] to:paths];
    }

    /* ④ <POJAV_HOME>/logs/*（极少数构建把日志落这里） */
    if (home.length) [self appendLogNamesUnderDir:[home stringByAppendingPathComponent:@"logs"] to:paths];

    return paths;
}

#pragma mark - 解析

/// 「开放局域网」的具体形态（大小写不敏感）。26.x 真身排第一。
+ (NSArray<NSRegularExpression *> *)publishPatterns {
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *raw = @[
            // ★ 26.2 / 26.3 / 26.4 实测真身（IntegratedServer.class: "Published LAN server on port {}"）
            @"(?i)published\\s+lan\\s+server\\s+on\\s+port\\s+(\\d{2,5})",
            // 旧版本措辞
            @"(?i)started\\s+serving\\s+on\\s+port\\s+(\\d{2,5})",
            @"(?i)serving\\s+on\\s+port\\s+(\\d{2,5})",
            @"(?i)local\\s+game\\s+hosted\\s+on\\s+(?:port\\s+)?(\\d{2,5})",
            @"(?i)hosted\\s+on\\s+port\\s+(\\d{2,5})",
            @"(?i)hosting\\s+(?:the\\s+)?(?:local\\s+)?(?:game\\s+)?on\\s+port\\s+(\\d{2,5})",
            @"(?i)(?:opening|open(?:ed)?)\\s+(?:to\\s+)?lan(?:\\s+world)?\\s+on\\s+port\\s+(\\d{2,5})",
            @"(?i)已?开放\\s*局域网.*?端口\\s*(\\d{2,5})",
        ];
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *p in raw) {
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
            if (re) [arr addObject:re];
        }
        patterns = arr;
    });
    return patterns;
}

/// 「关闭局域网」的形态（识别它才能只认「当前这次」）。
+ (NSArray<NSRegularExpression *> *)unpublishPatterns {
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *raw = @[
            // ★ 26.x 真身（IntegratedServer.class: "Unpublishing integrated server (was on port {})"）
            @"(?i)unpublish(?:ing|ed)?\\s+(?:the\\s+)?integrated\\s+server",
            @"(?i)stopped\\s+serving",
            @"(?i)lan\\s+(?:world\\s+)?(?:closed|stopped)",
            @"(?i)closing\\s+(?:the\\s+)?lan",
        ];
        NSMutableArray *arr = [NSMutableArray array];
        for (NSString *p in raw) {
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
            if (re) [arr addObject:re];
        }
        patterns = arr;
    });
    return patterns;
}

/// 未知形态兜底：含关键词的行里取【最后一个】1024..65535 的数字。
+ (NSRegularExpression *)genericLinePattern {
    static NSRegularExpression *re;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)(?:serving|hosted|\\blan\\b|局域网|open\\s+to\\s+lan)" options:0 error:nil];
    });
    return re;
}

+ (uint16_t)lastPortInLine:(NSString *)line {
    static NSRegularExpression *numRe;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        numRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d{2,5})" options:0 error:nil];
    });
    __block uint16_t found = 0;
    [numRe enumerateMatchesInString:line options:0 range:NSMakeRange(0, line.length)
                         usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        NSRange r = [result rangeAtIndex:1];
        if (r.location == NSNotFound) return;
        NSInteger v = [[line substringWithRange:r] integerValue];
        if (v >= kMpPortMin && v <= kMpPortMax) found = (uint16_t)v;
    }];
    return found;
}

+ (MpPortResult *)parseLogText:(NSString *)text {
    if (text.length == 0) return [MpPortResult resultWithStatus:MpPortStatusUnknown port:0 source:nil];
    NSRange full = NSMakeRange(0, text.length);

    /* 1) 收集所有「开放」事件（位置 + 端口） */
    __block NSUInteger bestPubLoc = NSNotFound;
    __block uint16_t bestPubPort = 0;
    for (NSRegularExpression *re in [self publishPatterns]) {
        [re enumerateMatchesInString:text options:0 range:full
                          usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            if (result.numberOfRanges < 2) return;
            NSRange r = [result rangeAtIndex:1];
            if (r.location == NSNotFound) return;
            NSInteger v = [[text substringWithRange:r] integerValue];
            if (v < kMpPortMin || v > kMpPortMax) return;
            if (bestPubLoc == NSNotFound || result.range.location >= bestPubLoc) {
                bestPubLoc = result.range.location;
                bestPubPort = (uint16_t)v;
            }
        }];
    }

    /* 2) 收集所有「关闭」事件 */
    __block NSUInteger bestUnpubLoc = NSNotFound;
    for (NSRegularExpression *re in [self unpublishPatterns]) {
        [re enumerateMatchesInString:text options:0 range:full
                          usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            if (bestUnpubLoc == NSNotFound || result.range.location >= bestUnpubLoc) {
                bestUnpubLoc = result.range.location;
            }
        }];
    }

    /* 3) 只有「最后一次开放晚于最后一次关闭」才算当前有效 */
    if (bestPubLoc != NSNotFound && (bestUnpubLoc == NSNotFound || bestPubLoc > bestUnpubLoc)) {
        return [MpPortResult resultWithStatus:MpPortStatusPublished port:bestPubPort source:nil];
    }
    if (bestUnpubLoc != NSNotFound && (bestPubLoc == NSNotFound || bestUnpubLoc > bestPubLoc)) {
        return [MpPortResult resultWithStatus:MpPortStatusUnpublished port:0 source:nil];
    }

    /* 4) 兜底：未知措辞但含关键词 + "port" 的行，仍取最后一次 */
    NSRegularExpression *generic = [self genericLinePattern];
    if (generic != nil) {
        __block NSUInteger genLoc = NSNotFound;
        __block uint16_t genPort = 0;
        [generic enumerateMatchesInString:text options:0 range:full
                              usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            NSRange lineRange = [text lineRangeForRange:result.range];
            NSString *line = [text substringWithRange:lineRange];
            if (![line.lowercaseString containsString:@"port"]) return;
            // 关闭类行不做兜底命中（避免把 "…was on port N" 当开放）
            for (NSRegularExpression *ure in [self unpublishPatterns]) {
                if ([ure firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil) return;
            }
            uint16_t v = [self lastPortInLine:line];
            if (v == 0) return;
            if (genLoc == NSNotFound || result.range.location >= genLoc) {
                genLoc = result.range.location;
                genPort = v;
            }
        }];
        if (genLoc != NSNotFound) {
            MpPortResult *r = [MpPortResult resultWithStatus:MpPortStatusPublished port:genPort source:nil];
            r.fromGenericFallback = YES;
            return r;
        }
    }
    return [MpPortResult resultWithStatus:MpPortStatusUnknown port:0 source:nil];
}

#pragma mark - 读文件

/// 取「当前会话最可能」的主日志：候选里存在且非空、mtime 最新的那份（并列取候选顺序靠前者）。
- (NSString *)pickPrimaryPathWithInstanceName:(NSString *)instanceName {
    NSArray<NSString *> *cands = [MpPortDetector candidateLogPathsWithInstanceName:instanceName];
    NSString *best = nil;
    NSTimeInterval bestM = -1;
    for (NSString *p in cands) {
        unsigned long long sz = MpFileSize(p);
        if (sz == 0) continue;
        NSTimeInterval m = MpFileMTime(p);
        if (best == nil || m > bestM) { best = p; bestM = m; }   // 严格 > ⇒ 并列取靠前者
    }
    return best;
}

/// 全量（末尾 budget 字节）解析
- (MpPortResult *)fullScanPath:(NSString *)path {
    unsigned long long size = MpFileSize(path);
    if (size == 0) return [MpPortResult resultWithStatus:MpPortStatusUnknown port:0 source:path];
    unsigned long long start = (size > self.backwardBudgetBytes) ? (size - self.backwardBudgetBytes) : 0;
    NSData *d = MpReadRange(path, start, (NSUInteger)(size - start));
    NSString *t = MpDropLeadingPartialLine(MpDataToText(d), start > 0);
    MpPortResult *r = [MpPortDetector parseLogText:t];
    r.sourcePath = path;
    return r;
}

- (MpPortResult *)detectNowWithInstanceName:(NSString *)instanceName {
    NSString *path = [self pickPrimaryPathWithInstanceName:instanceName];
    if (path.length == 0) {
        return [MpPortResult resultWithStatus:MpPortStatusUnknown port:0 source:nil];
    }
    unsigned long long size = MpFileSize(path);
    BOOL sameFile = (_lastPath != nil && [path isEqualToString:_lastPath]);
    MpPortResult *r = nil;

    if (!sameFile || size < _lastSize) {
        /* 换了文件 / 被轮转截断 ⇒ 全量重扫 */
        r = [self fullScanPath:path];
        NSLog(@"[MP-PORT] full scan path=%@ size=%llu -> %@", path.lastPathComponent, size, r);
    } else if (size == _lastSize) {
        /* 没长 ⇒ 直接复用上次结论（零 IO） */
        r = _lastResult ?: [MpPortResult resultWithStatus:MpPortStatusUnknown port:0 source:path];
    } else {
        /* 增量：只读新增字节（带重叠，丢掉半个行首） */
        unsigned long long start = (size > kMpPortIncrementalOverlap) ? (size - kMpPortIncrementalOverlap) : 0;
        NSData *d = MpReadRange(path, start, (NSUInteger)(size - start));
        NSString *t = MpDropLeadingPartialLine(MpDataToText(d), start > 0);
        MpPortResult *chunk = [MpPortDetector parseLogText:t];
        if (chunk.status != MpPortStatusUnknown) {
            r = chunk;
            r.sourcePath = path;
        } else {
            r = _lastResult ?: chunk;   // 新增内容里没有事件 ⇒ 维持上次结论
        }
        NSLog(@"[MP-PORT] incr scan path=%@ +%lluB -> %@", path.lastPathComponent, size - _lastSize, r);
    }

    _lastPath = path;
    _lastSize = size;
    _lastResult = r;
    return r;
}

#pragma mark - 轮询

- (void)startPollingWithInstanceName:(NSString *)instanceName
                             handler:(void (^)(MpPortResult *))handler {
    [self stopPolling];
    if (handler == nil) return;

    _reportedStatus = MpPortStatusUnknown;
    _reportedPort = 0;
    NSLog(@"[MP-PORT] start polling instance=%@ interval=%.1fs", instanceName ?: @"(auto)", self.pollInterval);
    NSLog(@"[MP-PORT] candidates=%@", [[MpPortDetector candidateLogPathsWithInstanceName:instanceName]
                                      componentsJoinedByString:@" | "] ?: @"(none)");

    __weak typeof(self) weakSelf = self;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(MAX(self.pollInterval, 0.2) * NSEC_PER_SEC);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),      // 首轮立即
                              interval,
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        MpPortResult *r = [strongSelf detectNowWithInstanceName:instanceName];
        if (r.status == strongSelf->_reportedStatus && r.port == strongSelf->_reportedPort) return;
        strongSelf->_reportedStatus = r.status;
        strongSelf->_reportedPort = r.port;
        NSLog(@"[MP-PORT] changed -> %@", r);
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(r);
        });
    });
    dispatch_resume(_timer);
}

- (void)stopPolling {
    if (_timer != nil) {
        dispatch_source_cancel(_timer);
        _timer = nil;
        _reportedStatus = MpPortStatusUnknown;
        _reportedPort = 0;
        NSLog(@"[MP-PORT] stop polling");
    }
}

@end
