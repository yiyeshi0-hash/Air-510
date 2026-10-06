//
//  MpPortDetector.h
//  Amethyst
//
//  ★ [MP-PORT] MC「对局域网开放」**实际端口**探测（只读日志；绝不 bind 端口）
//
//  为什么需要它（相对已下线的 [PORT-AUTO] / McLanPortDetector）：
//    1) MC 各版本措辞不同 —— 26.2/26.3/26.4 实测打印的是
//         [12:34:56] [Server thread/INFO]: Published LAN server on port 54321
//       （字符串常量取自 client-26.*.jar 的 IntegratedServer.class：
//        "Published LAN server on port {}"），而旧探测器只写了
//        "Started serving on port" / "Local game hosted on port" / "Opening LAN on port"
//        三条具体式样 —— 26.x 一条都不中，全靠「兜底」偶然命中。这里把 26.x 真身
//        列为一等公民，同时保留旧版本措辞。
//    2) 「当前会话那一次」—— 旧实现只按「文件里最后一次出现」取值，
//        MC 关闭局域网后打印的 "Unpublishing integrated server (was on port N)"
//        不识别 ⇒ 关掉局域网后仍返回旧端口（房客连不上）；并且旧实现把
//        latestlog.old.txt（**上一次运行**）也当候选 ⇒ 会拿上次会话的端口。
//       本实现用状态机：publish 与 unpublish 比位置，只有「最后一次 publish 晚于
//       最后一次 unpublish」才认；且**不读** *.old.*。
//    3) 「日志太长」—— 旧实现只读文件末尾 8MB。真机实测（iPad 金属渲染期
//        ~63 KB/s 日志，见下）**131 秒就把 8MB 尾窗挤出**，开局域网两分钟后
//        再打开联机页就再也读不到那行。本实现默认向后再读 96MB，并且轮询时只读
//        **新增字节**（增量），既省 IO 又不会漏。
//    4) 「路径」—— [VER-ISOLATE-PCL] 版本隔离开启后游戏真实目录是
//         <POJAV_HOME>/instances/<实例>/versions/<版本 id>
//       （见 JavaLauncher.m 的 amePCLVersionGameDirSubpath），旧实现只拼到
//         <POJAV_HOME>/instances/<实例> ⇒ logs/latest.log 指向不存在的地方。
//       本实现把 versions/*/ 子目录按 mtime 一并列入候选。
//
//  本类只做「找候选日志 → 读 → 解析 → （可选）定时轮询 → 回调」，不做任何网络绑定。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一次探测的结论
typedef NS_ENUM(NSInteger, MpPortStatus) {
    MpPortStatusUnknown     = 0,  ///< 这次扫描没看到任何「开放/关闭局域网」事件（可能还没开局域网）
    MpPortStatusPublished   = 1,  ///< 当前处于「已开放局域网」，port 有效
    MpPortStatusUnpublished = 2,  ///< 日志显示最近一次事件是「关闭局域网」⇒ 当前没有可用端口
};

#pragma mark - 结果

@interface MpPortResult : NSObject
@property (nonatomic, assign) MpPortStatus status;
@property (nonatomic, assign) uint16_t port;              ///< 仅 Published 有效
@property (nonatomic, copy, nullable) NSString *sourcePath;
@property (nonatomic, assign) BOOL fromGenericFallback;   ///< 是否走了「未知形态」兜底行
+ (instancetype)resultWithStatus:(MpPortStatus)status port:(uint16_t)port source:(nullable NSString *)source;
@end

#pragma mark - 探测器

@interface MpPortDetector : NSObject

/// 单例（便于日志/兼容；需要独立生命周期时直接 alloc/init —— 两个联机页各持一个，互不干扰）
+ (instancetype)sharedDetector;

/// 当前是否在轮询
@property (nonatomic, readonly) BOOL polling;

/// 单次探测向文件末尾回扫的上限（默认 96MB；超出则只取末尾这么多）
@property (nonatomic, assign) unsigned long long backwardBudgetBytes;

/// 轮询间隔（默认 0.5s；首轮立即执行）
@property (nonatomic, assign) NSTimeInterval pollInterval;

#pragma mark 路径
/// 启动器主目录：POJAV_HOME → Documents
+ (nullable NSString *)launcherHome;
/// 当前实例名（general.game_directory → nil）
+ (nullable NSString *)instanceNameFromPreferences;
/// 候选日志路径（已按「最可能是当前会话」排序；已剔除 *.old.*）
+ (NSArray<NSString *> *)candidateLogPathsWithInstanceName:(nullable NSString *)instanceName;

#pragma mark 解析（纯函数，便于单测）
/// 解析一段日志文本：宽松多格式 + 「最后一次 publish 晚于最后一次 unpublish」语义
+ (MpPortResult *)parseLogText:(nullable NSString *)text;

#pragma mark 探测
/// 立刻探测一次（内部会复用增量状态：同一个文件只读新增字节）
- (MpPortResult *)detectNowWithInstanceName:(nullable NSString *)instanceName;

#pragma mark 轮询
/// 开始轮询；结论（status/port）变化时回主线程回调。停旧的再起新的。
- (void)startPollingWithInstanceName:(nullable NSString *)instanceName
                             handler:(void (^)(MpPortResult *result))handler;
/// 停止轮询（幂等）
- (void)stopPolling;

@end

NS_ASSUME_NONNULL_END
