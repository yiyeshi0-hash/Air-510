#import "utils.h"
//
//  BackgroundManager.m
//  Amethyst
//
//  Background wallpaper manager implementation - Global Version with Transparency
//

#import "BackgroundManager.h"
#import "UIKit+GlassSurface.h"   // ★ 液态玻璃材质 + 玻璃质感(高光边)
#import "AMEGlassStyle.h"        // ★ [GLASS-STYLE] 界面风格解析层(原生 / 液态玻璃)
#import <Photos/Photos.h>

static NSString * const kBackgroundTypeKey = @"background_type";
static NSString * const kBackgroundPathKey = @"background_path";
static NSString * const kBackgroundUIEffectKey = @"background_ui_effect";
static NSString * const kBackgroundUIOpacityKey = @"background_ui_opacity";
static NSString * const kBackgroundBlurIntensityKey = @"background_blur_intensity";
static NSString * const kGlassRimEnabledKey  = @"background_glass_rim_enabled";   // ★ [RIM-UI]
static NSString * const kGlassRimStrengthKey = @"background_glass_rim_strength";  // ★ [RIM-UI]
static NSString * const kForegroundModeKey   = @"background_foreground_mode";     // ★ [BG-CONTRAST]
static NSString * const kBackgroundsFolder = @"backgrounds";
static const NSInteger kGlobalBackgroundTag = 99999;
static const NSInteger kBackgroundImageTag = 99998;
static const NSInteger kBackgroundBlurTag = 99997;
static const NSInteger kBackgroundDimTag = 99996;
static const NSInteger kDefaultBackgroundTag = 99995;

// ★ [BG-CONTRAST] 背景/前景模式变化广播
NSNotificationName const AMEForegroundContrastChangedNotification = @"AMEForegroundContrastChanged";

// ★ [BG-CONTRAST] 亮度判定:WCAG 相对对比度交叉点
//   contrast(白字) > contrast(黑字) ⇔ (1.05)/(L+0.05) > (L+0.05)/(0.05) ⇔ L < 0.179
//   ⇒ L < 0.179 用浅色前景(白字);否则用深色前景(深字)。纯白图 L≈1 ⇒ 深字;纯黑图 L≈0 ⇒ 白字。
static const CGFloat kAMELumaLightForegroundCeiling = 0.179f;
// ★ [GLASSUI] 合并同一 runloop 内的多次玻璃重刷(强度滑块连续拖动时避免反复遍历视图树)
static BOOL gAmeGlassRimApplyScheduled = NO;

#pragma mark - ★ [E3] 默认背景渐变视图(SPEC §2.1:深=紫蓝 / 浅=白→粉紫)
//
// 未设自定义背景图/视频时的默认背景。原实现是平面 systemBackgroundColor(深黑/浅白),
// 与 E 稿「深 = 紫蓝渐变 / 浅 = 白→粉紫渐变」不符。
// 本视图自绘渐变(base 线性 + 3 个椭圆径向光斑),仅当 currentType == BackgroundTypeNone
// (无自定义背景)时挂载 ⇒ 不触碰自定义背景图/视频路径,主界面自定义能力保留。
@interface AmeGradientBackgroundView : UIView
@end

@implementation AmeGradientBackgroundView {
    CGSize _ameLastLayoutSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO;
        self.opaque = YES;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self setNeedsDisplay];
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 尺寸变化(旋转/分屏)后重绘,保证渐变铺满
    if (!CGSizeEqualToSize(_ameLastLayoutSize, self.bounds.size)) {
        _ameLastLayoutSize = self.bounds.size;
        [self setNeedsDisplay];
    }
}

- (void)drawRect:(CGRect)rect {
    BOOL dark = YES;
    if (@available(iOS 13.0, *)) {
        dark = (self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
    }
    [AmeGradientBackgroundView ame_drawDefaultBackgroundInRect:self.bounds dark:dark];
}

// 一个椭圆径向渐变(CSS radial(rx ry at x y) 用 CTM 缩放近似:先画圆再压扁)
+ (void)ame_drawRadialInContext:(CGContextRef)ctx
                         center:(CGPoint)c
                             rx:(CGFloat)rx
                             ry:(CGFloat)ry
                          color:(UIColor *)color
                           stop:(CGFloat)stop {
    if (rx <= 0.0 || ry <= 0.0 || color == nil) { return; }
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 1.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        const CGFloat *cs = CGColorGetComponents(color.CGColor);
        size_t n = CGColorGetNumberOfComponents(color.CGColor);
        if (cs != NULL) {
            r = cs[0]; g = cs[1]; b = cs[2]; a = (n >= 4) ? cs[3] : 1.0;
        }
    }
    CGFloat comps[8] = { r, g, b, a, r, g, b, 0.0 };
    CGFloat locs[2]  = { 0.0, MAX(0.01, MIN(1.0, stop)) };
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, c.x, c.y);
    CGContextScaleCTM(ctx, 1.0, ry / rx);            // 圆 → 椭圆
    CGContextDrawRadialGradient(ctx, grad, CGPointZero, 0.0, CGPointZero, rx,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(ctx);
    CGGradientRelease(grad);
    CGColorSpaceRelease(space);
}

+ (void)ame_drawDefaultBackgroundInRect:(CGRect)b dark:(BOOL)dark {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx == NULL || b.size.width <= 0.0 || b.size.height <= 0.0) { return; }
    const CGFloat W = b.size.width, H = b.size.height;

    UIColor *base0 = nil, *base1 = nil, *r1 = nil, *r2 = nil, *r3 = nil;
    CGFloat r1x = 0.9 * W, r1y = 0.70 * H, r1s = 0.60;   // 蓝光斑
    CGFloat r2x = 0.9 * W, r2y = 0.80 * H, r2s = 0.55;   // 品红/粉光斑
    CGFloat r3x = 0.8 * W, r3y = 0.70 * H, r3s = 0.60;   // 青色/薄荷光斑
    if (dark) {
        // 深色:紫蓝渐变  base #101322 → #05060c
        base0 = AmeRGBA(0x10, 0x13, 0x22, 1.0);
        base1 = AmeRGBA(0x05, 0x06, 0x0C, 1.0);
        r1 = AmeRGBA(90, 130, 255, 0.55);
        r2 = AmeRGBA(210, 90, 220, 0.50);
        r3 = AmeRGBA(0, 220, 200, 0.32);
    } else {
        // 浅色:白→粉紫  base #eef3ff → #fdf8ff
        base0 = AmeRGBA(0xEE, 0xF3, 0xFF, 1.0);
        base1 = AmeRGBA(0xFD, 0xF8, 0xFF, 1.0);
        r1 = AmeRGBA(150, 185, 255, 0.90);
        r2 = AmeRGBA(255, 175, 235, 0.85);
        r3 = AmeRGBA(160, 240, 225, 0.70);
    }

    // 线性底(top → bottom)
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef baseGrad = CGGradientCreateWithColors(space,
        (__bridge CFArrayRef)@[(id)base0.CGColor, (id)base1.CGColor], NULL);
    CGContextDrawLinearGradient(ctx, baseGrad,
                                CGPointMake(CGRectGetMinX(b), CGRectGetMinY(b)),
                                CGPointMake(CGRectGetMinX(b), CGRectGetMaxY(b)), 0);
    CGGradientRelease(baseGrad);
    CGColorSpaceRelease(space);

    // 三个径向光斑(坐标 = CSS 的 at x% y%)
    [self ame_drawRadialInContext:ctx
                           center:CGPointMake(CGRectGetMinX(b) + 0.12 * W, CGRectGetMinY(b) + 0.00 * H)
                               rx:r1x ry:r1y color:r1 stop:r1s];
    [self ame_drawRadialInContext:ctx
                           center:CGPointMake(CGRectGetMinX(b) + 0.92 * W, CGRectGetMinY(b) + 0.22 * H)
                               rx:r2x ry:r2y color:r2 stop:r2s];
    [self ame_drawRadialInContext:ctx
                           center:CGPointMake(CGRectGetMinX(b) + 0.40 * W, CGRectGetMinY(b) + 1.00 * H)
                               rx:r3x ry:r3y color:r3 stop:r3s];
}

@end

@interface BackgroundManager ()
@property (nonatomic, strong) AVPlayer *videoPlayer;
@property (nonatomic, strong) AVPlayerLayer *videoPlayerLayer;
@property (nonatomic, weak) UIView *currentBackgroundView;
@property (nonatomic, readwrite) BackgroundType currentType;
@property (nonatomic, readwrite, nullable) NSString *currentBackgroundPath;
@property (nonatomic, weak) UIWindow *currentWindow;
@property (nonatomic, weak) UISplitViewController *currentSplitVC;
@property (nonatomic, strong, readwrite, nullable) UIView *globalBackgroundContainer;
// ★ [E3] 记住默认渐变宿主(removeGlobalBackground 的 currentWindow 会被置 nil,需单独持弱引用清理)
@property (nonatomic, weak) UIView *ameDefaultGradientHost;

// ★ [BG-CONTRAST] 背景代表亮度缓存(按 路径 + mtime 复用;视频首帧异步补算)
@property (nonatomic, assign) CGFloat ameCachedLuma;         // 0…1;-1 = 未算出
@property (nonatomic, assign) CGFloat ameLumaMin;            // 区块最小亮度(诊断)
@property (nonatomic, assign) CGFloat ameLumaMax;            // 区块最大亮度(诊断)
@property (nonatomic, copy)   NSString *ameLumaPath;
@property (nonatomic, assign) NSTimeInterval ameLumaMtime;
@property (nonatomic, assign) BOOL ameLumaComputed;
@property (nonatomic, assign) BOOL ameVideoLumaPending;
- (void)ame_storeLuma:(CGFloat)luma path:(NSString *)path mtime:(NSTimeInterval)mtime;
- (void)ame_invalidateForegroundContrast;
// ★ [E3] 私有:把默认渐变背景挂到宿主(window / splitVC.view)
- (void)ame_applyDefaultGradientToHost:(UIView *)host;
// ★ [GLASSUI] 私有:玻璃高光设置即时生效(设置页接入用)
- (void)applyGlassRimSettingsNow;
- (void)ameApplyGlassRimSettingsToViewTree:(UIView *)root;
// ★ [GLASS-STYLE] 私有:界面风格(原生 / 液态玻璃)即时生效
- (void)ameSyncGlassRimStrengthForCurrentStyle;
- (void)ameReapplyGlassStyleToViewTree:(UIView *)root;
- (void)ameGlassStyleChanged:(NSNotification *)note;
@end

