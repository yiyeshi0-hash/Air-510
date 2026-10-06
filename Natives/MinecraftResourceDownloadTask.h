#import <UIKit/UIKit.h>

@class AFURLSessionManager;
@class ModpackAPI;

extern NSString * const kMinecraftResourceDownloadBackgroundSessionIdentifier;

@interface MinecraftResourceDownloadTask : NSObject

+ (AFURLSessionManager *)sharedBackgroundSessionManager;

@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, copy) void(^modpackDownloadCompletion)(void);

// 重试相关属性
@property(nonatomic) NSInteger maxRetryCount;
@property(nonatomic, readonly) NSInteger currentRetryCount;
@property(nonatomic, copy) void(^retryCallback)(NSInteger retryCount, NSInteger maxRetryCount);

// 阶段5修复（参照 FCL）：失败的文件列表，单文件下载失败不再取消整批任务，
// 而是记录到此数组，最终汇总报告给用户。每个元素是 @{@"name": ..., "error": ...}
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *failedFiles;

// 新增方法声明（用于账户检查）
- (BOOL)checkAccessWithDialog:(BOOL)show;

- (void)prepareForDownload;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success;

// 带重试的下载任务创建
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path retryCount:(NSInteger)retryCount success:(void (^)())success;

- (void)finishDownloadWithErrorString:(NSString *)error;

/// 取消整个下载流程（redesign-download-ui Phase 3）：
/// 供 DownloadTaskManager.cancelRawTask: 通过 respondsToSelector:@selector(cancel)
/// 调用——统一进度页的取消按钮取消任务时，取消内部 NSProgress 以中断流程，
/// KVO 观察到 cancelled 后按既有路径收尾（置 Cancelled 状态并移除观察者）。
- (void)cancel;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

// ★ [PREDL] 安装期“一次装全”：对刚写入的实例（Fabric/Quilt profile 等）执行完整的
//   库 + 资源 + client.jar(伪库) 补齐，使首次启动【离线也能进】。
//   - 复用启动期完全相同的解析/补齐逻辑（processVersion / tweakVersionJson /
//     downloadClientLibraries / downloadClientAssets），保证「安装产物 == 启动所需」；
//   - 不注册 DownloadTaskManager 任务（stageReportingEnabled=NO、currentDownloadTaskItem=nil），
//     进度仅内部计数 ⇒ 不弹第二个统一进度页、不抢安装任务 UI；
//   - 有界轮询等待完成（与 AiAssetTools/DownloadViewController 的 30 分钟轮询同口径）。
//   语义：success=YES 表示安装期已把启动所需文件全部落地（可离线启动）；
//        success=NO 表示仍有缺件（error.localizedDescription 列出），启动时才会现补。
- (void)prefillVersionResources:(NSDictionary *)version
                     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

@end