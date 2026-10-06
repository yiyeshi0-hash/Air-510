//
//  BackgroundManager.h
//  Amethyst
//
//  Background wallpaper manager - Global support for all view controllers
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BackgroundType) {
    BackgroundTypeNone = 0,
    BackgroundTypeImage,
    BackgroundTypeVideo
};

typedef NS_ENUM(NSInteger, BackgroundUIEffect) {
    BackgroundUIEffectTranslucent = 0,  // 半透明
    BackgroundUIEffectBlur              // 毛玻璃效果
};

// ===========================================================================
//  ★ [BG-CONTRAST] 自定义背景下的「自适应前景色 / 可读性」真相源
//  ---------------------------------------------------------------------------
//  问题:用户设了自定义背景图/视频后,界面文字要么恒白、要么恒黑(见设置页里写死的
//        [UIColor whiteColor],以及只跟「浅色/深色模式」走的 labelColor 一族)⇒
//        浅背景 + 深色模式 ⇒ 白字看不见;深背景 + 浅色模式 ⇒ 黑字看不见。
//  方案:从当前背景(图/视频)算出【代表亮度】(8×8 区块中位数,抗局部过亮/过暗),
//        据此选深/浅前景并统一由本类给出 ⇒ 全树引同一处,不再各写各的。
//  ★ 兜底铁律:无自定义背景(系统默认渐变/纯色)或亮度未知 ⇒ 返回【语义色】
//    (labelColor/secondaryLabelColor/…),与改造前**逐像素一致**,默认观感零变化。
// ===========================================================================

/// 前景色模式(用户可配;默认自动)
typedef NS_ENUM(NSInteger, AMEForegroundMode) {
    AMEForegroundModeAuto       = 0,  // 自动:按背景代表亮度选深/浅前景(默认)
    AMEForegroundModeForceDark  = 1,  // 强制深色前景(浅色背景用)
    AMEForegroundModeForceLight = 2,  // 强制浅色前景(白字,深色背景用)
};

/// 前景色角色(与系统语义色一一对应)
typedef NS_ENUM(NSInteger, AMEForegroundRole) {
    AMEForegroundRolePrimary    = 0,  // 标题 / 正文      ⇄ labelColor
    AMEForegroundRoleSecondary  = 1,  // 副标题           ⇄ secondaryLabelColor
    AMEForegroundRoleTertiary   = 2,  // 弱提示 / 图标     ⇄ tertiaryLabelColor
    AMEForegroundRoleQuaternary = 3,  // 占位符           ⇄ quaternaryLabelColor
};

/// 背景(图片/视频/默认)或前景模式变化 ⇒ 各页监听后重刷前景色
FOUNDATION_EXPORT NSNotificationName const AMEForegroundContrastChangedNotification;

/// 全局便捷函数(各 UI 文件直接调用,免 import 实例):
/// 无自定义背景 ⇒ 与现状语义色逐像素一致;有自定义背景 ⇒ 按亮度自适应。
FOUNDATION_EXPORT UIColor *AMEForegroundColor(AMEForegroundRole role);
/// 文字阴影色(浅色前景 ⇒ 深色阴影;深色前景 ⇒ 浅色高光;无自定义背景 ⇒ nil)
FOUNDATION_EXPORT UIColor * _Nullable AMEForegroundShadowColor(void);

@interface BackgroundManager : NSObject

+ (instancetype)sharedManager;

// Background type
@property (nonatomic, readonly) BackgroundType currentType;
@property (nonatomic, readonly, nullable) NSString *currentBackgroundPath;

// UI effect settings (for custom background)
@property (nonatomic, assign) BackgroundUIEffect uiEffect;
@property (nonatomic, assign) CGFloat uiOpacity;  // 0.0 ~ 1.0
@property (nonatomic, assign) CGFloat blurIntensity; // 0.0 ~ 1.0, 背景模糊程度

// ★ [BG-CONTRAST] 自适应前景色真相源
/// 前景色模式(自动 / 强制深 / 强制浅);默认自动。写入即持久化并广播通知。
@property (nonatomic, assign) AMEForegroundMode foregroundMode;
/// 当前背景的【代表亮度】0…1(8×8 区块中位数);-1 = 未知(无自定义背景 / 视频尚未取样)。
- (CGFloat)representativeBackgroundLuminance;
/// 是否判为「亮背景」(需要深色前景)。无自定义背景 / 亮度未知 ⇒ NO(不改变现状)。
- (BOOL)backgroundIsLight;
/// 自适应前景色(单一真相源):无自定义背景 ⇒ 语义色(labelColor 一族,观感不变)。
- (UIColor *)foregroundColorForRole:(AMEForegroundRole)role;
/// 自适应文字阴影色(可读性兜底);无自定义背景 ⇒ nil。
- (UIColor * _Nullable)foregroundShadowColorForRole:(AMEForegroundRole)role;
/// 一行自证诊断串(亮度 / 判定 / 模式),供 NSLog 用。
- (NSString *)foregroundDiagnostics;

// Global background container
@property (nonatomic, strong, readonly, nullable) UIView *globalBackgroundContainer;

// Apply background globally
- (void)applyBackgroundToWindow:(UIWindow *)window;
- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC;
- (void)removeGlobalBackground;

// Legacy compatibility
- (void)applyBackgroundToView:(UIView *)view;
- (void)removeBackgroundFromView:(UIView *)view;

// Set background
- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)clearBackground;

// Check if has background
- (BOOL)hasBackground;
/// ★ [GLASS-BG] 「本风格下壁纸是否可见」= hasBackground 且 实际生效风格=液态玻璃。
///   用户拍板「如果是原生就不透」⇒ 原生风格(含 iOS<26 强制原生)下页面/面板/行一律实底,
///   壁纸不参与 UI。各处「按壁纸透明化 / 按壁纸取前景色」的分支请用这一条,别用 hasBackground。
- (BOOL)hasUIVisibleBackground;
- (BOOL)hasImageBackground;
- (BOOL)hasVideoBackground;

// Get background preview
- (nullable UIImage *)backgroundPreview;

// Pause/Resume video (for app lifecycle)
- (void)pauseVideo;
- (void)resumeVideo;

// Update background frame (call on rotation)
- (void)updateBackgroundFrame;

// Make view controllers transparent (for global background visibility)
- (void)makeViewControllerTransparent:(UIViewController *)viewController;
- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC;

// Apply UI effect to any UIView (blur or translucent based on settings)
/// ★ [RIM-UI] 高光描边开关(默认开;背景设置页可关)
@property(nonatomic, assign) BOOL glassRimEnabled;
/// ★ [RIM-UI] 高光强度 0…1(默认 1.0;设置页可调,0 等于关)
@property(nonatomic, assign) CGFloat glassRimStrength;

- (void)applyEffectToView:(UIView *)view;
- (void)applyEffectToCollectionViewCell:(UICollectionViewCell *)cell;
- (void)applyEffectToCell:(UITableViewCell *)cell;
// 适配 UISearchBar：移除默认不透明背景，让 searchBar 透出底层自定义启动器背景
- (void)applyEffectToSearchBar:(UISearchBar *)searchBar;

// Apply UI effect to navigation bar and toolbar
- (void)applyEffectToNavigationBar:(UINavigationBar *)navigationBar;
- (void)applyEffectToToolbar:(UIToolbar *)toolbar;

// Apply UI effect settings to current split view controller
- (void)refreshUIEffect;

@end

NS_ASSUME_NONNULL_END