@implementation BackgroundManager

+ (instancetype)sharedManager {
    static BackgroundManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadSavedBackground];
        [self loadUISettings];
        [self setupNotifications];
    }
    return self;
}

- (void)setupNotifications {
    // App lifecycle
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // Video loop
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    
    // Orientation changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleOrientationChange)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
    
    // Window size changes (iPad multitasking, rotation)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBackgroundFrame)
                                                 name:UIApplicationWillChangeStatusBarFrameNotification
                                               object:nil];

    // ★ [GLASS-STYLE] 界面风格切换(设置页写 AMEGlassStyleSetConfigured ⇒ 广播)⇒ 立即按新风格重刷
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ameGlassStyleChanged:)
                                                 name:AMEGlassStyleChangedNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cleanupVideoPlayer];
}

#pragma mark - Backgrounds Folder

- (NSString *)backgroundsFolderPath {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [docsDir stringByAppendingPathComponent:kBackgroundsFolder];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:folder]) {
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    return folder;
}

#pragma mark - Load/Save Background

- (void)loadSavedBackground {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.currentType = [defaults integerForKey:kBackgroundTypeKey];
    self.currentBackgroundPath = [defaults stringForKey:kBackgroundPathKey];
    
    // Validate path exists
    if (self.currentBackgroundPath && ![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) {
        self.currentBackgroundPath = nil;
        self.currentType = BackgroundTypeNone;
        [self saveBackgroundSettings];
    }
}

- (void)saveBackgroundSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.currentType forKey:kBackgroundTypeKey];
    // ★ [AUDIT] currentBackgroundPath 是 nullable(见头文件),clearBackgroundInternal /
    //   loadSavedBackground 都会把它置为 nil;而 setObject:forKey: 传 nil 会抛
    //   NSInvalidArgumentException(object cannot be nil)→ 崩溃(与
    //   「setTitleTextAttributes:nil」属同一类「把 nil 传给非空参数」的崩法)。
    //   nil 时改用 removeObjectForKey: 清除该键(NSUserDefaults 的官方清值方式)。
    if (self.currentBackgroundPath.length > 0) {
        [defaults setObject:self.currentBackgroundPath forKey:kBackgroundPathKey];
    } else {
        [defaults removeObjectForKey:kBackgroundPathKey];
    }
    [defaults synchronize];
}

- (void)loadUISettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // ★ [UI-B] 修复(2026-10-02):键不存在时 integerForKey 返回 0,而 0 == BackgroundUIEffectTranslucent,
    //   越界校验永远判不出"从未设置过" ⇒ 首装默认落到"半透明" ⇒ applyEffectToView: 的 Blur 分支永不执行
    //   ⇒ 整条玻璃路径被静默跳过(用户现场:"我可以保证主界面绝对没有玻璃")。用 objectForKey 区分。
    id ameEffObj = [defaults objectForKey:kBackgroundUIEffectKey];
    _uiEffect = ameEffObj ? [defaults integerForKey:kBackgroundUIEffectKey] : BackgroundUIEffectBlur;
    if (_uiEffect < BackgroundUIEffectTranslucent || _uiEffect > BackgroundUIEffectBlur) {
        _uiEffect = BackgroundUIEffectBlur; // 默认毛玻璃效果
    }
    
    _uiOpacity = [defaults floatForKey:kBackgroundUIOpacityKey];
    if (_uiOpacity < 0.1 || _uiOpacity > 1.0) {
        _uiOpacity = 0.7; // 默认透明度
    }
    
    // ★ [UI-B] 同型修复(2026-10-02):键不存在返回 0.0,恰在合法区间 [0,1] 内 ⇒ 强度 0%
    //   ⇒ blurView.alpha = 0.3 + 0*0.7 = 0.3,观感近于无。默认给 0.7。
    id ameBlurObj = [defaults objectForKey:kBackgroundBlurIntensityKey];
    _blurIntensity = ameBlurObj ? [defaults floatForKey:kBackgroundBlurIntensityKey] : 0.7;
    if (_blurIntensity < 0.0 || _blurIntensity > 1.0) {
        _blurIntensity = 0.7; // 默认模糊程度
    }

    // ★ [GLASS-MIGRATE] 一次性迁移:老版本"键不存在 => 0 => 半透明"的 bug 会把第一次运行写成
    //   "半透明",于是 applyEffectToView: 永远走 else 分支 ⇒ 用户现场"主界面绝对没有玻璃"。
    //   这里只做【一次】:若当前是半透明且从未迁移过,改成毛玻璃并打标记(用户仍可在设置里改回)。
    static NSString * const kGlassMigratedKey = @"background.glass_migrated_v1";
    if (_uiEffect == BackgroundUIEffectTranslucent && ![defaults boolForKey:kGlassMigratedKey]) {
        _uiEffect = BackgroundUIEffectBlur;
        [defaults setInteger:_uiEffect forKey:kBackgroundUIEffectKey];
        [defaults setBool:YES forKey:kGlassMigratedKey];
        [defaults synchronize];
        NSLog(@"[glass] migrated uiEffect: Translucent -> Blur (一次性,可在设置里改回)");
    }
    // ★ [RIM-UI] 高光开关 / 强度(默认:开、1.0)
    id ameRimObj  = [defaults objectForKey:kGlassRimEnabledKey];
    _glassRimEnabled  = ameRimObj ? [defaults boolForKey:kGlassRimEnabledKey] : YES;
    id ameRimSObj = [defaults objectForKey:kGlassRimStrengthKey];
    _glassRimStrength = ameRimSObj ? [defaults floatForKey:kGlassRimStrengthKey] : 1.0;
    if (_glassRimStrength < 0.0 || _glassRimStrength > 1.0) _glassRimStrength = 1.0;
    // ★ [BG-CONTRAST] 自适应前景色模式(键不存在 ⇒ 自动)
    id ameFgObj = [defaults objectForKey:kForegroundModeKey];
    _foregroundMode = ameFgObj ? (AMEForegroundMode)[defaults integerForKey:kForegroundModeKey] : AMEForegroundModeAuto;
    if (_foregroundMode < AMEForegroundModeAuto || _foregroundMode > AMEForegroundModeForceLight) {
        _foregroundMode = AMEForegroundModeAuto;
    }
    // ★ [GLASS-STYLE] 界面风格:解析实际生效风格(单一真相源),并按风格收敛纯代码玻璃强度。
    //   原生风格(iOS<26 一律,iOS>=26 用户可选)⇒ 强度强制 0(rim 助手内部也会短路,这里是双保险)。
    AMEGlassStyleLogResolvedOnce();
    [self ameSyncGlassRimStrengthForCurrentStyle];

    NSLog(@"[glass] settings loaded: uiEffect=%ld (0=半透明,1=毛玻璃) blurIntensity=%.2f uiOpacity=%.2f",
          (long)_uiEffect, _blurIntensity, _uiOpacity);
    NSLog(@"[glass] rim: enabled=%d strength=%.2f", (int)self.glassRimEnabled, self.glassRimStrength);
    // ★ [GLASS-STYLE] 自证日志:风格判定矩阵现场可判(系统能力 / 用户配置 / 实际生效)
    NSLog(@"[glass] style: 配置=%@ · 系统支持液态玻璃=%@ · 实际生效=%@",
          AMEGlassStyleStringFromEnum(AMEGlassStyleConfigured()),
          AMEGlassStyleSystemSupportsLiquid() ? @"是" : @"否",
          AMEGlassStyleStringFromEnum(AMEGlassStyleResolved()));
}

- (void)saveUISettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.uiEffect forKey:kBackgroundUIEffectKey];
    [defaults setFloat:self.uiOpacity forKey:kBackgroundUIOpacityKey];
    [defaults setFloat:self.blurIntensity forKey:kBackgroundBlurIntensityKey];
    [defaults setBool:self.glassRimEnabled forKey:kGlassRimEnabledKey];      // ★ [RIM-UI]
    [defaults setFloat:self.glassRimStrength forKey:kGlassRimStrengthKey];   // ★ [RIM-UI]
    [defaults setInteger:self.foregroundMode forKey:kForegroundModeKey];     // ★ [BG-CONTRAST]
    [defaults synchronize];
}

- (void)setUiEffect:(BackgroundUIEffect)uiEffect {
    _uiEffect = uiEffect;
    [self saveUISettings];
}

- (void)setUiOpacity:(CGFloat)uiOpacity {
    _uiOpacity = MAX(0.1, MIN(1.0, uiOpacity));
    [self saveUISettings];
}

- (void)setBlurIntensity:(CGFloat)blurIntensity {
    _blurIntensity = MAX(0.0, MIN(1.0, blurIntensity));
    [self saveUISettings];
}

// ★ [BG-CONTRAST] 前景色模式:夹紧 + 持久化 + 广播(各页重刷自适应前景)
- (void)setForegroundMode:(AMEForegroundMode)foregroundMode {
    if (foregroundMode < AMEForegroundModeAuto || foregroundMode > AMEForegroundModeForceLight) {
        foregroundMode = AMEForegroundModeAuto;
    }
    _foregroundMode = foregroundMode;
    [self saveUISettings];
    [[NSNotificationCenter defaultCenter] postNotificationName:AMEForegroundContrastChangedNotification object:nil];
    NSLog(@"[bg-contrast] 前景模式 = %ld (0=自动,1=强制深,2=强制浅) · %@",
          (long)_foregroundMode, [self foregroundDiagnostics]);
}

#pragma mark - ★ [GLASSUI] 玻璃高光 开关 / 强度(设置页接入:夹紧 + 持久化 + 即时生效)
//
// 说明:glassRimEnabled / glassRimStrength 原本只有自动合成的访问器 —— 外部直接赋值既不会
// 写进 NSUserDefaults,也不会写进 UIKit+GlassSurface.h 里的全局强度变量 gAmeGlassRimStrength。
// 这里补显式 setter,复用【既有】键(background_glass_rim_enabled / background_glass_rim_strength,
// 见本文件顶部常量),不新增第二套键/第二套实现:
//   ① 夹紧到合法区间;② saveUISettings 持久化;③ AmeSetGlassRimStrength 写全局强度(关 ⇒ 0);
//   ④ applyGlassRimSettingsNow 立即重刷屏幕上所有已挂高光的载体(即时生效)。
// 载入路径(init 里直写 _glassRimEnabled / _glassRimStrength 两个 ivar)不经过 setter ⇒ 启动不会触发重刷。
- (void)setGlassRimEnabled:(BOOL)glassRimEnabled {
    _glassRimEnabled = glassRimEnabled;
    [self saveUISettings];
    [self ameSyncGlassRimStrengthForCurrentStyle];   // ★ [GLASS-STYLE] 原生风格下恒为 0
    [self applyGlassRimSettingsNow];
}

