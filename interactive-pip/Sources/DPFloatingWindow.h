#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPSceneHost;

// 0.7.113: keyboard expand/collapse event trace (shared with diagnostics panel).
FOUNDATION_EXPORT NSString *DPKeyboardExpandTrace(void);
FOUNDATION_EXPORT void DPKBLog(NSString *fmt, ...);

/// Hosts a second app scene inside a draggable / resizable floating chrome.
@interface DPFloatingWindow : UIView

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly, nullable) DPSceneHost *sceneHost;
@property (nonatomic, assign) CGFloat contentOpacity;
@property (nonatomic, assign) CGFloat cornerRadiusValue;
@property (nonatomic, assign) BOOL showsBorder;
@property (nonatomic, assign, getter=isTiled) BOOL tiled;
@property (nonatomic, copy, nullable) void (^onSplit)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onClose)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFocus)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFrameChanged)(DPFloatingWindow *window, CGRect frame);

- (instancetype)initWithBundleID:(NSString *)bundleID frame:(CGRect)frame;
- (void)attachSceneHost:(DPSceneHost *)host;
- (nullable DPSceneHost *)detachSceneHost;
- (void)commitSceneLayout;
/// 0.7.218 照 PV 的 _parkedSnapshot：挂起时先贴一张快照占位，
/// App 即使被系统挂起/回桌面，卡片也不会黑屏。
- (void)setParkedSnapshot:(nullable UIImage *)image;
- (nullable UIImage *)parkedSnapshotImage;
- (BOOL)hasParkedSnapshot;
- (void)updateNaturalCanvasForCurrentScreen; // 0.7.131 rotation
/// Round the pane's own chrome + content container while in Duo split.
/// Never touches the hosted scene layer container's layer.
- (void)setSplitCardCornerRadius:(CGFloat)radius;
- (void)setActive:(BOOL)active animated:(BOOL)animated;
- (void)bringToFront;
- (void)closeAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;
/// 键盘弹出时把浮窗放大到覆盖键盘上方的可用区域（近似全屏）。
/// 键盘收起时用 -collapseForKeyboardAnimated: 还原到键盘弹出前的 frame。
/// 与手动全屏按钮的 maximized 状态互相独立。
- (void)expandForKeyboardAnimated:(BOOL)animated;
- (void)collapseForKeyboardAnimated:(BOOL)animated;
/// 当前是否因键盘弹出而处于扩展态。
@property (nonatomic, assign, readonly) BOOL keyboardExpanded;

/// 0.7.173: 拖出即保留预览态。激活时窗口进入该态：顶部显示「松手保留」提示，
/// 拖动标题栏松手后触发 onDragPreviewEnded，由管理端固定窗口并进入分屏配对。
@property (nonatomic, assign, getter=isDragPreviewActive) BOOL dragPreviewActive;
@property (nonatomic, copy, nullable) void (^onDragPreviewEnded)(DPFloatingWindow *window);
- (void)beginDragPreview;
- (void)endDragPreview;

/// 0.7.175: 在 App 界面上滑到灵动岛位置固定 → 开启分屏。
/// 松手回调由管理端把该窗口固定为分屏第一屏并弹 picker 选第二个 App。
@property (nonatomic, copy, nullable) void (^onSwipeUpToIsland)(DPFloatingWindow *window);

@end

NS_ASSUME_NONNULL_END