- (void)setGlassRimStrength:(CGFloat)glassRimStrength {
    _glassRimStrength = MAX(0.0, MIN(1.0, glassRimStrength));   // ★ 夹紧:0…1,越界不入
    [self saveUISettings];
    [self ameSyncGlassRimStrengthForCurrentStyle];   // ★ [GLASS-STYLE] 原生风格下恒为 0
    [self applyGlassRimSettingsNow];
}

#pragma mark - Global Background Application

- (void)applyBackgroundToWindow:(UIWindow *)window {
    if (!window) {
        [self removeGlobalBackground];
        return;
    }
    
    self.currentWindow = window;
    self.currentSplitVC = nil;
    
    // Remove existing
    [self removeGlobalBackground];

    // For default background, just set the window's background color
    // No need for container
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式。
    // 之前硬编码深灰（0.08）在浅色模式下导致"中间一片黑"。
    // systemBackgroundColor 在浅色模式为白、深色模式为黑，自动适配。
    // 为避免状态栏区域透出纯黑，使用 systemBackground 而非纯黑。
    if (self.currentType == BackgroundTypeNone) {
        // ★ [E3] SPEC §2.1:未设自定义背景时改用默认渐变(深=紫蓝 / 浅=白→粉紫)。
        //   原值:window.backgroundColor = systemBackgroundColor(深黑/浅白,平面无色)
        //   新值:挂 AmeGradientBackgroundView —— 仅无自定义背景时生效,自定义背景路径不受影响
        [self ame_applyDefaultGradientToHost:window];
        return;
    }
    
    // Create container (for custom backgrounds)
    UIView *container = [[UIView alloc] initWithFrame:window.bounds];
    container.tag = kGlobalBackgroundTag;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor clearColor];
    
    // Insert at index 0 (behind everything)
    [window insertSubview:container atIndex:0];
    self.globalBackgroundContainer = container;
    
    // Apply content
    switch (self.currentType) {
        case BackgroundTypeImage:
            [self applyImageBackgroundToContainer:container];
            break;
        case BackgroundTypeVideo:
            [self applyVideoBackgroundToContainer:container];
            break;
        default:
            break;
    }
}

- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC {
    if (!splitVC || !splitVC.view) {
        [self removeGlobalBackground];
        return;
    }
    
    self.currentSplitVC = splitVC;
    self.currentWindow = nil;
    
    // Remove existing
    [self removeGlobalBackground];
    
    // For default background, just set the view's background color
    // No need for container or transparency
    // 修复：使用 systemBackgroundColor 自适应浅色/深色模式
    if (self.currentType == BackgroundTypeNone) {
        // ★ [E3] SPEC §2.1:默认渐变背景(同 window 路径;原为平面 systemBackgroundColor)
        [self ame_applyDefaultGradientToHost:splitVC.view];
        return;
    }
    
    // Create container that covers entire split view (for custom backgrounds)
    UIView *container = [[UIView alloc] initWithFrame:splitVC.view.bounds];
    container.tag = kGlobalBackgroundTag;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor clearColor];
    
    // Insert at the very bottom
    [splitVC.view insertSubview:container atIndex:0];
    self.globalBackgroundContainer = container;
    
    // Apply content
    switch (self.currentType) {
        case BackgroundTypeImage:
            [self applyImageBackgroundToContainer:container];
            break;
        case BackgroundTypeVideo:
            [self applyVideoBackgroundToContainer:container];
            break;
        default:
            break;
    }
    
    // Make all child controllers transparent (only for custom backgrounds)
    [self makeSplitViewControllerTransparent:splitVC];
}

- (void)removeGlobalBackground {
    // Remove from window
    if (self.currentWindow) {
        UIView *existing = [self.currentWindow viewWithTag:kGlobalBackgroundTag];
        if (existing) [existing removeFromSuperview];
    }
    
    // Remove from split VC
    if (self.currentSplitVC && self.currentSplitVC.view) {
        UIView *existing = [self.currentSplitVC.view viewWithTag:kGlobalBackgroundTag];
        if (existing) [existing removeFromSuperview];
    }
    
    // ★ [E3] 同时移除默认渐变背景 —— 切自定义背景 / 清空背景时必须清掉,否则会盖住后续内容
    if (self.currentWindow) {
        UIView *dg = [self.currentWindow viewWithTag:kDefaultBackgroundTag];
        if (dg) [dg removeFromSuperview];
    }
    if (self.currentSplitVC && self.currentSplitVC.view) {
        UIView *dg = [self.currentSplitVC.view viewWithTag:kDefaultBackgroundTag];
        if (dg) [dg removeFromSuperview];
    }
    // ★ [E3] 兜底:通过弱持有的宿主清理(切背景时 currentWindow/currentSplitVC 可能已被置 nil)
    if (self.ameDefaultGradientHost) {
        UIView *dg = [self.ameDefaultGradientHost viewWithTag:kDefaultBackgroundTag];
        if (dg) [dg removeFromSuperview];
        self.ameDefaultGradientHost = nil;
    }
    
    // Cleanup
    [self cleanupVideoPlayer];
    self.globalBackgroundContainer = nil;
    self.currentWindow = nil;
    self.currentSplitVC = nil;
}

- (void)updateBackgroundFrame {
    if (!self.globalBackgroundContainer) return;
    
    UIView *parent = self.globalBackgroundContainer.superview;
    if (!parent) return;
    
    // Update container frame
    self.globalBackgroundContainer.frame = parent.bounds;
    
    // Update default background view
    UIView *defaultBg = [self.globalBackgroundContainer viewWithTag:kDefaultBackgroundTag];
    if (defaultBg) defaultBg.frame = self.globalBackgroundContainer.bounds;
    
    // Update image view
    UIView *imageView = [self.globalBackgroundContainer viewWithTag:kBackgroundImageTag];
    if (imageView) imageView.frame = self.globalBackgroundContainer.bounds;
    
    // Update blur view
    UIView *blurView = [self.globalBackgroundContainer viewWithTag:kBackgroundBlurTag];
    if (blurView) blurView.frame = self.globalBackgroundContainer.bounds;
    
    // Update dim view
    UIView *dimView = [self.globalBackgroundContainer viewWithTag:kBackgroundDimTag];
    if (dimView) dimView.frame = self.globalBackgroundContainer.bounds;
    
    // Update video layer
    if (self.videoPlayerLayer) self.videoPlayerLayer.frame = self.globalBackgroundContainer.bounds;
}

- (void)handleOrientationChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBackgroundFrame];
    });
}

#pragma mark - Background Content Application

// ★ [E3] 把默认渐变背景挂到宿主(window / splitVC.view)。仅无自定义背景时调用。
- (void)ame_applyDefaultGradientToHost:(UIView *)host {
    if (!host) return;
    UIView *existing = [host viewWithTag:kDefaultBackgroundTag];
    if (existing) [existing removeFromSuperview];

    AmeGradientBackgroundView *g = [[AmeGradientBackgroundView alloc] initWithFrame:host.bounds];
    g.tag = kDefaultBackgroundTag;
    [host insertSubview:g atIndex:0];
    self.ameDefaultGradientHost = host;   // ★ [E3] 弱持有,便于清理
    // 兜底底色(与渐变基色一致,避免首帧/渐变外露黑)
    host.backgroundColor = AmeDynamicColor(AmeRGBA(0x10, 0x13, 0x22, 1.0),
                                           AmeRGBA(0xEE, 0xF3, 0xFF, 1.0));
}

- (void)applyDefaultBackgroundToContainer:(UIView *)container {
    // Remove existing default background
    UIView *existing = [container viewWithTag:kDefaultBackgroundTag];
    if (existing) [existing removeFromSuperview];

    // ★ [E3] SPEC §2.1:默认背景改为「深=紫蓝 / 浅=白→粉紫」渐变。
    //   原值:平面 systemBackgroundColor(深黑/浅白,与 E 稿不符)
    //   新值:AmeGradientBackgroundView(随 traitCollection 自动切换深浅)
    AmeGradientBackgroundView *defaultBackgroundView =
        [[AmeGradientBackgroundView alloc] initWithFrame:container.bounds];
    defaultBackgroundView.tag = kDefaultBackgroundTag;
    [container addSubview:defaultBackgroundView];
}

- (void)applyImageBackgroundToContainer:(UIView *)container {
    if (!self.currentBackgroundPath) return;
    
    UIImage *image = [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    if (!image) return;
    
    // Remove existing
    UIView *existing = [container viewWithTag:kBackgroundImageTag];
    if (existing) [existing removeFromSuperview];
    
    // Image view
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.tag = kBackgroundImageTag;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.frame = container.bounds;
    
    [container addSubview:imageView];
    
    // Add blur effect for UI readability
    [self addBlurEffectToContainer:container];
}

- (void)applyVideoBackgroundToContainer:(UIView *)container {
    if (!self.currentBackgroundPath) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:self.currentBackgroundPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) return;
    
    [self cleanupVideoPlayer];
    
    // Create player
    self.videoPlayer = [AVPlayer playerWithURL:videoURL];
    self.videoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.videoPlayer.muted = YES; // Mute to avoid interrupting other audio
    
    // Create player layer
    self.videoPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:self.videoPlayer];
    self.videoPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.videoPlayerLayer.frame = container.bounds;
    
    // Insert at bottom
    [container.layer insertSublayer:self.videoPlayerLayer atIndex:0];
    
    // Add blur effect
    [self addBlurEffectToContainer:container];
    
    // Start playing
    [self.videoPlayer play];
}

- (void)addBlurEffectToContainer:(UIView *)container {
    // Remove existing blur
    UIView *existingBlur = [container viewWithTag:kBackgroundBlurTag];
    if (existingBlur) [existingBlur removeFromSuperview];

    UIView *existingDim = [container viewWithTag:kBackgroundDimTag];
    if (existingDim) [existingDim removeFromSuperview];

    // 修复：使用 SystemThinMaterial（自适应浅色/深色，且较通透）替代硬编码 Dark。
    // 之前使用 UIBlurEffectStyleDark + 黑色 dim view 叠加，导致：
    // 1. 浅色模式下背景图被完全压暗成"中间一片黑"
    // 2. 左右侧栏完全不透明，背景图透不出来
    // SystemThinMaterial 会在浅色模式呈浅色毛玻璃、深色模式呈深色毛玻璃，
    // 且透明度适中，背景图可见。
    UIBlurEffect *blurEffect;
    if (@available(iOS 13.0, *)) {
        blurEffect = AmeGlassEffect(UIBlurEffectStyleSystemThinMaterial);   // ★ 液态玻璃(iOS 26+)/ 旧系统回退
    } else {
        blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    }
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.tag = kBackgroundBlurTag;
    blurView.alpha = self.blurIntensity * 0.5; // max 0.5 for readability
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.frame = container.bounds;

    [container addSubview:blurView];

    // 修复：dim view 改为自适应颜色而非纯黑，避免浅色模式下过度压暗
    UIView *dimView = [[UIView alloc] initWithFrame:container.bounds];
    dimView.tag = kBackgroundDimTag;
    if (@available(iOS 13.0, *)) {
        dimView.backgroundColor = [UIColor labelColor];
    } else {
        dimView.backgroundColor = [UIColor blackColor];
    }
    dimView.alpha = self.blurIntensity * 0.2; // 降低到 0.2，避免过度压暗
    dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [container addSubview:dimView];
}

#pragma mark - Transparency Helpers with UI Effect Support

- (void)makeViewControllerTransparent:(UIViewController *)viewController {
    if (!viewController) return;
    
    // Main view - apply effect based on settings
    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - clear background, let blur show through
        viewController.view.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果 - semi-transparent background
        // 修复：使用 systemBackgroundColor 替代硬编码黑色，自适应浅色/深色模式
        if (@available(iOS 13.0, *)) {
            UIColor *base = [UIColor systemBackgroundColor];
            viewController.view.backgroundColor = [base colorWithAlphaComponent:1.0 - self.uiOpacity];
        } else {
            viewController.view.backgroundColor = [UIColor colorWithWhite:0 alpha:1.0 - self.uiOpacity];
        }
    }
    
    // For UITableViewController
    if ([viewController isKindOfClass:[UITableViewController class]]) {
        UITableViewController *tableVC = (UITableViewController *)viewController;
        tableVC.tableView.backgroundColor = [UIColor clearColor];
        tableVC.tableView.backgroundView = nil;
        
        // Make cells semi-transparent or with blur effect
        tableVC.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        
        // Apply to all visible cells
        for (UITableViewCell *cell in tableVC.tableView.visibleCells) {
            [self applyEffectToCell:cell];
        }
    }
    
    // For UICollectionViewController
    if ([viewController isKindOfClass:[UICollectionViewController class]]) {
        UICollectionViewController *collectionVC = (UICollectionViewController *)viewController;
        collectionVC.collectionView.backgroundColor = [UIColor clearColor];
    }
    
    // Child view controllers
    for (UIViewController *childVC in viewController.childViewControllers) {
        [self makeViewControllerTransparent:childVC];
    }
}

- (void)applyEffectToCell:(UITableViewCell *)cell {
    if (cell == nil) { return; }
    // ★ [RIM-STATE] 列表行不叠高光(见下面 [NO-RIM])——但行会被复用、也可能带着历史图层 ⇒
    //   每次应用都【无条件先摘一次】,保证「原生 / 关高光」下行上没有任何高光残留
    //   (用户实测:从玻璃切到原生后,设置页会残留一点小高光)。
    AmeDetachGlassRim(cell);

    // ★ [GLASS-BG] 无自定义背景 ⇒ 列表行给原生实底(不再叠"无底毛玻璃"),避免"整片列表透明"。
    //   (有壁纸时保持下面的毛玻璃/半透明,壁纸透出。)
    if (![self hasBackground]) {
        for (UIView *subview in [cell.contentView.superview.subviews copy]) {
            if ([subview isKindOfClass:[UIVisualEffectView class]]) {
                [subview removeFromSuperview];
            }
        }
        CGFloat ameRowRadius = (cell.layer.cornerRadius > 0.0) ? cell.layer.cornerRadius : 12.0;
        cell.backgroundView = nil;
        cell.backgroundColor = [UIColor clearColor];
        cell.layer.cornerRadius = ameRowRadius;
        cell.layer.cornerCurve = kCACornerCurveContinuous;
        cell.layer.masksToBounds = YES;
        cell.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];   // ★ [GLASS-BG] 行实底
        cell.contentView.layer.cornerRadius = ameRowRadius;
        cell.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.contentView.layer.masksToBounds = YES;
        return;
    }

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - use UIBlurEffect on cell background
        if (@available(iOS 13.0, *)) {
            UIVisualEffect *blur = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);   // ★ 列表行玻璃
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.frame = cell.bounds;
            // ★ [E3] SPEC §2:玻璃底 + blur 26 / saturate 180%
            //   ★ [GLASS-STYLE] 底填充按风格(液体=白填充;原生=不加,系统材质原样)
            AmeApplyGlassFillForCurrentStyle(blurView);
            AmeTuneGlassBackdrop(blurView, AmeGlassBlurRadius, AmeGlassSaturate);   // 内部按风格短路
            // ★ [NO-RIM] 列表行不再刷高光(用户反馈:设置页 / 实例子目录不要这个描边)
            //   主界面卡片的 rim 仍在 applyEffectToView: 里保留。
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

            // Remove old background views
            for (UIView *subview in cell.contentView.superview.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview != blurView) {
                    [subview removeFromSuperview];
                }
            }

            // ★ [ROUND-ROW] 选项行改圆角(设置页/实例子目录的选项)
            CGFloat rowRadius = 12.0;
            blurView.layer.cornerRadius = rowRadius;
            blurView.layer.masksToBounds = YES;
            cell.layer.cornerRadius = rowRadius;
            cell.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
            cell.layer.masksToBounds = YES;
            cell.backgroundView = blurView;
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果 - simple semi-transparent background
        // 修复：使用 secondarySystemBackgroundColor 替代硬编码 0.1 黑色
        if (@available(iOS 13.0, *)) {
            cell.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.backgroundView = nil;
        // ★ [ROUND-ROW] 半透明模式下行也圆角(与毛玻璃模式一致)
        cell.layer.cornerRadius = 12.0;
        cell.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
        cell.layer.masksToBounds = YES;
    }
}

- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC {
    if (!splitVC) return;
    
    // Make split view itself transparent
    splitVC.view.backgroundColor = [UIColor clearColor];
    
    // Make all view controllers transparent
    for (UIViewController *vc in splitVC.viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vc;
            
            // Navigation controller setup
            nav.view.backgroundColor = [UIColor clearColor];
            nav.navigationBar.translucent = YES;
            nav.toolbar.translucent = YES;
            
            // Apply effect to navigation bar
            [self applyEffectToNavigationBar:nav.navigationBar];
            [self applyEffectToToolbar:nav.toolbar];
            
            // Make all view controllers in stack transparent
            for (UIViewController *childVC in nav.viewControllers) {
                [self makeViewControllerTransparent:childVC];
            }
        } else {
            [self makeViewControllerTransparent:vc];
        }
    }
}

- (void)applyEffectToNavigationBar:(UINavigationBar *)navigationBar {
    // 关键修复（UI 累积异常 + 小白条根治）：
    // 1. 之前每次调用都重建 UINavigationBarAppearance，iOS 内部会重新生成 hairline
    //    UIImageView，累积后表现为"上方一行小白条"。现改为静态单例 Appearance，
    //    同一种效果只构建一次，避免反复触发 iOS 内部 hairline view 重建。
    // 2. 之前清理 hairline 只遍历 navigationBar.subviews（直接子视图），但 iOS 的
    //    hairline 常嵌在 _UINavigationBarBackground / _UIBarBackground 等私有子视图
    //    内部。改为递归遍历所有后代视图，彻底清理累积的 hairline。
    static UIImage *emptyImage = nil;
    static UINavigationBarAppearance *blurAppearance = nil;
    static UINavigationBarAppearance *translucentAppearance = nil;
    static UIColor *translucentBarColor = nil;
    static NSInteger blurAppearanceStyle = -1;   // ★ [GLASS-STYLE] 毛玻璃 Appearance 对应的界面风格
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyImage = [UIImage new];
        // 半透明 Appearance 在首次调用时按当前 uiOpacity 构建（见下方懒加载）
    });

    // ★ [GLASS-STYLE] 毛玻璃 Appearance 按【界面风格】缓存:风格变了就重建一次
    //   (原生 ⇒ 系统常规材质;液态 ⇒ 系统 UIGlassEffect)。既让切风格后导航栏立刻跟上,
    //   又保留「同一风格只构建一次」的原意(避免反复重建触发 iOS 内部 hairline 累积)。
    NSInteger curAmeNavStyle = (NSInteger)AMEGlassStyleResolved();
    if (blurAppearance == nil || blurAppearanceStyle != curAmeNavStyle) {
        blurAppearance = [[UINavigationBarAppearance alloc] init];
        [blurAppearance configureWithTransparentBackground];
        blurAppearance.backgroundColor = [UIColor clearColor];
        blurAppearance.backgroundEffect = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);   // ★ 导航栏玻璃(按风格)
        blurAppearance.shadowColor = nil;
        blurAppearance.shadowImage = emptyImage;
        blurAppearanceStyle = curAmeNavStyle;
    }

    // 递归清理 iOS 内部累积的 hairline UIImageView（高度极小的分割线视图）
    // hairline 常嵌在 _UINavigationBarBackground / _UIBarBackground 等私有子视图内部
    //
    // 关键修复（Card/Root 布局进入所有页闪退加固）：
    //   block 内引用自身（removeHairlines(sub)）必须用 __block 限定符，否则
    //   捕获的是 nil（block 字面量赋值还未完成时的栈帧值），递归调用是 no-op，
    //   只会处理 navigationBar 的直接子视图，无法清理 _UIBarBackground 内层的 hairline。
    //   累积的 hairline 在 setContentViewController 反复切换时会触发私有子视图
    //   layout 解算异常，导致 EXC_BAD_ACCESS（不被 NSUncaughtExceptionHandler 捕获）。
    __block void (^removeHairlines)(UIView *) = ^(UIView *view) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.bounds.size.height > 0 &&
                sub.bounds.size.height <= 2.0) {
                [sub removeFromSuperview];
            } else {
                removeHairlines(sub);
            }
        }
    };
    removeHairlines(navigationBar);

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - 复用静态单例
        if (@available(iOS 13.0, *)) {
            navigationBar.standardAppearance = blurAppearance;
            navigationBar.scrollEdgeAppearance = blurAppearance;
            navigationBar.compactAppearance = blurAppearance;
        }
        navigationBar.barTintColor = [UIColor clearColor];
        navigationBar.backgroundColor = [UIColor clearColor];
        navigationBar.shadowImage = emptyImage;
    } else {
        // 半透明效果
        if (@available(iOS 13.0, *)) {
            UIColor *barColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
            navigationBar.barTintColor = barColor;
            navigationBar.backgroundColor = barColor;
            // 半透明 Appearance 需要按当前 uiOpacity 构建（uiOpacity 可变，无法像 blur 一样全局单例）
            // 但同一 uiOpacity 下复用同一实例，避免反复重建
            if (!translucentAppearance || ![translucentBarColor isEqual:barColor]) {
                UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundColor = barColor;
                appearance.backgroundEffect = nil;
                appearance.shadowColor = nil;
                appearance.shadowImage = emptyImage;
                translucentAppearance = appearance;
                translucentBarColor = barColor;
            }
            navigationBar.standardAppearance = translucentAppearance;
            navigationBar.scrollEdgeAppearance = translucentAppearance;
            navigationBar.compactAppearance = translucentAppearance;
        } else {
            navigationBar.barTintColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            navigationBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        navigationBar.shadowImage = emptyImage;
    }
}

- (void)applyEffectToToolbar:(UIToolbar *)toolbar {
    // 关键修复（同 applyEffectToNavigationBar:）：静态单例 Appearance + 递归清理 hairline
    static UIImage *emptyImage = nil;
    static UIToolbarAppearance *blurToolbarAppearance = nil;
    static UIToolbarAppearance *translucentToolbarAppearance = nil;
    static UIColor *translucentToolbarColor = nil;
    static NSInteger blurToolbarAppearanceStyle = -1;   // ★ [GLASS-STYLE] 同导航栏
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyImage = [UIImage new];
    });
    // ★ [GLASS-STYLE] 工具栏毛玻璃 Appearance 同样按界面风格缓存重建(见 applyEffectToNavigationBar:)
    NSInteger curAmeBarStyle = (NSInteger)AMEGlassStyleResolved();
    if (blurToolbarAppearance == nil || blurToolbarAppearanceStyle != curAmeBarStyle) {
        blurToolbarAppearance = [[UIToolbarAppearance alloc] init];
        [blurToolbarAppearance configureWithTransparentBackground];
        blurToolbarAppearance.backgroundColor = [UIColor clearColor];
        blurToolbarAppearance.backgroundEffect = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);   // ★ 工具栏玻璃(按风格)
        blurToolbarAppearance.shadowColor = nil;
        blurToolbarAppearance.shadowImage = emptyImage;
        blurToolbarAppearanceStyle = curAmeBarStyle;
    }

    // 递归清理累积的 hairline UIImageView
    // 关键修复：同 applyEffectToNavigationBar:，block 内引用自身必须用 __block
    // 限定符，否则递归调用是 no-op，无法清理 _UIBarBackground 内层的 hairline。
    __block void (^removeHairlines)(UIView *) = ^(UIView *view) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.bounds.size.height > 0 &&
                sub.bounds.size.height <= 2.0) {
                [sub removeFromSuperview];
            } else {
                removeHairlines(sub);
            }
        }
    };
    removeHairlines(toolbar);

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - 复用静态单例
        if (@available(iOS 13.0, *)) {
            toolbar.standardAppearance = blurToolbarAppearance;
            // ★ [API-GUARD] UIToolbar.scrollEdgeAppearance 是 iOS 15+ 才有的属性
            //   （UINavigationBar.scrollEdgeAppearance 的 iOS 13 就有 ⇒ 易被上面 @available(iOS 13.0) 误放行）。
            //   老系统（iOS 14）直接赋值 ⇒ unrecognized selector 闪退。双重守门：版本 + respondsToSelector。
            if (@available(iOS 15.0, *)) {
                if ([toolbar respondsToSelector:@selector(setScrollEdgeAppearance:)]) {
                    toolbar.scrollEdgeAppearance = blurToolbarAppearance;
                }
            }
            toolbar.compactAppearance = blurToolbarAppearance;
        }
        toolbar.barTintColor = [UIColor clearColor];
        toolbar.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果
        if (@available(iOS 13.0, *)) {
            UIColor *barColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
            toolbar.barTintColor = barColor;
            toolbar.backgroundColor = barColor;
            if (!translucentToolbarAppearance || ![translucentToolbarColor isEqual:barColor]) {
                UIToolbarAppearance *appearance = [[UIToolbarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundColor = barColor;
                appearance.backgroundEffect = nil;
                appearance.shadowColor = nil;
                appearance.shadowImage = emptyImage;
                translucentToolbarAppearance = appearance;
                translucentToolbarColor = barColor;
            }
            toolbar.standardAppearance = translucentToolbarAppearance;
            // ★ [API-GUARD] 同上一处：UIToolbar.scrollEdgeAppearance 仅 iOS 15+（老系统赋值 = 闪退）。
            if (@available(iOS 15.0, *)) {
                if ([toolbar respondsToSelector:@selector(setScrollEdgeAppearance:)]) {
                    toolbar.scrollEdgeAppearance = translucentToolbarAppearance;
                }
            }
            toolbar.compactAppearance = translucentToolbarAppearance;
        } else {
            toolbar.barTintColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            toolbar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
    }
}

- (void)refreshUIEffect {
    if (self.currentSplitVC && self.currentType != BackgroundTypeNone) {
        [self makeSplitViewControllerTransparent:self.currentSplitVC];
    }
    
    // Re-apply blur intensity to background container
    if (self.globalBackgroundContainer) {
        [self addBlurEffectToContainer:self.globalBackgroundContainer];
    }
    
    // Post notification for other views to refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
}

#pragma mark - Unified View Effect Application

- (void)applyEffectToView:(UIView *)view {
    if (!view) return;

    // ★ [GLASS-BG] 无自定义背景 ⇒ 原生实底(对照上游 Prisma 的"原生外观"口径)。
    //   旧管线无论有无壁纸都铺一层【无底的毛玻璃】:
    //     · applyEffectToView: 把宿主 `backgroundColor = clearColor`,只挂 UIVisualEffectView;
    //     · GLASS-LIQUID 之后 `AmeApplyGlassFillForCurrentStyle` 在系统材质路径又【不给任何填充】;
    //     · 无壁纸时系统材质(ThinMaterial / iOS26 UIGlassEffect Regular)本身极通透 ⇒
    //       宿主下方(默认渐变底 / 纯色)整片透出 ⇒ 用户报的「很多背景都是透明的 / 切回原生还透明」。
    //   修复:没有壁纸可透出时,面板/卡片/整页一律给【不透明系统底】,不再叠"无底的毛玻璃"。
    //   (有壁纸时保持下面的毛玻璃/半透明,壁纸正常透出 —— 与上游同口径。)
    if (![self hasBackground]) {
        NSLog(@"[glass] applyEffectToView: [GLASS-BG] 无自定义背景 ⇒ 原生实底 on %@ (radius=%.1f)",
              NSStringFromClass(view.class), (double)view.layer.cornerRadius);
        for (UIView *subview in [view.subviews copy]) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }
        AmeDetachGlassRim(view);
        CGFloat ameSolidRadius = view.layer.cornerRadius;
        if (ameSolidRadius > 0.0) {
            view.backgroundColor = [UIColor secondarySystemBackgroundColor];   // 卡片 / 面板:原生卡面实底
        } else {
            view.backgroundColor = [UIColor systemBackgroundColor];           // 整页:原生页面底色
        }
        return;
    }

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // ★ [GLASS-LIQUID] 明确区分两条路:系统材质(默认)vs 自绘叠加(仅用户显式打开)。
        //   旧日志 "BLUR path" 会被误读成"还在纯代码画玻璃" ⇒ 按当前风格如实汇报。
        //   · 系统材质:iOS≥26 ⇒ 系统 UIGlassEffect;iOS<26 ⇒ 系统 UIBlurEffect 常规材质。都不自绘。
        BOOL ameSystemMaterial = AMEGlassStyleUsesSystemMaterial();
        NSLog(@"[glass] applyEffectToView: %@ on %@ (blur=%.1f sat=%.2f intensity=%.2f hasBg=%d)",
              ameSystemMaterial ? @"SYSTEM-material path(系统材质,不自绘)"
                                : @"HAND-DRAWN overlay path(显式自绘叠加)",
              NSStringFromClass(view.class), (double)AmeGlassBlurRadius, (double)AmeGlassSaturate,
              (double)self.blurIntensity, (int)[self hasBackground]);
        // 毛玻璃效果 - 创建 UIVisualEffectView 作为子视图
        // 先移除已有的 blur view
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }

        // 修复：使用 SystemThinMaterial 替代 SystemMaterialDark，使左右侧栏
        // 在浅色/深色模式下都自适应，且足够通透让背景图透出。
        // SystemMaterialDark 过于不透明，导致"左右两边完全不透明"。
        // ★ 真玻璃可用就用真玻璃(iOS 26 设备),否则系统材质 + 下面加的高光边
        UIVisualEffect *blur = AmeGlassEffect(UIBlurEffectStyleSystemThinMaterial);
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.tag = kBackgroundBlurTag;
        blurView.frame = view.bounds;
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.layer.cornerRadius = view.layer.cornerRadius;
        blurView.layer.masksToBounds = YES;

        // 参照 ZL2 双层透明度控制：
        // 1. blurIntensity 控制毛玻璃本身的模糊强度（0.3~1.0 范围，避免过低完全透明）
        // 2. 有自定义背景时降低不透明度让背景透出，无背景时保持较高不透明度
        // 这样实现了 ZL2 的 influencedByBackgroundColor 效果：
        // 有背景图/视频时卡片更通透，无背景时卡片更不透明（与系统默认一致）
        CGFloat effectiveAlpha = 0.3 + (self.blurIntensity * 0.7);  // 0.3~1.0
        if (![self hasBackground]) {
            // 无自定义背景时，提高不透明度，使 UI 更清晰
            effectiveAlpha = MIN(effectiveAlpha + 0.2, 1.0);
        }
        blurView.alpha = effectiveAlpha;

        // 毛玻璃本身不响应触摸，让事件穿透到宿主视图（如 UIControl 卡片）。
        // 否则 blurView 会拦截 touch，导致 AccountLoginViewController 的登录卡片
        // 点击无反应（UIControlEventTouchUpInside 永远不触发）。
        blurView.userInteractionEnabled = NO;

        [view insertSubview:blurView atIndex:0];
        view.backgroundColor = [UIColor clearColor];
        // ★ [E3] SPEC §2 设计令牌:玻璃底填充(glass 深.10/浅.55)+ blur 26 / saturate 180%
        //   ★ [GLASS-STYLE] 底填充与私有 backdrop 调参按风格(液体=做;原生=不做)
        AmeApplyGlassFillForCurrentStyle(blurView);
        AmeTuneGlassBackdrop(blurView, AmeGlassBlurRadius, AmeGlassSaturate);
        // ★ 玻璃质感:高光描边 + 上缘内高光(不依赖 iOS 26 SDK)
        // ★ [RIM-UI] 按用户开关/强度刷高光;先摘旧图层,再按新强度重刷
        // ★ [GLASS-STYLE] 强度按当前风格收敛(原生风格 ⇒ 恒 0,下面的 rim 助手随即短路为 no-op)
        [self ameSyncGlassRimStrengthForCurrentStyle];
        AmeDetachGlassRim(view);
        AmeAttachGlassRim(view, view.layer.cornerRadius);
        // ★ [UI-B] 修复(2026-10-02):AmeRefreshGlassRim 全工程原本 0 个调用者
        //   ⇒ 高光 CAGradientLayer 的 frame 恒为 (0,0,0,0) ⇒ 上缘高光从来没画出来过。
        dispatch_async(dispatch_get_main_queue(), ^{
            AmeRefreshGlassRim(view);
            [self ameRefreshRimsRecursive:view];
        });
    } else {
        NSLog(@"[glass] applyEffectToView: TRANSLUCENT path on %@ (uiEffect=%ld)",
              NSStringFromClass(view.class), (long)self.uiEffect);
        // 半透明效果 - 移除 blur view，使用半透明背景
        // 修复：使用 systemBackgroundColor 替代硬编码深灰，自适应浅色/深色模式
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }
        if (@available(iOS 13.0, *)) {
            // 使用 secondarySystemBackgroundColor 作为半透明基底，再叠加 alpha
            // 参照 ZL2 双层透明度控制：有背景时降低不透明度让背景透出
            CGFloat effectiveOpacity = self.uiOpacity;
            if (![self hasBackground]) {
                // 无自定义背景时，提高不透明度，使 UI 更清晰
                effectiveOpacity = MIN(effectiveOpacity + 0.3, 1.0);
            }
            UIColor *base = [UIColor secondarySystemBackgroundColor];
            view.backgroundColor = [base colorWithAlphaComponent:effectiveOpacity];
        } else {
            view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:self.uiOpacity];
        }
    }
}

- (void)applyEffectToCollectionViewCell:(UICollectionViewCell *)cell {
    if (!cell) return;

    // ★ [CORNER-FIX] 有效圆角:contentView 没设圆角时,回退到「第一个带圆角的内层卡片容器」。
    //   原先只取 cell.contentView.layer.cornerRadius ⇒ 对「圆角挂在【内层容器】上、contentView
    //   本身为 0」的 cell(实例页 VMTileBaseCell 一族)注入的 blur 圆角为 0 且铺满整个 cell
    //   ⇒ 圆角卡片外沿露出一圈方角(用户实测:「长方形的尖尖角没有消掉」)。
    //   统一做法:把有效圆角也落到 contentView 并裁剪,blur 与它同值 ⇒ 圆角外沿不再有方角。
    CGFloat ameEffectiveRadius = cell.contentView.layer.cornerRadius;
    if (ameEffectiveRadius <= 0.0) {
        for (UIView *ameSub in cell.contentView.subviews) {
            if (ameSub.layer.cornerRadius > 0.0) { ameEffectiveRadius = ameSub.layer.cornerRadius; break; }
        }
    }
    if (ameEffectiveRadius > 0.0) {
        cell.contentView.layer.cornerRadius = ameEffectiveRadius;
        cell.contentView.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 与系统卡片一致
        cell.contentView.layer.masksToBounds = YES;
    }

    // ★ [GLASS-BG] 无自定义背景 ⇒ 集合卡片给原生实底(不再叠"无底毛玻璃"),
    //   根治主页便当盒卡 / 实例卡 / 新闻卡 / 公告卡在无壁纸时整片透明。
    if (![self hasBackground]) {
        NSLog(@"[glass] applyEffectToCollectionViewCell: [GLASS-BG] 无自定义背景 ⇒ 卡片实底 (radius=%.1f)",
              (double)ameEffectiveRadius);
        for (UIView *subview in [cell.contentView.subviews copy]) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        return;
    }

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }

        // ★ [GLASS-LIQUID] 别绕过风格层:iOS≥26 必须走系统 UIGlassEffect(旧代码直接 UIBlurEffect)。
        UIVisualEffect *blur = AmeGlassEffect(UIBlurEffectStyleSystemMaterial);
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.tag = kBackgroundBlurTag;
        blurView.frame = cell.contentView.bounds;
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.layer.cornerRadius = ameEffectiveRadius;   // ★ [CORNER-FIX] 用有效圆角(见方法开头)
        blurView.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 与系统卡片一致
        blurView.layer.masksToBounds = YES;
        // ★ [E3] SPEC §2.5:blur 26 / saturate 180%(尽力落到系统材质,失败回退默认并打日志)
        AmeTuneGlassBackdrop(blurView, AmeGlassBlurRadius, AmeGlassSaturate);

        [cell.contentView insertSubview:blurView atIndex:0];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                [subview removeFromSuperview];
            }
        }
        // 修复：使用 secondarySystemBackgroundColor 替代硬编码 0.1 黑色
        if (@available(iOS 13.0, *)) {
            cell.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
    }
}

- (void)applyEffectToSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;

    // 1. searchBar 整体背景透明，让底层自定义启动器背景透出
    //    UISearchBar 默认是不透明的 systemBackgroundColor，会遮挡全局背景图/毛玻璃
    searchBar.barTintColor = [UIColor clearColor];
    searchBar.backgroundColor = [UIColor clearColor];
    searchBar.translucent = YES;
    // Minimal 样式让系统不绘制不透明背景，仅保留输入框背景
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // 移除系统自动添加的 _UISearchBarBackground 不透明背景视图
    for (UIView *sub in searchBar.subviews) {
        for (UIView *inner in sub.subviews) {
            if ([NSStringFromClass(inner.class) containsString:@"Background"]) {
                inner.backgroundColor = [UIColor clearColor];
                inner.hidden = NO;
            }
        }
        if ([NSStringFromClass(sub.class) containsString:@"Background"]) {
            sub.backgroundColor = [UIColor clearColor];
        }
    }

    // 2. 透明化内部 UITextField（搜索输入框）背景
    //    UITextField 默认带 systemFillColor 浅灰色背景，遮挡自定义背景
    UITextField *textField = nil;
    for (UIView *sub in searchBar.subviews) {
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[UITextField class]]) {
                textField = (UITextField *)inner;
                break;
            }
        }
        if (textField) break;
    }
    // iOS 13+ 可直接用 -searchTextField
    if (!textField && [searchBar respondsToSelector:@selector(searchTextField)]) {
        @try {
            textField = [searchBar performSelector:@selector(searchTextField)];
        } @catch (NSException *e) {
            textField = nil;
        }
    }
    if (textField) {
        if (self.uiEffect == BackgroundUIEffectBlur) {
            // 毛玻璃：输入框背景设为浅色半透明，保证文字可读且不挡背景
            if (@available(iOS 13.0, *)) {
                textField.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.5];
            } else {
                textField.backgroundColor = [UIColor colorWithWhite:0.95 alpha:0.5];
            }
        } else {
            // 半透明效果：输入框背景按 uiOpacity 调整
            if (@available(iOS 13.0, *)) {
                textField.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:MAX(0.3, self.uiOpacity)];
            } else {
                textField.backgroundColor = [UIColor colorWithWhite:0.95 alpha:MAX(0.3, self.uiOpacity)];
            }
        }
    }
}

#pragma mark - Legacy Methods

- (void)applyBackgroundToView:(UIView *)view {
    // Find the view controller or window
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UISplitViewController class]]) {
            [self applyBackgroundToSplitViewController:(UISplitViewController *)responder];
            return;
        }
        if ([responder isKindOfClass:[UIWindow class]]) {
            [self applyBackgroundToWindow:(UIWindow *)responder];
            return;
        }
        responder = responder.nextResponder;
    }
}

- (void)removeBackgroundFromView:(UIView *)view {
    [self removeGlobalBackground];
}

#pragma mark - Video Management

- (void)cleanupVideoPlayer {
    if (self.videoPlayer) {
        [self.videoPlayer pause];
        self.videoPlayer = nil;
    }
    if (self.videoPlayerLayer) {
        [self.videoPlayerLayer removeFromSuperlayer];
        self.videoPlayerLayer = nil;
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *playerItem = notification.object;
    [playerItem seekToTime:kCMTimeZero completionHandler:nil];
}

#pragma mark - App Lifecycle

- (void)appDidEnterBackground {
    [self pauseVideo];
}

- (void)appWillEnterForeground {
    [self resumeVideo];
}

- (void)pauseVideo {
    if (self.videoPlayer) [self.videoPlayer pause];
}

- (void)resumeVideo {
    if (self.videoPlayer && self.currentType == BackgroundTypeVideo) {
        [self.videoPlayer play];
    }
}

#pragma mark - Set Background

- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!image) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_48", nil)}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing
        [self clearBackgroundInternal];
        
        // Save image
        NSString *fileName = [NSString stringWithFormat:@"background_image_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSData *imageData = UIImageJPEGRepresentation(image, 0.85);
        if (!imageData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_49", nil)}]);
            });
            return;
        }
        
        BOOL saved = [imageData writeToFile:filePath atomically:YES];
        
        if (saved) {
            self.currentType = BackgroundTypeImage;
            self.currentBackgroundPath = filePath;
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Reapply if needed
                if (self.currentSplitVC) {
                    [self applyBackgroundToSplitViewController:self.currentSplitVC];
                } else if (self.currentWindow) {
                    [self applyBackgroundToWindow:self.currentWindow];
                }
                // ★ [BG-CONTRAST] 背景变了 ⇒ 作废亮度缓存 + 广播(各页重刷自适应前景)
                [self ame_invalidateForegroundContrast];
                if (completion) completion(YES, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_50", nil)}]);
            });
        }
    });
}

- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!videoURL) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_51", nil)}]);
        }
        return;
    }
    // ★ [ISSUE-FIX] #92：从「文件」App（UIDocumentPickerViewController）选出的视频是
    //   security-scoped URL，未 startAccessingSecurityScopedResource 时
    //   fileExistsAtPath: / copyItemAtURL: 都会失败 ⇒ 用户看到「视频文件不存在」
    //   （i18n_str_51）。这里在读取/复制期间持有安全作用域，复制完成后立即释放；
    //   相册(UIImagePickerController)返回的临时 URL 无作用域：start 返回 NO，无需释放。
    BOOL ame92Scoped = videoURL.isFileURL ? [videoURL startAccessingSecurityScopedResource] : NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) {
        if (ame92Scoped) [videoURL stopAccessingSecurityScopedResource];
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_51", nil)}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing
        [self clearBackgroundInternal];
        
        // Copy video
        NSString *fileName = [NSString stringWithFormat:@"background_video_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSError *copyError = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:filePath] error:&copyError];
        // ★ [ISSUE-FIX] #92：复制完成，安全作用域即可释放（后续只操作已复制到沙盒的副本）。
        if (ame92Scoped) [videoURL stopAccessingSecurityScopedResource];
        
        if (copied) {
            self.currentType = BackgroundTypeVideo;
            self.currentBackgroundPath = filePath;
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Reapply if needed
                if (self.currentSplitVC) {
                    [self applyBackgroundToSplitViewController:self.currentSplitVC];
                } else if (self.currentWindow) {
                    [self applyBackgroundToWindow:self.currentWindow];
                }
                // ★ [BG-CONTRAST] 背景变了 ⇒ 作废亮度缓存 + 广播(各页重刷自适应前景)
                [self ame_invalidateForegroundContrast];
                if (completion) completion(YES, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, copyError ?: [NSError errorWithDomain:@"BackgroundManager" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_52", nil)}]);
            });
        }
    });
}

- (void)clearBackground {
    [self clearBackgroundInternal];
    [self removeGlobalBackground];
    [self saveBackgroundSettings];
    // ★ [BG-CONTRAST] 清背景 ⇒ 作废亮度缓存 + 广播(前景回到语义色 = 与改造前一致)
    [self ame_invalidateForegroundContrast];
}

- (void)clearBackgroundInternal {
    [self cleanupVideoPlayer];
    
    if (self.currentBackgroundPath) {
        [[NSFileManager defaultManager] removeItemAtPath:self.currentBackgroundPath error:nil];
    }
    
    self.currentType = BackgroundTypeNone;
    self.currentBackgroundPath = nil;
}

#pragma mark - Check Background

- (BOOL)hasBackground {
    return self.currentType != BackgroundTypeNone && self.currentBackgroundPath != nil;
}

- (BOOL)hasImageBackground {
    return self.currentType == BackgroundTypeImage && self.currentBackgroundPath != nil;
}

- (BOOL)hasVideoBackground {
    return self.currentType == BackgroundTypeVideo && self.currentBackgroundPath != nil;
}

#pragma mark - Preview

- (nullable UIImage *)backgroundPreview {
    if (self.currentType == BackgroundTypeImage && self.currentBackgroundPath) {
        return [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    }
    return nil;
}

#pragma mark - ★ [BG-CONTRAST] 自适应前景色 / 可读性(单一真相源)

// 8×8 区块 → 每块 Rec.709 平均亮度 → 取【中位数】。中位数对"一颗亮 logo / 一条暗边"这类
// 局部极值不敏感,比"整图平均"更稳 ⇒ 不会出现同一页"半亮半不亮"的乱态。min/max 仅作诊断。
- (CGFloat)ame_luminanceFromImage:(UIImage *)image {
    if (!image) return -1.0;
    CGImageRef cg = image.CGImage;
    if (cg == NULL) return -1.0;
    const NSInteger N = 8;
    const size_t bytesPerRow = (size_t)N * 4;
    unsigned char *buf = (unsigned char *)calloc((size_t)N * (size_t)N * 4, 1);
    if (buf == NULL) return -1.0;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, N, N, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx == NULL) { free(buf); return -1.0; }
    // 先铺黑:透明像素按黑算(与"看不清"一致),避免被当白
    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, N, N));
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(ctx);

    CGFloat lumas[64];
    const NSInteger count = N * N;
    for (NSInteger i = 0; i < count; i++) {
        CGFloat r = buf[i * 4 + 0] / 255.0;
        CGFloat g = buf[i * 4 + 1] / 255.0;
        CGFloat b = buf[i * 4 + 2] / 255.0;
        lumas[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }
    free(buf);

    for (NSInteger i = 1; i < count; i++) {          // 插入排序(count=64,可忽略)
        CGFloat key = lumas[i];
        NSInteger j = i - 1;
        while (j >= 0 && lumas[j] > key) { lumas[j + 1] = lumas[j]; j--; }
        lumas[j + 1] = key;
    }
    self.ameLumaMin = lumas[0];
    self.ameLumaMax = lumas[count - 1];
    return lumas[count / 2];
}

- (void)ame_storeLuma:(CGFloat)luma path:(NSString *)path mtime:(NSTimeInterval)mtime {
    self.ameCachedLuma = luma;
    self.ameLumaPath = path;
    self.ameLumaMtime = mtime;
    self.ameLumaComputed = YES;
}

// 背景变化 ⇒ 丢掉缓存并把"要重刷前景色"广播出去(各页 observer 重取 AMEForegroundColor)
- (void)ame_invalidateForegroundContrast {
    self.ameLumaComputed = NO;
    self.ameCachedLuma = -1.0;
    self.ameLumaPath = nil;
    self.ameVideoLumaPending = NO;
    (void)[self representativeBackgroundLuminance];   // 立即重算一次(图片同步;视频转异步)
    NSLog(@"[bg-contrast] 背景已刷新 · %@", [self foregroundDiagnostics]);
    [[NSNotificationCenter defaultCenter] postNotificationName:AMEForegroundContrastChangedNotification object:nil];
}

// 视频:首帧异步取一次(不阻塞主线程);取到前返回 -1(未知 ⇒ 走现状语义色,绝不会闪成错色)
- (void)ame_computeVideoLumaAsync:(NSString *)path mtime:(NSTimeInterval)mtime {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:path]];
        AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(64, 64);
        NSError *err = nil;
        CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(0.5, 600) actualTime:NULL error:&err];
        CGFloat luma = -1.0;
        if (cg != NULL) {
            UIImage *img = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
            luma = [self ame_luminanceFromImage:img];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ameVideoLumaPending = NO;
            if (luma >= 0.0) {
                [self ame_storeLuma:luma path:path mtime:mtime];
                [[NSNotificationCenter defaultCenter] postNotificationName:AMEForegroundContrastChangedNotification object:nil];
                NSLog(@"[bg-contrast] 视频首帧已取样 · %@", [self foregroundDiagnostics]);
            } else {
                NSLog(@"[bg-contrast] 视频首帧取样失败(保持语义色):%@", err.localizedDescription ?: @"unknown");
            }
        });
    });
}

- (CGFloat)representativeBackgroundLuminance {
    if (![self hasBackground]) return -1.0;              // 无自定义背景 ⇒ 未知
    NSString *path = self.currentBackgroundPath;
    if (path.length == 0) return -1.0;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSTimeInterval mtime = [attrs fileModificationDate].timeIntervalSince1970;
    if (self.ameLumaComputed &&
        [self.ameLumaPath isEqualToString:path] &&
        fabs(self.ameLumaMtime - mtime) < 0.001) {
        return self.ameCachedLuma;                        // 命中缓存
    }

    if (self.currentType == BackgroundTypeImage) {
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        CGFloat luma = [self ame_luminanceFromImage:img];
        if (luma < 0.0) return -1.0;
        [self ame_storeLuma:luma path:path mtime:mtime];
        return luma;
    }
    if (self.currentType == BackgroundTypeVideo) {
        if (!self.ameVideoLumaPending) {
            self.ameVideoLumaPending = YES;
            [self ame_computeVideoLumaAsync:path mtime:mtime];
        }
        return -1.0;                                      // 未就绪 ⇒ 语义色(与现状一致)
    }
    return -1.0;
}

// 无自定义背景 / 亮度未知时用的语义色(与改造前逐像素一致)
- (UIColor *)ame_semanticColorForRole:(AMEForegroundRole)role {
    switch (role) {
        case AMEForegroundRolePrimary:    return [UIColor labelColor];
        case AMEForegroundRoleSecondary:  return [UIColor secondaryLabelColor];
        case AMEForegroundRoleTertiary:   return [UIColor tertiaryLabelColor];
        case AMEForegroundRoleQuaternary: return [UIColor quaternaryLabelColor];
    }
    return [UIColor labelColor];
}

- (BOOL)backgroundIsLight {
    if (![self hasBackground]) return NO;
    if (self.foregroundMode == AMEForegroundModeForceDark)  return YES;   // 强制深字 ⇒ 当作亮底
    if (self.foregroundMode == AMEForegroundModeForceLight) return NO;    // 强制白字 ⇒ 当作暗底
    CGFloat luma = [self representativeBackgroundLuminance];
    if (luma < 0.0) return NO;                                            // 未知 ⇒ 不改现状
    return (luma >= kAMELumaLightForegroundCeiling);                      // 亮底 ⇒ 需要深字
}

- (UIColor *)foregroundColorForRole:(AMEForegroundRole)role {
    // ★ 兜底:无自定义背景(默认渐变/纯色)⇒ 语义色,观感与改造前一致
    if (![self hasBackground]) return [self ame_semanticColorForRole:role];
    CGFloat luma = [self representativeBackgroundLuminance];
    if (luma < 0.0 && self.foregroundMode == AMEForegroundModeAuto) {
        return [self ame_semanticColorForRole:role];       // 亮度未知(视频未就绪)⇒ 语义色
    }

    BOOL darkForeground = [self backgroundIsLight];        // 亮底 ⇒ 深字
    if (darkForeground) {
        // 深字(浅底):比系统浅色模式略提 alpha,照片类底更稳
        switch (role) {
            case AMEForegroundRolePrimary:    return [UIColor colorWithWhite:0.0 alpha:1.00];
            case AMEForegroundRoleSecondary:  return [UIColor colorWithWhite:0.0 alpha:0.62];
            case AMEForegroundRoleTertiary:   return [UIColor colorWithWhite:0.0 alpha:0.38];
            case AMEForegroundRoleQuaternary: return [UIColor colorWithWhite:0.0 alpha:0.24];
        }
    } else {
        // 白字(暗底):比系统深色模式略提 alpha(0.6→0.65 / 0.3→0.40 / 0.18→0.25)
        switch (role) {
            case AMEForegroundRolePrimary:    return [UIColor colorWithWhite:1.0 alpha:1.00];
            case AMEForegroundRoleSecondary:  return [UIColor colorWithWhite:1.0 alpha:0.65];
            case AMEForegroundRoleTertiary:   return [UIColor colorWithWhite:1.0 alpha:0.40];
            case AMEForegroundRoleQuaternary: return [UIColor colorWithWhite:1.0 alpha:0.25];
        }
    }
    return [self ame_semanticColorForRole:role];
}

- (UIColor *)foregroundShadowColorForRole:(AMEForegroundRole)role {
    (void)role;
    if (![self hasBackground]) return nil;
    if ([self representativeBackgroundLuminance] < 0.0 && self.foregroundMode == AMEForegroundModeAuto) return nil;
    // 浅色前景 ⇒ 深色投影;深色前景 ⇒ 浅色高光(复杂/中等亮度背景下保住可读性)
    return [self backgroundIsLight] ? [UIColor colorWithWhite:1.0 alpha:0.55]
                                    : [UIColor colorWithWhite:0.0 alpha:0.35];
}

- (NSString *)foregroundDiagnostics {
    CGFloat luma = [self representativeBackgroundLuminance];
    NSString *lumaStr = (luma < 0.0) ? @"未知" : [NSString stringWithFormat:@"%.3f", luma];
    NSString *modeStr = (self.foregroundMode == AMEForegroundModeForceDark) ? @"强制深"
                      : (self.foregroundMode == AMEForegroundModeForceLight) ? @"强制浅" : @"自动";
    NSString *fgStr = [self backgroundIsLight] ? @"深色前景" : @"浅色前景";
    return [NSString stringWithFormat:@"hasBg=%d type=%ld 代表亮度=%@(区块 min=%.2f max=%.2f) 模式=%@ ⇒ %@",
            (int)[self hasBackground], (long)self.currentType, lumaStr,
            self.ameLumaMin, self.ameLumaMax, modeStr, fgStr];
}

#pragma mark - ★ [BG-CONTRAST] 全局便捷函数(定义放在文件末尾 @end 之后)


// ★ [UI-B] 递归重刷玻璃高光(frame 不随 autoresize 变化,必须在布局后重设)
- (void)ameRefreshRimsRecursive:(UIView *)v {
    if (!v) return;
    AmeRefreshGlassRim(v);
    for (UIView *sub in v.subviews) { [self ameRefreshRimsRecursive:sub]; }
}

#pragma mark - ★ [GLASSUI] 玻璃高光设置即时生效

// 遍历视图树:只对「已经挂了高光图层(tag 'MRIM')」的载体做摘除 + 按当前开关/强度重建。
// 关 ⇒ AmeDetachGlassRim 摘掉;开 ⇒ AmeAttachGlassRim 按新强度重建(内部先查强度,0 也不刷)。
// 主路径(applyEffectToView:)与其它文件自挂的高光都会在这里被按新强度重建。
- (void)ameApplyGlassRimSettingsToViewTree:(UIView *)root {
    if (root == nil) { return; }
    static const NSInteger kAmeGlassRimTag = 0x4D52494D;   // 'MRIM',与 UIKit+GlassSurface.h 一致
    // ★ [RIM-STATE] 【载体】判定必须与开关无关:
    //   旧逻辑只看"当前有没有挂着高光子层" ⇒ 关掉高光后所有载体都被摘成"没有子层",于是再打开
    //   开关时这里直接跳过 ⇒ **开关是开的却没有任何高光**,而新建/复用的 cell 又各自按开关走
    //   ⇒ 表现为用户说的"随机 / 这次不听开关的话"。改为认「高光载体」标记(永久保留)。
    BOOL isCarrier = AmeIsGlassRimHost(root);
    if (!isCarrier) {
        for (UIView *sub in root.subviews) {
            if (sub.tag == kAmeGlassRimTag) { isCarrier = YES; break; }
        }
    }
    if (isCarrier) {
        [self ameSyncGlassRimStrengthForCurrentStyle];   // ★ [GLASS-STYLE] 原生风格 ⇒ 恒 0
        AmeDetachGlassRim(root);                                // ★ 摘除(先摘,保证只有一层)
        if (AMEGlassStyleAllowsHandDrawnGlass() && self.glassRimEnabled && self.glassRimStrength > 0.001) {
            AmeAttachGlassRim(root, root.layer.cornerRadius);   // ★ 按当前开关【补上】(原生/关 ⇒ 内部即时 no-op)
        }
        AmeRefreshGlassRim(root);
    }
    for (UIView *sub in [root.subviews copy]) {
        [self ameApplyGlassRimSettingsToViewTree:sub];
    }
}

// 立即把当前开关/强度刷到所有窗口上(合并同一 runloop 的重复调用),并广播通知让各页重新应用。
- (void)applyGlassRimSettingsNow {
    [self ameSyncGlassRimStrengthForCurrentStyle];   // ★ [GLASS-STYLE]
    if (gAmeGlassRimApplyScheduled) { return; }   // ★ 本 runloop 已排队 ⇒ 合并,不重复遍历
    gAmeGlassRimApplyScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gAmeGlassRimApplyScheduled = NO;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            [self ameApplyGlassRimSettingsToViewTree:w];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
    });
}

#pragma mark - ★ [GLASS-STYLE] 界面风格(原生 / 液态玻璃)即时生效

// 纯代码玻璃的强度按【实际生效风格】收敛:原生(iOS<26,或用户在 iOS>=26 上选原生)⇒ 恒 0;
// 液态玻璃 ⇒ 由「高光开关 + 强度滑块」决定。所有写全局强度的地方都走这一条,避免风格与开关打架。
- (void)ameSyncGlassRimStrengthForCurrentStyle {
    CGFloat s = 0.0;
    if (AMEGlassStyleAllowsHandDrawnGlass() && self.glassRimEnabled) { s = self.glassRimStrength; }
    AmeSetGlassRimStrength(s);
}

// 遍历视图树:把已经贴出去的玻璃层按【当前风格】重新解析一次。
// 只认我们自己打的 tag(kBackgroundBlurTag),壁纸容器的模糊层也在其列 —— 它没有 managed 标记,
// 所以只换材质、绝不叠白底。
- (void)ameReapplyGlassStyleToViewTree:(UIView *)root {
    if (root == nil) { return; }
    for (UIView *sub in [root.subviews copy]) {
        if ([sub isKindOfClass:[UIVisualEffectView class]] && sub.tag == kBackgroundBlurTag) {
            UIVisualEffectView *vev = (UIVisualEffectView *)sub;
            // 宿主分类决定回退材质:列表行/集合行用 SystemMaterial,面板/卡片/容器用 SystemThinMaterial
            // (与 applyEffectToCell: / applyEffectToView: / applyEffectToCollectionViewCell: 的原选型一致)
            BOOL isRow = [vev.superview isKindOfClass:[UITableViewCell class]] ||
                         [vev.superview isKindOfClass:[UICollectionViewCell class]] ||
                         [vev.superview.superview isKindOfClass:[UITableViewCell class]] ||
                         [vev.superview.superview isKindOfClass:[UICollectionViewCell class]];
            // ★ 换一遍 effect ⇒ UIKit 重建 backdrop(私有调参随之复位),再按风格重铺填充 / 重做调参
            vev.effect = AmeGlassEffect(isRow ? UIBlurEffectStyleSystemMaterial : UIBlurEffectStyleSystemThinMaterial);
            if (AmeIsManagedGlass(vev)) {
                AmeApplyGlassFillForCurrentStyle(vev);
                if (AMEGlassStyleAllowsHandDrawnGlass()) {
                    AmeTuneGlassBackdrop(vev, AmeGlassBlurRadius, AmeGlassSaturate);
                }
            }
        }
        [self ameReapplyGlassStyleToViewTree:sub];
    }
}

// 界面风格变更(设置页 → AMEGlassStyleSetConfigured → 通知)⇒ 立即重刷:
//   ① 收敛纯代码玻璃强度;② 重解析所有已贴玻璃层的材质/填充/调参;③ 重建高光;
//   ④ 广播 BackgroundUIEffectChanged,让各页面按新风格重新应用(导航栏/工具栏在各自 apply 里按风格重建)。
- (void)ameGlassStyleChanged:(NSNotification *)note {
    (void)note;
    [self ameSyncGlassRimStrengthForCurrentStyle];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            [self ameReapplyGlassStyleToViewTree:w];
            [self ameApplyGlassRimSettingsToViewTree:w];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
        NSLog(@"[glass] 界面风格切换已生效: 配置=%@ · 实际生效=%@",
              AMEGlassStyleStringFromEnum(AMEGlassStyleConfigured()),
              AMEGlassStyleStringFromEnum(AMEGlassStyleResolved()));
    });
}
@end

#pragma mark - ★ [BG-CONTRAST] 全局便捷函数(文件作用域,供各 UI 文件直接调用)

UIColor *AMEForegroundColor(AMEForegroundRole role) {
    return [[BackgroundManager sharedManager] foregroundColorForRole:role];
}

UIColor *AMEForegroundShadowColor(void) {
    return [[BackgroundManager sharedManager] foregroundShadowColorForRole:AMEForegroundRolePrimary];
}