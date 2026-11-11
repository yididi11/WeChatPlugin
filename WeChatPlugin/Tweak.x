// WeChatPlugin — Phase 6.1：抢红包 DK 忠实度审计对齐（适配微信 8.0.79）
//
// 在 Phase 4 的基础上只做一件事：
//   1. 设置页格式分区第 1 行（自定义格式）和第 6 行（自定义颜色）不再是内联
//      输入框，改成展示行（标题 + 当前值副标题 + 右箭头），点按弹出输入弹窗，
//      在弹窗里输入。弹窗是纯 UIKit 的自定义 modal VC（半透明遮罩 + 圆角白
//      卡片），模板和颜色共用同一个弹窗骨架；不用 UIAlertController（它只
//      适合塞单行输入框，多行输入框放不进去）。
//   2. 模板弹窗：多行输入框（预填当前模板，回车即换行）+ 占位符说明小字，
//      底部“取消”/“保存”；保存时任何内容都合法，留空＝默认格式。
//   3. 颜色弹窗：单行输入框（预填当前颜色值）+ 格式提示小字；保存时按
//      WCPNormalizeHexColor 校验——合法则归一化存进 "revokeNoticeColor"，
//      留空则清除颜色恢复默认灰，非法则不关弹窗、在弹窗内红字提示格式错误。
//   4. 内联输入框的相关代码（UITextView / UITextField 的创建、复用移动、
//      delegate 保存、键盘收起逻辑）全部删除，不留死代码；WCPNormalizeHexColor、
//      WCPSetRevokeNoticeColorHex、模板存取函数保留。行数不变：格式分区展开
//      仍是 7 行、收起仍是 1 行；版本号升到 HBG · Phase 5。
// Phase 6：自动抢红包（白名单模式），移植自 DKWechatHelper：
//   1. 设置页“更多功能”分区第 0 行是自动抢红包开关（默认关闭），第 1 行是
//      “选择群聊/私聊”（点进去是白名单选择页），其余 5 行仍是“即将推出”占位。
//   2. 白名单模式：开关打开后先不生效；只有白名单里选中的群聊/私聊的红包才抢，
//      一个都没选就什么都不抢。白名单存 username（不用显示名，群名/备注会改）。
//   3. 抢的链路（DK 原样）：CMessageMgr onNewSyncAddMessage: 收到 type 49 且内容
//      含 wxpay:// 的消息 → 解析 m_oWCPayInfoItem.m_c2cNativeUrl → 查白名单 →
//      ReceiverQueryRedEnvelopesRequest: 查询 → OnWCToHongbaoCommonResponse:
//      （cgiCmdid==3）校验 receiveStatus/hbStatus/timingIdentifier/sign →
//      OpenRedEnvelopesRequest: 开红包。消息本身一律走 %orig，不拦截不改消息。
//   4. 弹窗的玻璃代码原样不动（真机上玻璃效果没出来，用户说先不管它）。
//   版本号升到 HBG · Phase 6。
// Phase 6.1：抢红包 DK 忠实度审计（用户要求着重参考 DK 原项目）：
//   把 Phase 6 逐行对照 DK 原版（dkhelperDylib.xm 红包检测 144-260 行、响应
//   304-355 行；DKHelper.m toParams 291-305 行、操作类 368-427 行、任务队列
//   436-469 行），结论：核心链路已与 DK 对齐，只改了一处会影响抢得到的
//   地方——timingIdentifier 的类型：DK 只判断存在性，Phase 6 只认 NSString；
//   8.0.79 若返回数字会被直接放弃。现按 DK 语义对齐：字符串直接用，数字转
//   字符串，其他类型/空值才放弃。其余与 DK 的差异都是有意保留的（白名单模式、
//   4 处防闪退安全改动）或用户没要的功能（延迟、关键词过滤、后台抢、串行队列），
//   详见 phase6.1-NOTES.md。版本号升到 HBG · Phase 6.1。
//
// Phase 3.1 的修复原样保留：逻辑/物理分区换算用 >=、格式分区标题显式返回 nil、
// 开关拨动和收起/展开一律 reloadData（绝不用 insert/deleteSections/Rows）。
//
// 保持不变：静默加载（无 %ctor 弹窗）、汉伯格/HBG 命名、所有功能默认关闭、
// 点提示跳转、格式模板+预设+换行、不直接写 [WeChatClass class]（微信类一律
// objc_getClass / %c 运行时查，否则链接失败）、不用 keyWindow / MSHookIvar /
// CaptainHook / QGVAPlayer。
// 不包含（后续阶段再做）：步数、小游戏、朋友圈转发、集赞、好友检测、
// 动态背景/启动图、反检测层、后台抢红包（第一版只做前台抢红包）。

#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/message.h>
#import <objc/runtime.h>


// =========================================================================
// 最小微信接口声明 —— 只声明本文件实际用到的类/方法，且只以 8.0.79 头文件为准。
// =========================================================================

@interface MMServiceCenter : NSObject
- (id)getService:(Class)service;
// 由本文件 %hook MMServiceCenter 经 %new 加上的方法（8.0.79 原生没有）。
+ (id)defaultCenter;
@end

@interface MMContext : NSObject
+ (id)currentContext;
@property (readonly, nonatomic) MMServiceCenter *serviceCenter;
@end

// 8.0.79 里 m_nsUsrName 等字段在父类 CBaseContact 上（CBaseContact.h:133）。
@interface CBaseContact : NSObject
@property (retain, nonatomic) NSString *m_nsUsrName;
@property (retain, nonatomic) NSString *m_nsHeadImgUrl; // CBaseContact.h:119
@end

@interface CContact : CBaseContact
- (id)getContactDisplayName; // CContact.h:326
@end

@interface CContactMgr : NSObject
- (id)getSelfContact; // CContactMgr.h:77
- (id)getContactByName:(id)arg1; // CContactMgr.h:158
@end

@class WCPayInfoItem; // 完整声明在下面（红包接口区）；这里先前置声明，CMessageWrap 的属性要用它

@interface CMessageWrap : NSObject
@property (retain, nonatomic) NSString *m_nsContent;
@property (nonatomic) unsigned int m_uiMessageType;
@property (retain, nonatomic) NSString *m_nsToUsr;
@property (retain, nonatomic) NSString *m_nsFromUsr;
@property (nonatomic) unsigned int m_uiStatus;
@property (nonatomic) unsigned int m_uiCreateTime;
@property (nonatomic) unsigned int m_uiMesLocalID; // CMessageWrap.h:474
@property (retain, nonatomic) WCPayInfoItem *m_oWCPayInfoItem; // CMessageWrap.h:998
- (id)initWithMsgType:(long long)arg1;
@end

// 红包消息的支付信息（WCPayInfoItem.h:214）与会话列表、红包逻辑管理：
// WCPayInfoItem / MMNewSessionMgr / WCBizUtil / WCRedEnvelopesLogicMgr /
// HongBaoRes / HongBaoReq / SKBuiltinBuffer_t 的声明都以 8.0.79 头文件为准。
@interface WCPayInfoItem : NSObject
@property (retain, nonatomic) NSString *m_c2cNativeUrl;
@end

@interface MMNewSessionMgr : NSObject
- (id)GetUserNamesOnSessionList; // MMNewSessionMgr.h:142
@end

@interface WCBizUtil : NSObject
+ (NSDictionary *)dictionaryWithDecodedComponets:(NSString *)components separator:(NSString *)separator; // WCBizUtil.h:157
@end

@interface WCRedEnvelopesLogicMgr : NSObject
- (void)ReceiverQueryRedEnvelopesRequest:(id)arg1; // WCRedEnvelopesLogicMgr.h:38
- (void)OpenRedEnvelopesRequest:(id)arg1; // WCRedEnvelopesLogicMgr.h:34
- (void)OnWCToHongbaoCommonResponse:(id)arg1 Request:(id)arg2; // WCRedEnvelopesLogicMgr.h:73
@end

@interface SKBuiltinBuffer_t : NSObject
@property (retain, nonatomic) NSData *buffer; // SKBuiltinBuffer_t.h:19
@end

@interface HongBaoReq : NSObject
@property (retain, nonatomic) SKBuiltinBuffer_t *reqText; // HongBaoReq.h:21
@end

@interface HongBaoRes : NSObject
@property (nonatomic) int cgiCmdid; // HongBaoRes.h:19
@property (retain, nonatomic) SKBuiltinBuffer_t *retText; // HongBaoRes.h:24
@end

@interface CMessageMgr : NSObject
- (void)onNewSyncNotAddDBMessage:(id)arg1;
- (void)onNewSyncAddMessage:(id)arg1; // CMessageMgr.h:189
- (id)GetMsg:(id)arg1 n64SvrID:(long long)arg2;
- (void)AddLocalMsg:(id)arg1 MsgWrap:(id)arg2 fixTime:(BOOL)arg3 NewMsgArriveNotify:(BOOL)arg4;
- (id)GetMsg:(id)arg1 LocalID:(unsigned int)arg2; // CMessageMgr.h:329
- (unsigned int)GetMsgSeqMaxLocalId:(id)arg1;      // CMessageMgr.h:298
@end

@interface WCTableViewManager : NSObject
@property (retain, nonatomic) NSMutableArray *sections;
- (id)getTableView;
@end

@interface WCTableViewSectionManager : NSObject
- (void)addCell:(id)arg1;
@end

@interface WCTableViewNormalCellManager : NSObject
// 8.0.79 里没有 DK 用的三参数版，最短的是这个带 accessoryType: 的四参数版
//（WCTableViewNormalCellManager.h:29）。
+ (id)normalCellForSel:(SEL)arg1 target:(id)arg2 title:(id)arg3 accessoryType:(long long)arg4;
@end

@interface NewSettingViewController : UIViewController
- (void)reloadTableData;
@end

// 系统消息 cell（msgType 0x2710 的提示就渲染在这里）：
// viewModel 是 SystemMessageViewModel，messageWrap 在父类 BaseMessageViewModel 上
//（BaseMessageViewModel.h:50）。
@interface BaseMessageViewModel : NSObject
@property (retain, nonatomic) CMessageWrap *messageWrap;
@end

@interface SystemMessageViewModel : BaseMessageViewModel
// 解析后的文本样式数组（SystemMessageViewModel.h，readonly 但内容可改）。
@property (readonly, nonatomic) NSMutableArray *contentTextStyles;
@end

// 富文本样式（TextStyle.h:34-35）与富文本视图（RichTextView.h:157）。
@interface TextStyle : NSObject
@property (retain) UIColor *oTextColor;
@property (retain) UIColor *oDrawColor;
@end

@interface RichTextView : UIView
@property (retain, nonatomic) UIColor *oTextColor;
@end

@interface SystemMessageCellView : UIView
@property (readonly, nonatomic) SystemMessageViewModel *viewModel; // SystemMessageCellView.h:44
- (void)onAppear; // SystemMessageCellView.h:31
- (void)layoutContentView; // SystemMessageCellView.h:30
- (RichTextView *)getRichTextView; // SystemMessageCellView.h（返回 id）
@end

// 聊天页 VC：getCurrentChatName（:691）、locateToMsg:（:976）、
// scrollToMessage:highlight:marginTop:animated:（:509，均在 BaseMsgContentViewController.h）。
@interface BaseMsgContentViewController : UIViewController
- (id)getCurrentChatName;
- (void)locateToMsg:(id)arg1;
- (void)scrollToMessage:(id)arg1 highlight:(BOOL)arg2 marginTop:(double)arg3 animated:(BOOL)arg4;
@end


// =========================================================================
// 开关存储 —— NSUserDefaults，key 与 DK 保持一致（"preventRevoke"），
// 默认关闭：从未存过值时返回 NO（本项目所有功能默认关闭）。
// =========================================================================

static NSString * const kWCPPreventRevokeKey = @"preventRevoke";

static BOOL WCPPreventRevokeEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kWCPPreventRevokeKey] == nil) return NO;
    return [defaults boolForKey:kWCPPreventRevokeKey];
}

static void WCPSetPreventRevokeEnabled(BOOL enabled) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kWCPPreventRevokeKey];
    [defaults synchronize];
}


// =========================================================================
// 自动抢红包开关 + 白名单 —— NSUserDefaults（新 key "autoGrabRedPacket" /
// "redPacketWhitelist"），全部默认关闭/为空。
// 白名单模式（用户 2026-11-11 决定）：开关打开后先不生效；只有白名单里选中的
// 群聊/私聊的红包才抢，一个都没选就什么都不抢。
// 白名单存 username 数组（不用显示名：群名/备注会改，username 不变）。
// =========================================================================

static NSString * const kWCPAutoGrabRedPacketKey = @"autoGrabRedPacket";
static NSString * const kWCPRedPacketWhitelistKey = @"redPacketWhitelist";

static BOOL WCPAutoGrabRedPacketEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kWCPAutoGrabRedPacketKey] == nil) return NO;
    return [defaults boolForKey:kWCPAutoGrabRedPacketKey];
}

static void WCPSetAutoGrabRedPacketEnabled(BOOL enabled) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kWCPAutoGrabRedPacketKey];
    [defaults synchronize];
}

static NSSet<NSString *> *WCPWhitelistUsernames(void) {
    NSArray *arr = [[NSUserDefaults standardUserDefaults] arrayForKey:kWCPRedPacketWhitelistKey];
    if (!arr) return [NSSet set];
    NSMutableSet *set = [NSMutableSet set];
    for (id obj in arr) {
        if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length]) [set addObject:obj];
    }
    return [set copy];
}

static BOOL WCPIsUsernameWhitelisted(NSString *username) {
    if (!username.length) return NO;
    return [WCPWhitelistUsernames() containsObject:username];
}

static void WCPSetUsernameWhitelisted(NSString *username, BOOL whitelisted) {
    if (!username.length) return;
    NSMutableSet *set = [WCPWhitelistUsernames() mutableCopy];
    if (whitelisted) [set addObject:username];
    else [set removeObject:username];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[set allObjects] forKey:kWCPRedPacketWhitelistKey];
    [defaults synchronize];
}


// =========================================================================
// 拦截提示格式 —— NSUserDefaults（新 key "revokeNoticeFormat"）。
// 占位符：{名字} 撤回者（自己显示“你”）；{内容} 原消息文本（非文本消息为空）；
// {时间} 原消息时间（当天显示 HH:mm，否则 MM-dd HH:mm）。
// 模板为空（未设置）时，回退到 Phase 1 的原 4 种默认文案。
// =========================================================================

static NSString * const kWCPRevokeNoticeFormatKey = @"revokeNoticeFormat";

static NSString *WCPRevokeNoticeFormat(void) {
    NSString *tpl = [[NSUserDefaults standardUserDefaults] stringForKey:kWCPRevokeNoticeFormatKey];
    if (!tpl.length) return nil;
    return tpl;
}

static void WCPSetRevokeNoticeFormat(NSString *tpl) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (tpl.length) [defaults setObject:tpl forKey:kWCPRevokeNoticeFormatKey];
    else [defaults removeObjectForKey:kWCPRevokeNoticeFormatKey];
    [defaults synchronize];
}

static NSString *WCPFormatTimeForNotice(unsigned int createTime) {
    static NSDateFormatter *sameDayFmt = nil;
    static NSDateFormatter *otherDayFmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sameDayFmt = [[NSDateFormatter alloc] init];
        sameDayFmt.dateFormat = @"HH:mm";
        otherDayFmt = [[NSDateFormatter alloc] init];
        otherDayFmt.dateFormat = @"MM-dd HH:mm";
    });
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:createTime];
    if ([[NSCalendar currentCalendar] isDateInToday:date]) return [sameDayFmt stringFromDate:date];
    return [otherDayFmt stringFromDate:date];
}

static NSString *WCPApplyNoticeTemplate(NSString *tpl, NSString *name, NSString *content, unsigned int createTime) {
    NSString *result = tpl;
    result = [result stringByReplacingOccurrencesOfString:@"{名字}" withString:(name ?: @"")];
    result = [result stringByReplacingOccurrencesOfString:@"{内容}" withString:(content ?: @"")];
    result = [result stringByReplacingOccurrencesOfString:@"{时间}" withString:WCPFormatTimeForNotice(createTime)];
    return result;
}

// 预设模板（设置页一键切换）
static NSArray<NSDictionary *> *WCPNoticeFormatPresets(void) {
    static NSArray<NSDictionary *> *presets = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        presets = @[
            @{@"title": @"简洁", @"template": @"{名字}撤回了一条消息"},
            @{@"title": @"详细", @"template": @"[{时间}] {名字}撤回消息：{内容}"},
            @{@"title": @"完整", @"template": @"拦截到 {名字} 在 {时间} 撤回的消息：{内容}"},
        ];
    });
    return presets;
}


// =========================================================================
// 格式分区收起/展开 —— NSUserDefaults（新 key "revokeFormatExpanded"）。
// 默认展开（从未存过值时返回 YES）；收起时分区只留首行开关行。
// =========================================================================

static NSString * const kWCPFormatExpandedKey = @"revokeFormatExpanded";

static BOOL WCPFormatExpanded(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kWCPFormatExpandedKey] == nil) return YES;
    return [defaults boolForKey:kWCPFormatExpandedKey];
}

static void WCPSetFormatExpanded(BOOL expanded) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:expanded forKey:kWCPFormatExpandedKey];
    [defaults synchronize];
}


// =========================================================================
// 拦截提示颜色 —— NSUserDefaults（key "revokeNoticeColor"，存 #RRGGBB；
// 未设置/空字符串＝默认灰，不做任何改色）。
// Phase 4：颜色只通过“自定义颜色”行的十六进制输入框改；Phase 3 的 6 个
// 预设色点已按用户要求取消，相关代码全部删除（不再有色点 UI 和同步逻辑）。
// =========================================================================

static NSString * const kWCPRevokeNoticeColorKey = @"revokeNoticeColor";

// 把用户输入归一化成 #RRGGBB（大写）；非法返回 nil。
// 规则：去首尾空格和可选的 '#'；接受 6 位 RRGGBB、3 位 RGB 简写（每位翻倍，
// 如 FBC → FFBBCC）、8 位 AARRGGBB（前两位是透明度，取后 6 位作颜色）；
// 大小写不敏感；其他长度或含非十六进制字符一律非法。
// 注意：FFFBAC6 是 7 位，属于非法输入。
static NSString *WCPNormalizeHexColor(NSString *input) {
    if (!input) return nil;
    NSString *clean = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"#"]) clean = [clean substringFromIndex:1];
    if (clean.length == 3) {
        // 3 位简写：每位翻倍。
        NSMutableString *expanded = [NSMutableString stringWithCapacity:6];
        for (NSUInteger i = 0; i < 3; i++) {
            unichar c = [clean characterAtIndex:i];
            [expanded appendFormat:@"%C%C", c, c];
        }
        clean = expanded;
    } else if (clean.length == 8) {
        // 8 位 AARRGGBB：前两位透明度，取后 6 位。
        clean = [clean substringFromIndex:2];
    } else if (clean.length != 6) {
        return nil;
    }
    // 必须是 6 位十六进制字符（NSScanner 的 scanHexInt 会在首个非法字符处停下，
    // 只看返回值不够严，必须先逐字符校验）。
    NSCharacterSet *hexChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    if ([[clean stringByTrimmingCharactersInSet:hexChars] length] != 0) return nil;
    return [NSString stringWithFormat:@"#%@", [clean uppercaseString]];
}

// 返回当前选中的颜色 hex；nil/空＝默认灰（不改色）。
static NSString *WCPRevokeNoticeColorHex(void) {
    NSString *hex = [[NSUserDefaults standardUserDefaults] stringForKey:kWCPRevokeNoticeColorKey];
    if (!hex.length) return nil;
    return hex;
}

static void WCPSetRevokeNoticeColorHex(NSString *hex) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (hex.length) [defaults setObject:hex forKey:kWCPRevokeNoticeColorKey];
    else [defaults removeObjectForKey:kWCPRevokeNoticeColorKey];
    [defaults synchronize];
}

static UIColor *WCPUIColorFromHex(NSString *hex) {
    NSString *normalized = WCPNormalizeHexColor(hex);
    if (!normalized) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[normalized substringFromIndex:1]];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}


// =========================================================================
// 提示 ↔ 原消息 映射（只放内存，重启微信后旧提示点按无效）。
// key 有两种：
//   "会话|L<提示localID>" —— 主键，localID 在同一会话内唯一；
//   "会话|T<提示createTime>" —— 备用（AddLocalMsg 后若 wrap 上读不到 localID、
//   且 GetMsgSeqMaxLocalId 兜底也不可靠时，仍能按时间找到）。
//   字典上限 200 条，超了按插入顺序淘汰最旧的。
// =========================================================================

static NSMutableDictionary<NSString *, NSNumber *> *WCPNoticeMap(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSMutableArray<NSString *> *WCPNoticeMapOrder(void) {
    static NSMutableArray<NSString *> *order = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ order = [NSMutableArray array]; });
    return order;
}

static void WCPNoticeMapSet(NSString *key, unsigned int origLocalID) {
    NSMutableDictionary *map = WCPNoticeMap();
    NSMutableArray *order = WCPNoticeMapOrder();
    if (!map[key]) [order addObject:key];
    map[key] = @(origLocalID);
    while (order.count > 200) {
        NSString *oldKey = order.firstObject;
        [order removeObjectAtIndex:0];
        [map removeObjectForKey:oldKey];
    }
}

static NSNumber *WCPNoticeMapGet(NSString *key) {
    return WCPNoticeMap()[key];
}


// =========================================================================
// 提示点按处理 —— 单例做手势 target，避免手势 recognizer 直接 retain cell
// 造成循环引用（cell → recognizer → target(cell) 互相持有就泄漏了；
// 单例不持有 cell，点按时通过 recognizer.view 反查当前 cell）。
// =========================================================================

@interface WCPNoticeTapHandler : NSObject
+ (instancetype)sharedHandler;
- (void)handleNoticeTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation WCPNoticeTapHandler

+ (instancetype)sharedHandler {
    static WCPNoticeTapHandler *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[WCPNoticeTapHandler alloc] init]; });
    return shared;
}

- (void)handleNoticeTap:(UITapGestureRecognizer *)recognizer {
    UIView *tappedView = recognizer.view;
    // 注意：不能写 [SystemMessageCellView class]——微信的类构建时不存在，
    // 链接器会报 _OBJC_CLASS_$_SystemMessageCellView 找不到；用运行时查类。
    if (![tappedView isKindOfClass:objc_getClass("SystemMessageCellView")]) return;
    SystemMessageCellView *cellView = (SystemMessageCellView *)tappedView;
    // 点按时才读当前 viewModel：cell 会复用，挂手势时读到的 wrap 可能是旧的。
    CMessageWrap *noticeWrap = cellView.viewModel.messageWrap;
    if (!noticeWrap || noticeWrap.m_uiMessageType != 0x2710) return;

    // 沿响应链往上找聊天页 VC（点按只能发生在该提示所在的会话聊天页内，
    // 所以一定是同会话跳转，不需要跨会话打开）。
    BaseMsgContentViewController *chatVC = nil;
    for (UIResponder *r = cellView; r; r = r.nextResponder) {
        // 同上：微信类只能运行时查，写 [BaseMsgContentViewController class] 会链接失败。
        if ([r isKindOfClass:objc_getClass("BaseMsgContentViewController")]) {
            chatVC = (BaseMsgContentViewController *)r;
            break;
        }
    }
    if (!chatVC) return;

    NSString *session = [chatVC getCurrentChatName];
    if (!session.length) session = noticeWrap.m_nsToUsr;
    if (!session.length) return;

    // 先按提示 localID 查，再按 session+createTime 查。
    NSString *keyL = [NSString stringWithFormat:@"%@|L%u", session, noticeWrap.m_uiMesLocalID];
    NSNumber *origLocalID = WCPNoticeMapGet(keyL);
    if (!origLocalID) {
        NSString *keyT = [NSString stringWithFormat:@"%@|T%u", session, noticeWrap.m_uiCreateTime];
        origLocalID = WCPNoticeMapGet(keyT);
    }
    if (!origLocalID) return; // 不是我们插的提示，或重启后映射已丢失

    CMessageMgr *msgMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(CMessageMgr)];
    CMessageWrap *origWrap = [msgMgr GetMsg:session LocalID:origLocalID.unsignedIntValue];
    if (!origWrap) return; // 原消息已被删库，无法定位

    if ([chatVC respondsToSelector:@selector(locateToMsg:)]) {
        [chatVC locateToMsg:origWrap];
    } else {
        [chatVC scrollToMessage:origWrap highlight:YES marginTop:10 animated:YES];
    }
}

@end


// =========================================================================
// 拦截提示改色 —— 只对我们插的提示生效，别人的系统消息一律不动。
//
// 做法：cell 布局时（layoutContentView / onAppear 之后），若该 cell 渲染的
// 是我们插的拦截提示（msgType 0x2710 且 localID 在内存映射里），且用户选了
// 非默认颜色，就把 viewModel.contentTextStyles 里每个 TextStyle 的
// oTextColor/oDrawColor 改成所选颜色，同时改 RichTextView.oTextColor，
// 再让 RichTextView 重绘。只改样式对象本身，不改 wrap、不改内容，
// 颜色只影响这一条提示的渲染。
//
// 注意：
//   - m_attachedTextColor 不是这条路：它是表情消息附加文字的颜色
//     （CExtendInfoOfEmoticon.h:39、55），系统消息渲染不读它，
//     在 wrap 上设它不会让提示变色；
//   - 内容里嵌 <font color> 之类的标记也没有证据支持：109,569 个头文件里
//     搜不到任何 font/color 标记解析，TextParser 的子类只有 Address /
//     Bold / Link，没有 Color 解析器；
//   - 样式对象在 cell 布局前由 viewModel 量尺寸时建好，所以布局时改得到；
//     但渲染管线是否在绘制时重读样式颜色，只能真机验证——若不生效，
//     提示保持微信默认灰色，功能不受影响（见 phase3-NOTES.md §5）。
//   - 已应用过的样式不再重复触发重绘（比对后无变化就不 setNeedsDisplay），
//     布局反复调用也不会多耗。
// =========================================================================

static void WCPApplyNoticeColorToCell(SystemMessageCellView *cellView) {
    if (!cellView) return;
    NSString *hex = WCPRevokeNoticeColorHex();
    if (!hex) return; // 默认灰：不改色

    CMessageWrap *noticeWrap = cellView.viewModel.messageWrap;
    if (!noticeWrap || noticeWrap.m_uiMessageType != 0x2710) return;

    // 沿响应链找聊天页 VC 拿会话名（与点按处理同样的办法），拿不到用 wrap 的 ToUsr 兜底。
    NSString *session = nil;
    for (UIResponder *r = cellView; r; r = r.nextResponder) {
        if ([r isKindOfClass:objc_getClass("BaseMsgContentViewController")]) {
            session = [(BaseMsgContentViewController *)r getCurrentChatName];
            break;
        }
    }
    if (!session.length) session = noticeWrap.m_nsToUsr;
    if (!session.length) return;

    // 只改我们插的提示：localID 或 session+createTime 在映射里才算。
    NSString *keyL = [NSString stringWithFormat:@"%@|L%u", session, noticeWrap.m_uiMesLocalID];
    NSString *keyT = [NSString stringWithFormat:@"%@|T%u", session, noticeWrap.m_uiCreateTime];
    if (!WCPNoticeMapGet(keyL) && !WCPNoticeMapGet(keyT)) return;

    UIColor *color = WCPUIColorFromHex(hex);
    if (!color) return;

    BOOL changed = NO;
    NSArray *styles = cellView.viewModel.contentTextStyles;
    Class textStyleClass = objc_getClass("TextStyle");
    for (id styleObj in styles) {
        if (![styleObj isKindOfClass:textStyleClass]) continue;
        TextStyle *style = (TextStyle *)styleObj;
        if (![style.oTextColor isEqual:color]) { style.oTextColor = color; changed = YES; }
        if (![style.oDrawColor isEqual:color]) { style.oDrawColor = color; changed = YES; }
    }
    RichTextView *richTextView = [cellView getRichTextView];
    if (richTextView && ![richTextView.oTextColor isEqual:color]) {
        richTextView.oTextColor = color;
        changed = YES;
    }
    if (changed && richTextView) [richTextView setNeedsDisplay];
}


// =========================================================================
// 输入弹窗 —— 纯 UIKit 的自定义 modal VC（半透明遮罩 + 圆角白卡片）。
//
// 用途：设置页第 1 行（自定义格式，多行输入）和第 6 行（自定义颜色，单行输入）
// =========================================================================
// 液态玻璃（Phase 5.1）：弹窗卡片、按钮都做成 iOS 27 Liquid Glass 质感。
//
// 实现分两层，缺一不可：
//   1. 真玻璃：iOS 26+ 的 UIGlassEffect（UIVisualEffect 的子类），只能运行时查
//      类——构建机的 SDK 未必有这个符号，代码里绝不能直接写 UIGlassEffect /
//      UIGlassContainerView / UIGlassEffectStyle 这些名字（否则编译或链接失败，
//      和之前直接写 [WeChatClass class] 导致第 8 次构建失败是同类问题）。
//      查法：NSClassFromString(@"UIGlassEffect")，依次试 +glassEffect、
//      +glassEffectWithStyle:（0＝Regular）、[[alloc] init]，拿到后验证它确实
//      是 UIVisualEffect 的实例再用；全部包在 @try/@catch 里，任何一步不对就
//      掉到第 2 层。带 tint 的（保存按钮）再试 setTintColor:（同样先
//      respondsToSelector 再调）。
//   2. 模糊回退：没有真玻璃的系统（iOS 26 之前，或运行时查不到）用
//      UIBlurEffect systemUltraThinMaterial（卡片，透得更多、更像玻璃）或
//      systemMaterial（按钮），再叠白半透明描边 + 阴影，同样是磨砂玻璃观感。
// 注意：UIGlassContainerView（把多个玻璃面拼成一片折射）这里故意不用——
// 弹窗只有一张玻璃卡片，不需要分组折射；UIVisualEffectView + UIGlassEffect
// 是 Apple 给 UIKit 的标准做法。
// =========================================================================

// 返回一块液态玻璃效果：有真玻璃就用真玻璃，没有就回退到磨砂模糊。
// tinted＝YES 时（保存按钮）尽量给玻璃带一点主题色 tint。
static UIVisualEffect *WCPGlassEffect(BOOL tinted) {
    Class glassCls = NSClassFromString(@"UIGlassEffect");
    if (glassCls) {
        @try {
            id effect = nil;
            SEL selGlass = NSSelectorFromString(@"glassEffect");
            if ([glassCls respondsToSelector:selGlass]) {
                effect = ((id (*)(id, SEL))objc_msgSend)(glassCls, selGlass);
            }
            if (!effect) {
                SEL selStyle = NSSelectorFromString(@"glassEffectWithStyle:");
                if ([glassCls respondsToSelector:selStyle]) {
                    effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassCls, selStyle, (NSInteger)0);
                }
            }
            if (!effect) effect = [[glassCls alloc] init];
            if (effect && [effect isKindOfClass:[UIVisualEffect class]]) {
                if (tinted && [effect respondsToSelector:@selector(setTintColor:)]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(effect, @selector(setTintColor:), [UIColor systemBlueColor]);
                }
                return (UIVisualEffect *)effect;
            }
        } @catch (NSException *e) {
            // 查类/调方法任何一步出问题，都掉到下面的模糊回退。
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

// 做一块圆角玻璃：UIVisualEffectView + 大圆角 + 细亮边（白半透明描边）。
// 调用方负责把它放进合适的位置；内容一律加到返回值的 contentView 里。
static UIVisualEffectView *WCPMakeGlassView(CGFloat cornerRadius, BOOL tinted) {
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:WCPGlassEffect(tinted)];
    glass.layer.cornerRadius = cornerRadius;
    glass.layer.masksToBounds = YES;
    glass.layer.borderWidth = 1;
    glass.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    return glass;
}

// 做一颗玻璃胶囊按钮：底是圆角玻璃（保存按钮带主题色 tint），字在上面。
// tinted＝YES 时：真玻璃走效果自身的 tintColor；回退模糊时补一块
// systemBlue 18% 透明的色块（真玻璃不用补，isKindOfClass 能分出来）。
static UIButton *WCPMakeGlassCapsuleButton(NSString *title, BOOL tinted, BOOL bold, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor clearColor];
    button.layer.cornerRadius = 19; // 按钮行高 38 的一半，胶囊。
    button.layer.masksToBounds = YES;

    UIVisualEffectView *glass = WCPMakeGlassView(19, tinted);
    glass.frame = button.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.userInteractionEnabled = NO;
    [button insertSubview:glass atIndex:0];

    if (tinted && ![glass.effect isKindOfClass:NSClassFromString(@"UIGlassEffect")]) {
        // 回退模糊：补主题色（真玻璃已通过 tintColor 着色，不用补）。
        UIView *tint = [[UIView alloc] initWithFrame:button.bounds];
        tint.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.18];
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.userInteractionEnabled = NO;
        [glass.contentView addSubview:tint];
    }

    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:(tinted ? [UIColor systemBlueColor] : [UIColor labelColor]) forState:UIControlStateNormal];
    button.titleLabel.font = bold ? [UIFont boldSystemFontOfSize:16] : [UIFont systemFontOfSize:16];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// 点按后弹出的输入框。Phase 5 之前这两处是内联在 cell 里的输入框（UITextView /
// UITextField），用户要求改成点一下弹弹窗、在弹窗里输入。
//
// 不用 UIAlertController：UIAlertController 只适合塞单行输入框，多行输入框
// 放不进去，而且样式改不动；自定义 VC 想怎么排就怎么排。
//
// 骨架共用：模板和颜色两个弹窗是同一个类，区别只在配置（标题、是否多行、
// 占位提示、提示小字、保存回调）。
//   - saveHandler：点“保存”时调，入参是输入框当前文字；返回 nil 表示接受
//     （调用方已在里面存好值），弹窗关闭；返回一段错误文案表示拒绝，
//     弹窗不关闭，错误文案在弹窗内红字显示，输入框内容保留，用户可接着改。
//   - 取消：点“取消”或点遮罩空白处，直接关闭，不保存。
//   - 键盘：监听 UIKeyboardWillShow/Hide，卡片上移，保证输入框不被键盘遮住。
// =========================================================================

@interface WCPInputSheetViewController : UIViewController <UITextViewDelegate, UITextFieldDelegate>
@property (nonatomic, copy) NSString *sheetTitle;
@property (nonatomic, assign) BOOL multiline;
@property (nonatomic, copy) NSString *initialText;
@property (nonatomic, copy) NSString *placeholderText;
@property (nonatomic, copy) NSString *hintText;
@property (nonatomic, copy) NSString *(^saveHandler)(NSString *text);
@end

@implementation WCPInputSheetViewController {
    UIView *_cardView; // 外层容器：只负责圆角阴影，不裁剪。
    UIVisualEffectView *_glassView; // 玻璃层：磨砂 + 大圆角 + 细亮边 + 裁剪。
    UIView *_highlightView; // 顶部高光：卡片上沿 1pt 亮线，模拟玻璃边缘反光。
    UILabel *_titleLabel;
    UITextView *_textView;
    UILabel *_textViewPlaceholderLabel;
    UITextField *_textField;
    UILabel *_hintLabel;
    UIButton *_cancelButton;
    UIButton *_saveButton;
    CGFloat _keyboardOffset;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 遮罩比以前淡一点（0.45 → 0.30），让后面的微信页面多透出来一点，
    // 玻璃感更明显；点遮罩空白处仍是取消。
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.30];

    // 点遮罩空白处＝取消：遮罩是一个盖满全屏的按钮，卡片是它的兄弟视图、
    // 盖在它上面，所以点卡片不会误触取消。
    UIButton *dimButton = [UIButton buttonWithType:UIButtonTypeCustom];
    dimButton.frame = self.view.bounds;
    dimButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dimButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dimButton];

    // 外层容器：透明，只挂圆角阴影（阴影不能和裁剪同层，用 shadowPath 画圆角影）。
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor clearColor];
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.25;
    card.layer.shadowRadius = 20;
    card.layer.shadowOffset = CGSizeMake(0, 10);
    [self.view addSubview:card];
    _cardView = card;

    // 玻璃层：真玻璃（运行时查）或磨砂模糊回退；大圆角 28、细亮边。
    UIVisualEffectView *glass = WCPMakeGlassView(28, NO);
    [card addSubview:glass];
    _glassView = glass;

    // 顶部高光：1pt 白亮线，放在玻璃的 contentView 里（会被圆角裁剪，不会冒出去）。
    UIView *highlight = [[UIView alloc] init];
    highlight.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    [glass.contentView addSubview:highlight];
    _highlightView = highlight;

    // 下面所有内容都加到玻璃的 contentView 里（在磨砂上面，不在磨砂后面）。
    UIView *content = glass.contentView;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = self.sheetTitle;
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [content addSubview:titleLabel];
    _titleLabel = titleLabel;

    if (self.multiline) {
        UITextView *tv = [[UITextView alloc] init];
        tv.font = [UIFont systemFontOfSize:16];
        tv.textColor = [UIColor labelColor];
        // 玻璃输入框：半透明底 + 细亮边 + 圆角（不再是灰边白底）。
        tv.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        tv.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
        tv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
        tv.layer.borderWidth = 1;
        tv.layer.cornerRadius = 12;
        tv.text = self.initialText ?: @"";
        tv.delegate = self;
        // 回车即换行，收键盘靠键盘上方的“完成”按钮（沿用以前内联输入框的做法）。
        UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(doneEditing)];
        toolbar.items = @[flex, done];
        tv.inputAccessoryView = toolbar;
        [content addSubview:tv];
        _textView = tv;

        UILabel *placeholder = [[UILabel alloc] init];
        placeholder.text = self.placeholderText;
        placeholder.font = [UIFont systemFontOfSize:16];
        placeholder.textColor = [UIColor placeholderTextColor];
        placeholder.numberOfLines = 0;
        [tv addSubview:placeholder];
        _textViewPlaceholderLabel = placeholder;
        placeholder.hidden = tv.text.length > 0;
    } else {
        UITextField *field = [[UITextField alloc] init];
        field.font = [UIFont systemFontOfSize:16];
        field.textColor = [UIColor labelColor];
        // 玻璃输入框：不用系统圆角边框（不透明），改半透明底 + 细亮边 + 圆角。
        field.borderStyle = UITextBorderStyleNone;
        field.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        field.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
        field.layer.borderWidth = 1;
        field.layer.cornerRadius = 12;
        field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 0)];
        field.leftViewMode = UITextFieldViewModeAlways;
        field.placeholder = self.placeholderText;
        field.text = self.initialText ?: @"";
        field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.returnKeyType = UIReturnKeyDone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.delegate = self;
        [content addSubview:field];
        _textField = field;
    }

    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = self.hintText;
    hintLabel.font = [UIFont systemFontOfSize:11];
    hintLabel.textColor = [UIColor secondaryLabelColor];
    hintLabel.numberOfLines = 0;
    [content addSubview:hintLabel];
    _hintLabel = hintLabel;

    // 底部按钮行：两颗玻璃胶囊（取消中性、保存带主题色 tint），中间留空隙，
    // 不再是左右分半 + 分隔线的系统弹窗样式。
    UIButton *cancel = WCPMakeGlassCapsuleButton(@"取消", NO, NO, self, @selector(cancelTapped));
    [content addSubview:cancel];
    _cancelButton = cancel;

    UIButton *save = WCPMakeGlassCapsuleButton(@"保存", YES, YES, self, @selector(saveTapped));
    [content addSubview:save];
    _saveButton = save;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 弹窗一出来就弹键盘，不用再点一下输入框。
    if (self.multiline) [_textView becomeFirstResponder];
    else [_textField becomeFirstResponder];
}

// 小巧精致尺寸（Phase 5.1）：卡片宽＝屏宽 − 88、上限 340；内边距 16；
// 标题 20pt（字号 16）→ 间距 12 → 输入框（模板 88pt / 颜色 44pt）→
// 间距 6 → 提示小字（字号 11）→ 间距 12 → 按钮行 38pt（两颗玻璃胶囊，
// 中间留 12 空隙）→ 底边 16。模板输入框 88pt 至少能看三行字，够用。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat viewW = self.view.bounds.size.width;
    CGFloat viewH = self.view.bounds.size.height;
    CGFloat cardW = MIN(viewW - 88, 340);
    CGFloat pad = 16;
    CGFloat y = pad;

    _titleLabel.frame = CGRectMake(pad, y, cardW - pad * 2, 20);
    y += 20 + 12;

    if (self.multiline) {
        _textView.frame = CGRectMake(pad, y, cardW - pad * 2, 88);
        _textViewPlaceholderLabel.frame = CGRectMake(10, 8, _textView.bounds.size.width - 20, 44);
        y += 88;
    } else {
        _textField.frame = CGRectMake(pad, y, cardW - pad * 2, 44);
        y += 44;
    }
    y += 6;

    CGFloat hintW = cardW - pad * 2;
    CGRect hintRect = [_hintLabel.text boundingRectWithSize:CGSizeMake(hintW, 100)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{NSFontAttributeName: _hintLabel.font}
                                                     context:nil];
    CGFloat hintH = ceil(CGRectGetHeight(hintRect));
    _hintLabel.frame = CGRectMake(pad, y, hintW, hintH);
    y += hintH + 12;

    // 按钮行在卡片坐标里（y 是卡片内的纵坐标）。
    CGFloat buttonRowY = y;
    y += 38 + pad;
    CGFloat cardH = y;
    CGFloat cardX = (viewW - cardW) / 2;
    CGFloat cardY = (viewH - cardH) / 2 - _keyboardOffset;
    if (cardY < 20) cardY = 20;
    _cardView.frame = CGRectMake(cardX, cardY, cardW, cardH);

    // 玻璃层铺满卡片，圆角阴影按卡片形状画；顶部高光线压在卡片上沿。
    _glassView.frame = _cardView.bounds;
    _cardView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_cardView.bounds cornerRadius:28].CGPath;
    _highlightView.frame = CGRectMake(28, 0, cardW - 56, 1);

    // 两颗玻璃胶囊：各占一半减去中间空隙，高 38。
    CGFloat buttonW = (cardW - pad * 2 - 12) / 2;
    _cancelButton.frame = CGRectMake(pad, buttonRowY, buttonW, 38);
    _saveButton.frame = CGRectMake(pad + buttonW + 12, buttonRowY, buttonW, 38);
}

// 键盘弹出时把卡片往上顶，保证输入框不被键盘遮住。
// 按“未上移的卡片位置”算需要上移多少，这样重复收到通知也不会把偏移量清掉。
- (void)keyboardWillShow:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInView = [self.view convertRect:kbFrame fromView:nil];
    CGFloat keyboardTop = CGRectGetMinY(kbInView);
    CGFloat cardH = CGRectGetHeight(_cardView.frame);
    CGFloat cardYUnshifted = (CGRectGetHeight(self.view.bounds) - cardH) / 2;
    if (cardYUnshifted < 20) cardYUnshifted = 20;
    CGFloat need = (cardYUnshifted + cardH) - (keyboardTop - 12);
    _keyboardOffset = MAX(0, need);
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }];
}

- (void)keyboardWillHide:(NSNotification *)note {
    _keyboardOffset = 0;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }];
}

- (void)cancelTapped {
    // 取消：丢弃改动，直接关弹窗，不保存。
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    NSString *text = self.multiline ? _textView.text : _textField.text;
    NSString *error = self.saveHandler ? self.saveHandler(text ?: @"") : nil;
    if (error) {
        // 校验失败：弹窗不关，红字提示格式错误，输入框内容保留，用户可接着改。
        _hintLabel.text = error;
        _hintLabel.textColor = [UIColor systemRedColor];
        [self.view setNeedsLayout];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doneEditing {
    if (self.multiline) [_textView resignFirstResponder];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    _textViewPlaceholderLabel.hidden = textView.text.length > 0;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // 单行输入框回车＝保存（和点“保存”一样走校验）。
    [self saveTapped];
    return NO;
}

@end


// =========================================================================
// 红包参数 / 队列 / 操作 / 任务管理 —— 移植自 DKWechatHelper 的
// WeChatRedEnvelopParam / WBRedEnvelopParamQueue / WBReceiveRedEnvelopOperation /
// WBRedEnvelopTaskManager（DKHelper.m:291–470），类名前加 WCP 前缀。
// 两处与 DK 不同的地方：
//   1. toParams 里所有值都兜底 @""——DK 原版用 NSDictionary 字面量，某个字段为
//      nil 时会直接闪退；这里不会。
//   2. 操作的 start/main 按标准并发 NSOperation 写法：start 里先置 executing=YES
//      再调 main，main 结束时置 executing=NO、finished=YES。DK 原版在 start 里
//      先调 main、再把 finished 置回 NO，靠队列已经把操作移出才没卡死；这里不
//      依赖这种巧合。延迟固定为 0（立即开红包），Phase 6 不做延迟设置。
//   3. 任务管理只保留并发队列（最多 5 个，与 DK 的 normal 队列一致）；DK 的串行
//      队列对应“防止同时抢多个红包”开关，Phase 6 没有这个开关，先不引进来。
// =========================================================================

@interface WCPHBParam : NSObject
@property (strong, nonatomic) NSString *msgType;
@property (strong, nonatomic) NSString *sendId;
@property (strong, nonatomic) NSString *channelId;
@property (strong, nonatomic) NSString *nickName;
@property (strong, nonatomic) NSString *headImg;
@property (strong, nonatomic) NSString *nativeUrl;
@property (strong, nonatomic) NSString *sessionUserName;
@property (strong, nonatomic) NSString *sign;
@property (strong, nonatomic) NSString *timingIdentifier;
@property (assign, nonatomic) BOOL isGroupSender;
- (NSDictionary *)toParams;
@end

@implementation WCPHBParam

- (NSDictionary *)toParams {
    return @{
        @"msgType": self.msgType ?: @"",
        @"sendId": self.sendId ?: @"",
        @"channelId": self.channelId ?: @"",
        @"nickName": self.nickName ?: @"",
        @"headImg": self.headImg ?: @"",
        @"nativeUrl": self.nativeUrl ?: @"",
        @"sessionUserName": self.sessionUserName ?: @"",
        @"timingIdentifier": self.timingIdentifier ?: @""
    };
}

@end

@interface WCPHBParamQueue : NSObject
+ (instancetype)sharedQueue;
- (void)enqueue:(WCPHBParam *)param;
- (WCPHBParam *)dequeue;
@end

@implementation WCPHBParamQueue {
    NSMutableArray<WCPHBParam *> *_queue;
}

+ (instancetype)sharedQueue {
    static WCPHBParamQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ queue = [[WCPHBParamQueue alloc] init]; });
    return queue;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = [NSMutableArray array];
    }
    return self;
}

- (void)enqueue:(WCPHBParam *)param {
    if (!param) return;
    @synchronized (self) {
        [_queue addObject:param];
    }
}

- (WCPHBParam *)dequeue {
    @synchronized (self) {
        if (_queue.count == 0) return nil;
        WCPHBParam *first = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        return first;
    }
}

@end

@interface WCPHBReceiveOperation : NSOperation
- (instancetype)initWithRedEnvelopParam:(WCPHBParam *)param delay:(unsigned int)delaySeconds;
@end

@implementation WCPHBReceiveOperation {
    WCPHBParam *_redEnvelopParam;
    unsigned int _delaySeconds;
    BOOL _executing;
    BOOL _finished;
}

- (instancetype)initWithRedEnvelopParam:(WCPHBParam *)param delay:(unsigned int)delaySeconds {
    if (self = [super init]) {
        _redEnvelopParam = param;
        _delaySeconds = delaySeconds;
    }
    return self;
}

- (void)start {
    if (self.isCancelled) {
        [self willChangeValueForKey:@"isFinished"];
        _finished = YES;
        [self didChangeValueForKey:@"isFinished"];
        return;
    }
    [self willChangeValueForKey:@"isExecuting"];
    _executing = YES;
    [self didChangeValueForKey:@"isExecuting"];
    [self main];
}

- (void)main {
    @try {
        if (_delaySeconds > 0) [NSThread sleepForTimeInterval:_delaySeconds / 1000.0];
        WCRedEnvelopesLogicMgr *logicMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(WCRedEnvelopesLogicMgr)];
        [logicMgr OpenRedEnvelopesRequest:[_redEnvelopParam toParams]];
    } @catch (NSException *e) {
        // 开红包失败就静默跳过，不影响其他红包和消息流程。
    }
    [self willChangeValueForKey:@"isExecuting"];
    _executing = NO;
    [self didChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _finished = YES;
    [self didChangeValueForKey:@"isFinished"];
}

- (void)cancel {
    [self willChangeValueForKey:@"isExecuting"];
    _executing = NO;
    [self didChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _finished = YES;
    [self didChangeValueForKey:@"isFinished"];
}

- (BOOL)isFinished { return _finished; }
- (BOOL)isExecuting { return _executing; }
- (BOOL)isAsynchronous { return YES; }

@end

@interface WCPHBTaskManager : NSObject
+ (instancetype)sharedManager;
- (void)addNormalTask:(WCPHBReceiveOperation *)task;
@end

@implementation WCPHBTaskManager {
    NSOperationQueue *_normalTaskQueue;
}

+ (instancetype)sharedManager {
    static WCPHBTaskManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[WCPHBTaskManager alloc] init]; });
    return manager;
}

- (instancetype)init {
    if (self = [super init]) {
        _normalTaskQueue = [[NSOperationQueue alloc] init];
        _normalTaskQueue.maxConcurrentOperationCount = 5;
    }
    return self;
}

- (void)addNormalTask:(WCPHBReceiveOperation *)task {
    if (task) [_normalTaskQueue addOperation:task];
}

@end


// =========================================================================
// 红包解析辅助 —— 只用下标取值 + 类型检查，不用 NSDictionary 的
// stringForKey:（那是微信私有分类的方法，本文件不声明它）。
// =========================================================================

// 字典里取字符串值：不是 NSString 或为空就返回 nil。
static NSString *WCPHBStringFromDict(NSDictionary *dict, NSString *key) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    id v = dict[key];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}

// 从查询请求的 reqText 里反推 sign（DK 的 parseRequestSign 原样）：
// reqText 是 URL 编码的请求串，里面 nativeUrl 字段解码后是红包的 nativeUrl，
// 再解一次拿 sign。拿不到就返回 nil（响应处理里会直接放弃，不开红包）。
static NSString *WCPHBRequestSign(HongBaoReq *req) {
    NSData *data = req.reqText.buffer;
    if (!data.length) return nil;
    NSString *reqStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!reqStr.length) return nil;
    NSDictionary *reqDict = [%c(WCBizUtil) dictionaryWithDecodedComponets:reqStr separator:@"&"];
    NSString *nativeUrl = WCPHBStringFromDict(reqDict, @"nativeUrl");
    if (!nativeUrl.length) return nil;
    nativeUrl = [nativeUrl stringByRemovingPercentEncoding] ?: nativeUrl;
    NSRange qRange = [nativeUrl rangeOfString:@"?"];
    if (qRange.location != NSNotFound) {
        nativeUrl = [nativeUrl substringFromIndex:qRange.location + qRange.length];
    }
    NSDictionary *urlDict = [%c(WCBizUtil) dictionaryWithDecodedComponets:nativeUrl separator:@"&"];
    return WCPHBStringFromDict(urlDict, @"sign");
}


// =========================================================================
// 白名单选择页 —— 纯 UIKit 的 UITableViewController 风格 VC，列出用户的全部
// 会话（群聊在前、私聊在后），每行一个开关；开关状态即白名单内容，存 username。
// 会话列表来自 MMNewSessionMgr GetUserNamesOnSessionList（MMNewSessionMgr.h:142，
// 返回会话 username 数组，按微信会话顺序）；显示名用 CContactMgr
// getContactByName: 取联系人再 getContactDisplayName；群聊按 username 含
// "@chatroom" 区分。getContactByName 可能查库，所以在后台线程建列表，建好再
// 回主线程刷表；任何一步失败都只显示空列表，不闪退。
// =========================================================================

static const char kWCPWhitelistUsernameKey = 0;

@interface WCPWhitelistViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *groupSessions;   // 每项 @{@"username":..., @"displayName":...}
@property (nonatomic, strong) NSArray *privateSessions;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation WCPWhitelistViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择群聊/私聊";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITableView *tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                          style:UITableViewStyleInsetGrouped];
    tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableView.dataSource = self;
    tableView.delegate = self;
    [self.view addSubview:tableView];
    self.tableView = tableView;

    self.groupSessions = @[];
    self.privateSessions = @[];
    self.loaded = NO;
    [self loadSessions];
}

// 后台读会话列表，建好再回主线程刷表。
- (void)loadSessions {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *groups = @[];
        NSArray *privates = @[];
        @try {
            MMNewSessionMgr *sessionMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(MMNewSessionMgr)];
            CContactMgr *contactMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(CContactMgr)];
            id userNames = [sessionMgr GetUserNamesOnSessionList];
            if ([userNames isKindOfClass:[NSArray class]]) {
                NSMutableArray *g = [NSMutableArray array];
                NSMutableArray *p = [NSMutableArray array];
                for (id name in (NSArray *)userNames) {
                    if (![name isKindOfClass:[NSString class]] || ![(NSString *)name length]) continue;
                    NSString *username = (NSString *)name;
                    NSString *displayName = username;
                    @try {
                        CContact *contact = [contactMgr getContactByName:username];
                        NSString *dn = [contact getContactDisplayName];
                        if (dn.length) displayName = dn;
                    } @catch (NSException *e) {
                        // 联系人取不到显示名就用 username 本身，不影响选择。
                    }
                    NSDictionary *item = @{@"username": username, @"displayName": displayName};
                    if ([username rangeOfString:@"@chatroom"].location != NSNotFound) {
                        [g addObject:item];
                    } else {
                        [p addObject:item];
                    }
                }
                groups = [g copy];
                privates = [p copy];
            }
        } @catch (NSException *e) {
            // 会话列表读不到就显示空列表，不闪退。
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.groupSessions = groups;
            self.privateSessions = privates;
            self.loaded = YES;
            [self.tableView reloadData];
        });
    });
}

- (NSArray *)rowsForSection:(NSInteger)section {
    return section == 0 ? self.groupSessions : self.privateSessions;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rowsForSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"群聊" : @"私聊";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.loaded) return section == 1 ? @"正在加载会话列表…" : nil;
    if (section != 1) return nil;
    NSUInteger n = WCPWhitelistUsernames().count;
    if (n == 0) return @"未选择任何会话，不会抢红包";
    return [NSString stringWithFormat:@"已选 %lu 个会话，仅这些会话的红包会被自动抢", (unsigned long)n];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseId = @"WCPWhitelistCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *item = [self rowsForSection:indexPath.section][indexPath.row];
    cell.textLabel.text = item[@"displayName"];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = item[@"username"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = WCPIsUsernameWhitelisted(item[@"username"]);
    objc_setAssociatedObject(sw, &kWCPWhitelistUsernameKey, item[@"username"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(whitelistSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)whitelistSwitchChanged:(UISwitch *)sender {
    NSString *username = objc_getAssociatedObject(sender, &kWCPWhitelistUsernameKey);
    if (!username.length) return;
    WCPSetUsernameWhitelisted(username, sender.isOn);
    [self.tableView reloadData]; // 刷新 footer 的已选数量
}

@end


// =========================================================================
// 设置页 —— 纯 UIKit 的 UITableView，不依赖微信的 WCTableViewManager /
// UiUtil / MMUIViewController，避免引入 DK 那些辅助类。
//
// 分区（逻辑编号）：0 消息防撤回 / 1 拦截提示格式 / 2 更多功能 / 3 关于。
// 防撤回关闭时格式分区直接不显示（物理分区数 4→3，开关拨动时 reloadData
// 整表重画）；格式分区内部：首行是收起/展开开关行，展开时才有自定义格式
// 展示行、3 个预设、恢复默认、自定义颜色展示行；收起状态存 NSUserDefaults。
// 第 1 行和第 6 行是展示行，点按弹出输入弹窗（WCPInputSheetViewController），
// 在弹窗里输入；预设切换/恢复默认/弹窗保存后都用 reloadData 整表重画。
// =========================================================================

// 逻辑分区编号（与物理分区编号的换算见下面两个函数）。
enum {
    WCPSectionRevoke = 0,
    WCPSectionFormat = 1,
    WCPSectionMore = 2,
    WCPSectionAbout = 3,
};

// 格式分区可见＝防撤回已开启；关闭时物理分区只有 3 个（格式分区整个消失）。
static BOOL WCPHasFormatSection(void) { return WCPPreventRevokeEnabled(); }

// （Phase 5.1 修复：WCPPhysicalSectionForLogical 已删——Phase 5 删掉
// updateFormatCheckmarks 后它是唯一调用者，没人再用它，-Werror 会把它
// 当成未使用函数报错。反向换算 WCPLogicalSectionForPhysical 还在用。）
static NSInteger WCPLogicalSectionForPhysical(NSInteger physical) {
    // Phase 3.1 修复：这里必须是 >=，不是 >。
    // 格式分区不存在时物理分区只有 3 个：0＝防撤回，1＝更多功能，2＝关于。
    // 物理 1 其实是“更多功能”（逻辑 2），用 > 会把它错认成格式分区（逻辑 1），
    // 导致关掉开关的状态下 dataSource 给“更多功能”返回格式分区的行数/标题/footer/
    // cell，insert/deleteSections 的一致性检查失败（NSInternalInconsistencyException）
    // 直接闪退，布局也全乱（见 phase3.1-NOTES.md §1）。
    if (!WCPHasFormatSection() && physical >= WCPSectionFormat) return physical + 1;
    return physical;
}

@interface WCPSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation WCPSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"汉伯格";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITableView *tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                          style:UITableViewStyleInsetGrouped];
    tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableView.dataSource = self;
    tableView.delegate = self;
    [self.view addSubview:tableView];
    self.tableView = tableView;
}

- (void)preventRevokeSwitchChanged:(UISwitch *)sender {
    BOOL on = sender.isOn;
    BOOL wasOn = WCPPreventRevokeEnabled();
    WCPSetPreventRevokeEnabled(on);
    if (on == wasOn) return;
    // Phase 3.1：防撤回关闭时格式分区直接消失，打开时再出现（不再是变灰）。
    // 以前这里用 insert/deleteSections，但 dataSource 映射错一个字符（见上面
    // WCPLogicalSectionForPhysical 的注释）就让一致性检查失败而闪退；动画不值得
    // 再闪退一次，改成 reloadData——整表按同一份快照重画，分区/行数不可能错位。
    [self.tableView reloadData];
}

// 自动抢红包开关：只存状态，不立即生效——白名单说了算；
// 刷一下表，刷新“选择群聊/私聊”的副标题和更多功能分区 footer。
- (void)autoGrabSwitchChanged:(UISwitch *)sender {
    WCPSetAutoGrabRedPacketEnabled(sender.isOn);
    [self.tableView reloadData];
}

#pragma mark - 格式设置

// 预设切换 / 恢复默认：存完直接 reloadData 整表重画。
// Phase 5：以前这里只改可见 cell 的勾选，是为了躲
// Phase 2 整区 reload 惹的重影；但第 1 行现在是展示行，模板变了它的副标题也
// 要跟着变，单改勾选不够。reloadData 是整表按同一份快照重画（Phase 3.1 已
// 验证过，开关拨动/收起展开都在用），不会触发重影那套删除+插入动画。
- (void)applyPresetAtIndex:(NSInteger)presetIndex {
    NSArray *presets = WCPNoticeFormatPresets();
    if (presetIndex < 0 || presetIndex >= (NSInteger)presets.count) return;
    WCPSetRevokeNoticeFormat(presets[presetIndex][@"template"]);
    [self.tableView reloadData];
}

- (void)resetFormatToDefault {
    WCPSetRevokeNoticeFormat(nil);
    [self.tableView reloadData];
}

- (void)toggleFormatExpanded {
    BOOL expanded = !WCPFormatExpanded();
    WCPSetFormatExpanded(expanded);
    // Phase 3.1：以前这里用 beginUpdates + insert/deleteRows（1..6 行）再 reloadRows
    // 首行，行数本身是对得上的（展开 7 行、收起 1 行），但把删除/插入/重载三种操作
    // 混在同一个 update 里本身就是闪退高危区（Phase 3 的教训）；改成 reloadData，
    // 整表按同一份快照重画，收起/展开不可能再和别的行重叠。首行“收起 ▴ / 展开 ▾”
    // 的字样由 cellForRow 按新状态重画，不用单独刷。
    [self.tableView reloadData];
}

#pragma mark - 输入弹窗

// 模板输入弹窗（多行）。保存时任何内容都合法（留空＝默认格式），
// 存完 reloadData 刷新第 1 行副标题和第 5 行勾选。
- (void)presentFormatTemplateSheet {
    WCPInputSheetViewController *sheet = [[WCPInputSheetViewController alloc] init];
    sheet.sheetTitle = @"自定义格式";
    sheet.multiline = YES;
    sheet.initialText = WCPRevokeNoticeFormat() ?: @"";
    sheet.placeholderText = @"例如：{名字}撤回了一条消息";
    sheet.hintText = @"占位符：{名字}＝撤回者（自己显示“你”）；{内容}＝原消息文本（非文本消息为空）；{时间}＝原消息时间。模板支持换行，留空则使用默认格式。";
    __weak typeof(self) weakSelf = self;
    sheet.saveHandler = ^NSString *(NSString *text) {
        WCPSetRevokeNoticeFormat(text);
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf.tableView reloadData];
        return nil;
    };
    sheet.modalPresentationStyle = UIModalPresentationOverFullScreen;
    sheet.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:sheet animated:YES completion:nil];
}

// 颜色输入弹窗（单行）。保存时按 WCPNormalizeHexColor 校验：
// 合法 → 归一化存进 "revokeNoticeColor"；留空 → 清除颜色恢复默认灰；
// 非法 → 返回报错文案，弹窗不关闭，在弹窗内红字提示格式错误
// （见 WCPInputSheetViewController saveTapped）。
- (void)presentColorHexSheet {
    WCPInputSheetViewController *sheet = [[WCPInputSheetViewController alloc] init];
    sheet.sheetTitle = @"自定义颜色";
    sheet.multiline = NO;
    sheet.initialText = WCPRevokeNoticeColorHex() ?: @"";
    sheet.placeholderText = @"例如 FFBAC6";
    sheet.hintText = @"请输入 6 位十六进制颜色代码，例如 FFBAC6，留空恢复默认灰色";
    __weak typeof(self) weakSelf = self;
    sheet.saveHandler = ^NSString *(NSString *text) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length) {
            WCPSetRevokeNoticeColorHex(nil);
            [strongSelf.tableView reloadData];
            return nil;
        }
        NSString *normalized = WCPNormalizeHexColor(text);
        if (!normalized) {
            return @"格式不正确，请输入 6 位十六进制颜色代码，例如 FFBAC6";
        }
        WCPSetRevokeNoticeColorHex(normalized);
        [strongSelf.tableView reloadData];
        return nil;
    };
    sheet.modalPresentationStyle = UIModalPresentationOverFullScreen;
    sheet.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return WCPHasFormatSection() ? 4 : 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger logical = WCPLogicalSectionForPhysical(section);
    if (logical == WCPSectionRevoke) return 1;
    if (logical == WCPSectionFormat) return WCPFormatExpanded() ? 7 : 1;
    // 格式分区展开时的 7 行：开关行 / 自定义格式（展示行，点按弹弹窗）/ 3 个预设 / 恢复默认 / 自定义颜色（展示行，点按弹弹窗）
    if (logical == WCPSectionMore) return 7; // 自动抢红包开关 / 选择群聊·私聊 / 5 个“即将推出”占位
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger logical = WCPLogicalSectionForPhysical(section);
    if (logical == WCPSectionRevoke) return @"消息防撤回";
    // 格式分区没有独立标题：首行开关行就是标题行，避免“拦截提示格式”出现两次。
    // Phase 3.1 修复：以前这里没给格式分区单独返回 nil，逻辑 1 会掉到最后的
    // return @"关于"，导致格式分区上方凭空多一个“关于”标题（用户截图里就是它）。
    if (logical == WCPSectionFormat) return nil;
    if (logical == WCPSectionMore) return @"更多功能";
    return @"关于";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSInteger logical = WCPLogicalSectionForPhysical(section);
    if (logical == WCPSectionRevoke) {
        return @"开启后，对方撤回的消息仍会保留，并插入一条拦截提示（仅保存在本地）。防撤回可能被微信检测到，请注意账号风险。";
    }
    if (logical == WCPSectionFormat) {
        if (!WCPFormatExpanded()) return nil;
        return @"占位符：{名字}＝撤回者（自己显示“你”）；{内容}＝原消息文本（非文本消息为空）；{时间}＝原消息时间。模板支持换行，提示里会保留换行。留空则使用默认格式。颜色只对拦截提示生效，改色后新拦截的提示即生效，已显示的滑出屏幕再滑回也会变色。";
    }
    if (logical == WCPSectionMore) {
        // 开关开了但白名单还是空的，提醒用户先去选会话（否则什么都不抢）。
        if (WCPAutoGrabRedPacketEnabled() && WCPWhitelistUsernames().count == 0) {
            return @"自动抢红包已开启，但未选择任何会话，不会抢红包。请点“选择群聊/私聊”挑选要抢的会话。";
        }
        return nil;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger logical = WCPLogicalSectionForPhysical(indexPath.section);
    if (logical == WCPSectionFormat) {
        if (indexPath.row == 1) return WCPRevokeNoticeFormat() ? 66 : 44; // 展示行：有模板两行，无模板一行
        if (indexPath.row >= 2 && indexPath.row <= 4) return 66; // 预设：标题 + 两行模板
        if (indexPath.row == 6) return 44; // 自定义颜色展示行
    }
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger logical = WCPLogicalSectionForPhysical(indexPath.section);

    if (logical == WCPSectionFormat) {
        if (indexPath.row == 0) {
            // 收起/展开开关行（独立 reuseId）
            static NSString *toggleReuseId = @"WCPFormatToggleCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:toggleReuseId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:toggleReuseId];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"拦截提示格式";
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.text = WCPFormatExpanded() ? @"收起 ▴" : @"展开 ▾";
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }
        if (indexPath.row == 1) {
            // 自定义格式展示行（Phase 5：内联多行输入框改成点按弹弹窗）。
            // 副标题显示当前模板的前两行；未设置时显示“未设置，使用默认格式”。
            // 必须用独立的 Subtitle reuseId，不和预设行混用复用池。
            static NSString *templateReuseId = @"WCPFormatTemplateCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:templateReuseId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:templateReuseId];
                cell.detailTextLabel.numberOfLines = 2;
                cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"自定义格式";
            cell.textLabel.textColor = [UIColor labelColor];
            NSString *tpl = WCPRevokeNoticeFormat();
            if (tpl) {
                // 只取前两行，多余的截掉（完整内容在弹窗里改）。
                NSArray *lines = [tpl componentsSeparatedByString:@"\n"];
                if (lines.count > 2) {
                    tpl = [[lines subarrayWithRange:NSMakeRange(0, 2)] componentsJoinedByString:@"\n"];
                }
                cell.detailTextLabel.text = tpl;
            } else {
                cell.detailTextLabel.text = @"未设置，使用默认格式";
            }
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row >= 2 && indexPath.row <= 4) {
            // 预设：上下两行（标题 + 模板），模板多行完整显示。
            // 必须用独立的 Subtitle reuseId，不能和 Value1 的行混用一个复用池，
            // 否则取到的 cell 样式不对，模板又会挤到标题同一行。
            static NSString *presetReuseId = @"WCPFormatPresetCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:presetReuseId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:presetReuseId];
                cell.detailTextLabel.numberOfLines = 0;
                cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            NSArray *presets = WCPNoticeFormatPresets();
            NSDictionary *preset = presets[indexPath.row - 2];
            cell.textLabel.text = [@"预设 · " stringByAppendingString:preset[@"title"]];
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.text = preset[@"template"];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            NSString *currentTpl = WCPRevokeNoticeFormat();
            cell.accessoryType = [preset[@"template"] isEqualToString:currentTpl] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            return cell;
        }
        if (indexPath.row == 5) {
            // 恢复默认
            static NSString *reuseId = @"WCPSettingsCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseId];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryView = nil;
            cell.textLabel.text = @"恢复默认";
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.text = @"使用原来的默认格式";
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = (WCPRevokeNoticeFormat() == nil) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            return cell;
        }
        // row 6：自定义颜色展示行（Phase 5：内联单行输入框改成点按弹弹窗）。
        static NSString *colorReuseId = @"WCPFormatColorCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:colorReuseId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:colorReuseId];
        }
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = @"自定义颜色";
        cell.textLabel.textColor = [UIColor labelColor];
        NSString *storedHex = WCPRevokeNoticeColorHex();
        cell.detailTextLabel.text = storedHex ?: @"默认灰色";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    static NSString *reuseId = @"WCPSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseId];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = [UIColor labelColor];

    if (logical == WCPSectionRevoke) {
        // 防撤回开关
        cell.textLabel.text = @"消息防撤回";
        UISwitch *revokeSwitch = [[UISwitch alloc] init];
        revokeSwitch.on = WCPPreventRevokeEnabled();
        [revokeSwitch addTarget:self
                         action:@selector(preventRevokeSwitchChanged:)
               forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = revokeSwitch;
    } else if (logical == WCPSectionMore) {
        if (indexPath.row == 0) {
            // 自动抢红包开关（默认关闭；开关本身不立即生效，白名单说了算）。
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"自动抢红包";
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.text = nil;
            UISwitch *grabSwitch = [[UISwitch alloc] init];
            grabSwitch.on = WCPAutoGrabRedPacketEnabled();
            [grabSwitch addTarget:self
                           action:@selector(autoGrabSwitchChanged:)
                 forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = grabSwitch;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            // 选择群聊/私聊：点进去是白名单选择页；副标题显示已选数量。
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"选择群聊/私聊";
            cell.textLabel.textColor = [UIColor labelColor];
            NSUInteger n = WCPWhitelistUsernames().count;
            cell.detailTextLabel.text = (n == 0) ? @"未选择" : [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)n];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // 占位行：后续阶段再实现
            NSArray *comingSoon = @[@"修改微信步数",
                                    @"小游戏作弊（剪刀石头布 / 骰子）",
                                    @"朋友圈转发",
                                    @"集赞助手",
                                    @"好友关系检测"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = comingSoon[indexPath.row - 2];
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.text = @"即将推出";
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"当前版本";
            cell.detailTextLabel.text = @"HBG · Phase 6.1 · 适配微信 8.0.79";
        } else {
            cell.textLabel.text = @"来源";
            cell.detailTextLabel.text = @"移植自 DKWechatHelper v1.1.0";
        }
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger logical = WCPLogicalSectionForPhysical(indexPath.section);
    if (logical == WCPSectionMore) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (indexPath.row == 1) {
            // 白名单选择页随时都能进（开关没开也能先选好，开关开了才生效）。
            WCPWhitelistViewController *vc = [[WCPWhitelistViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    if (logical != WCPSectionFormat) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        [self toggleFormatExpanded];
    } else if (indexPath.row == 1) {
        [self presentFormatTemplateSheet];
    } else if (indexPath.row >= 2 && indexPath.row <= 4) {
        [self applyPresetAtIndex:indexPath.row - 2];
    } else if (indexPath.row == 5) {
        [self resetFormatToDefault];
    } else if (indexPath.row == 6) {
        [self presentColorHexSheet];
    }
}

@end


// =========================================================================
// Hook 1：MMServiceCenter — 补一个 DK 自有的 +defaultCenter（8.0.79 原生没有，
// 但防撤回代码要靠它拿 CContactMgr；依赖的 MMContext +currentContext 和
// serviceCenter 属性在 8.0.79 里都在：MMContext.h:50 / :59）。
// =========================================================================

%hook MMServiceCenter
%new
+ (id)defaultCenter {
    return [[%c(MMContext) currentContext] serviceCenter];
}
%end


// =========================================================================
// Hook 2：设置入口 —— NewSettingViewController reloadTableData 里加一行
// “汉伯格”，点进 WCPSettingsViewController。
//   - normalCellForSel 改用 8.0.79 真实存在的四参数版（accessoryType: 1，带箭头）；
//   - 跳转改用系统标准 pushViewController:animated:，不用 DK 自带头文件里声明的
//     PushViewController:animated:（那是 DK 手写的 UINavigationController 分类方法）。
// =========================================================================

%hook NewSettingViewController

- (void)reloadTableData {
    %orig;
    // 用系统 runtime 直接读 ivar：Theos 自带的 substrate.h 里没有 MSHookIvar，
    // 改用 object_getIvar 就不依赖它了。m_tableViewMgr 在 8.0.79 里仍在
    //（NewSettingViewController.h:11）。
    WCTableViewManager *tableViewMgr = object_getIvar(self, class_getInstanceVariable([self class], "m_tableViewMgr"));
    if (!tableViewMgr || tableViewMgr.sections.count == 0) return;
    UITableView *tableView = [tableViewMgr getTableView];
    WCTableViewNormalCellManager *newCell =
        [%c(WCTableViewNormalCellManager) normalCellForSel:@selector(openWCPSettings)
                                                     target:self
                                                      title:@"汉伯格"
                                              accessoryType:1];
    [((WCTableViewSectionManager *)tableViewMgr.sections[0]) addCell:newCell];
    [tableView reloadData];
}

%new
- (void)openWCPSettings {
    WCPSettingsViewController *vc = [[WCPSettingsViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

%end


// =========================================================================
// Hook 3：提示点按跳转 + 提示改色 —— SystemMessageCellView。
// 点按（详见 phase2-NOTES.md §1）：onAppear 时挂一个点按手势。
//   - 拦截提示是 msgType 0x2710 的系统消息，渲染它的就是 SystemMessageCellView，
//     其 viewModel.messageWrap 就是这条提示的 wrap；
//   - 系统消息 cell 自己处理 touches，tableView:didSelectRowAtIndexPath:
//     不一定会被调到，自己挂手势最稳，不依赖微信内部的点按分发；
//   - 手势 target 用单例（不持有 cell），避免 cell ↔ recognizer 循环引用；
//   - cancelsTouchesInView = NO，不干扰微信自己的点按/长按处理；
//   - 复用时不再重复挂（associated object 标记），点按时才读当前 viewModel。
// 改色（Phase 3 新增）：layoutContentView 之后调 WCPApplyNoticeColorToCell，
//   onAppear 里也调一次（双保险：样式在布局前已由 viewModel 建好，
//   两处调用都是幂等的，无变化时不触发重绘）。
// 若真机上 onAppear 没被调到（手势挂不上），手势改挂到 layoutContentView 里。
// =========================================================================

static const char kWCPJumpTapAttachedKey = 0;

%hook SystemMessageCellView

- (void)onAppear {
    %orig;
    WCPApplyNoticeColorToCell(self);
    if (objc_getAssociatedObject(self, &kWCPJumpTapAttachedKey)) return;
    objc_setAssociatedObject(self, &kWCPJumpTapAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[WCPNoticeTapHandler sharedHandler]
                                                                          action:@selector(handleNoticeTap:)];
    tap.cancelsTouchesInView = NO;
    [self addGestureRecognizer:tap];
}

- (void)layoutContentView {
    %orig;
    WCPApplyNoticeColorToCell(self);
}

%end


// =========================================================================
// Hook 4：消息防撤回 —— CMessageMgr onNewSyncNotAddDBMessage:
// 撤回通知是以 <sysmsg type="revokemsg"> 的同步消息到达的，解析出 session /
// newmsgid / 撤回者名字，用 GetMsg 取回被撤回的原消息，再用 AddLocalMsg 插一条
// 本地拦截提示；然后直接 return，不调 %orig，撤回就不生效。
//
// Phase 2 新增：
//   - 提示文案按自定义模板生成（模板为空时保持 Phase 1 的原 4 种默认文案）；
//   - 插提示后记映射：提示 localID（读不到时用 GetMsgSeqMaxLocalId: 兜底）和
//     session+createTime → 原消息 localID，供点按跳转查。
//
// 防闪退保护（Phase 1 已有）：解析不到标签、或 GetMsg 取不到原消息时，
// 不拦截，走 %orig，让撤回正常生效。
// =========================================================================

%hook CMessageMgr

- (void)onNewSyncNotAddDBMessage:(CMessageWrap *)arg1 {
    NSString *msgContent = arg1.m_nsContent;
    if (![msgContent hasPrefix:@"<sysmsg type=\"revokemsg\"><revokemsg>"]) {
        %orig;
        return;
    }

    if (!WCPPreventRevokeEnabled()) {
        %orig;
        return;
    }

    // 从撤回 sysmsg 的 XML 里取参数；任一标签找不到就放弃拦截，让撤回正常走。
    NSString *(^parseParam)(NSString *, NSString *, NSString *) = ^NSString *(NSString *content,
                                                                              NSString *paramBegin,
                                                                              NSString *paramEnd) {
        NSRange beginRange = [content rangeOfString:paramBegin];
        NSRange endRange = [content rangeOfString:paramEnd];
        if (beginRange.location == NSNotFound || endRange.location == NSNotFound) return nil;
        NSUInteger startIndex = beginRange.location + beginRange.length;
        if (endRange.location < startIndex) return nil;
        return [content substringWithRange:NSMakeRange(startIndex, endRange.location - startIndex)];
    };

    NSString *session = parseParam(msgContent, @"<session>", @"</session>");
    NSString *newmsgid = parseParam(msgContent, @"<newmsgid>", @"</newmsgid>");
    NSString *fromUsrName = parseParam(msgContent, @"<![CDATA[", @"撤回了一条消息");
    if (!session.length || !newmsgid.length || !fromUsrName.length) {
        %orig;
        return;
    }

    CMessageWrap *revokemsg = [self GetMsg:session n64SvrID:[newmsgid longLongValue]];
    if (!revokemsg) {
        %orig;
        return;
    }

    CContactMgr *contactMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(CContactMgr)];
    CContact *selfContact = [contactMgr getSelfContact];
    BOOL isSelf = [revokemsg.m_nsFromUsr isEqualToString:selfContact.m_nsUsrName];
    NSString *displayName = isSelf ? @"你" : fromUsrName;
    NSString *displayContent = (revokemsg.m_uiMessageType == 1) ? (revokemsg.m_nsContent ?: @"") : @"";

    NSString *newMsgContent = nil;
    NSString *tpl = WCPRevokeNoticeFormat();
    if (tpl) {
        // 自定义模板：{名字} {内容} {时间}，{时间} 取原消息的发送时间。
        newMsgContent = WCPApplyNoticeTemplate(tpl, displayName, displayContent, revokemsg.m_uiCreateTime);
    } else {
        // 默认格式（Phase 1 原样）：自己撤回 / 他人撤回 × 文本 / 非文本。
        if (isSelf) {
            if (revokemsg.m_uiMessageType == 1) {       // 文本消息
                newMsgContent = [NSString stringWithFormat:@"拦截到你撤回了一条消息：\n %@", revokemsg.m_nsContent];
            } else {
                newMsgContent = @"拦截到你撤回一条消息";
            }
        } else {
            if (revokemsg.m_uiMessageType == 1) {
                newMsgContent = [NSString stringWithFormat:@"拦截到一条 %@撤回消息：\n %@", fromUsrName, revokemsg.m_nsContent];
            } else {
                newMsgContent = [NSString stringWithFormat:@"拦截到一条 %@撤回消息", fromUsrName];
            }
        }
    }

    CMessageWrap *newWrap = [[%c(CMessageWrap) alloc] initWithMsgType:0x2710];
    [newWrap setM_nsFromUsr:revokemsg.m_nsFromUsr];
    [newWrap setM_nsToUsr:revokemsg.m_nsToUsr];
    [newWrap setM_uiStatus:0x4];
    [newWrap setM_nsContent:newMsgContent];
    [newWrap setM_uiCreateTime:[arg1 m_uiCreateTime]];

    [self AddLocalMsg:session MsgWrap:newWrap fixTime:YES NewMsgArriveNotify:NO];

    // 记映射，供点按跳转查。AddLocalMsg 后 wrap 上一般已有 localID（DB 分配），
    // 读不到就用该会话当前最大 localID 兜底（刚插完，最大的一条就是这条提示）。
    unsigned int noticeLocalID = newWrap.m_uiMesLocalID;
    if (noticeLocalID == 0) noticeLocalID = [self GetMsgSeqMaxLocalId:session];
    unsigned int origLocalID = revokemsg.m_uiMesLocalID;
    if (origLocalID != 0) {
        if (noticeLocalID != 0) {
            WCPNoticeMapSet([NSString stringWithFormat:@"%@|L%u", session, noticeLocalID], origLocalID);
        }
        WCPNoticeMapSet([NSString stringWithFormat:@"%@|T%u", session, newWrap.m_uiCreateTime], origLocalID);
    }
    return;
}

// Phase 6 新增：自动抢红包检测 —— CMessageMgr onNewSyncAddMessage:。
// 链路（DK 原样，见 phase6-NOTES.md §1）：type 49 且内容含 wxpay:// 的消息 →
// 解析 m_oWCPayInfoItem.m_c2cNativeUrl → 查白名单 → ReceiverQueryRedEnvelopesRequest:
// 查询 → 查询响应回来再开红包（见下面 %hook WCRedEnvelopesLogicMgr）。
// 判断链（缺一不可，任一不满足就直接返回，什么都不做）：
//   开关开着 → type 49 红包消息 → nativeUrl 能拿到 → 不是自己发的 →
//   会话在白名单里 → nativeUrl 里有 sendId。
// 安全：%orig 永远先调（消息本身正常显示）；整个方法包在 @try/@catch 里，
// 解析或调用一出异常就静默跳过，绝不能影响消息流程。
- (void)onNewSyncAddMessage:(CMessageWrap *)wrap {
    %orig;
    @try {
        if (!WCPAutoGrabRedPacketEnabled()) return;
        if (!wrap || wrap.m_uiMessageType != 49) return;
        NSString *content = wrap.m_nsContent;
        if (!content.length || [content rangeOfString:@"wxpay://"].location == NSNotFound) return;
        NSString *nativeUrl = wrap.m_oWCPayInfoItem.m_c2cNativeUrl;
        if (!nativeUrl.length) return;

        CContactMgr *contactMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(CContactMgr)];
        CContact *selfContact = [contactMgr getSelfContact];
        if (!selfContact) return;
        NSString *selfUserName = selfContact.m_nsUsrName;
        // 自己发的红包不抢（自己发的群红包没有 sign，走另一条校验分支；Phase 6 不抢自己的）。
        if (selfUserName.length && [wrap.m_nsFromUsr isEqualToString:selfUserName]) return;

        // 会话＝消息来源方：群聊消息 m_nsFromUsr 是群 username，私聊是对方 username。
        NSString *session = wrap.m_nsFromUsr;
        if (!session.length) return;
        if (!WCPIsUsernameWhitelisted(session)) return;

        // 解析 nativeUrl：取 ? 后面的查询串，用 WCBizUtil 解码。
        NSRange qRange = [nativeUrl rangeOfString:@"?"];
        if (qRange.location == NSNotFound) return;
        NSString *query = [nativeUrl substringFromIndex:qRange.location + qRange.length];
        if (!query.length) return;
        NSDictionary *urlDict = [%c(WCBizUtil) dictionaryWithDecodedComponets:query separator:@"&"];
        if (![urlDict isKindOfClass:[NSDictionary class]]) return;
        NSString *sendId = WCPHBStringFromDict(urlDict, @"sendid");
        if (!sendId.length) return;

        // 发查询请求（服务端返回走 OnWCToHongbaoCommonResponse:Request:）。
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        params[@"agreeDuty"] = @"0";
        NSString *channelId = WCPHBStringFromDict(urlDict, @"channelid");
        if (channelId) params[@"channelId"] = channelId;
        params[@"inWay"] = @"0";
        NSString *msgType = WCPHBStringFromDict(urlDict, @"msgtype");
        if (msgType) params[@"msgType"] = msgType;
        params[@"nativeUrl"] = nativeUrl;
        params[@"sendId"] = sendId;
        WCRedEnvelopesLogicMgr *logicMgr = [[%c(MMServiceCenter) defaultCenter] getService:%c(WCRedEnvelopesLogicMgr)];
        if (!logicMgr) return;
        [logicMgr ReceiverQueryRedEnvelopesRequest:params];

        // 入队，等查询响应回来再开（响应处理见下面的 hook）。
        WCPHBParam *hbParam = [[WCPHBParam alloc] init];
        hbParam.msgType = msgType ?: @"";
        hbParam.sendId = sendId;
        hbParam.channelId = channelId ?: @"";
        hbParam.nickName = [selfContact getContactDisplayName] ?: @"";
        hbParam.headImg = selfContact.m_nsHeadImgUrl ?: @"";
        hbParam.nativeUrl = nativeUrl;
        hbParam.sessionUserName = session;
        hbParam.sign = WCPHBStringFromDict(urlDict, @"sign") ?: @"";
        hbParam.isGroupSender = NO; // 自己发的已在上面跳过，这里恒为 NO
        [[WCPHBParamQueue sharedQueue] enqueue:hbParam];
    } @catch (NSException *e) {
        // 解析/调用异常就静默跳过，绝不能影响消息正常显示（%orig 已调过）。
    }
}

%end


// =========================================================================
// Hook 5：抢红包查询响应 —— WCRedEnvelopesLogicMgr
// OnWCToHongbaoCommonResponse:Request:。
// 链路（DK 原样）：只有 cgiCmdid == 3（参数查询的响应）才处理；从队列里取出发
// 查询时入队的参数；解析响应 JSON，校验 receiveStatus != 2（自己已抢过）、
// hbStatus != 4（已抢完）、有 timingIdentifier（缺这个字段会被判外挂，直接
// 放弃；按 DK 只判断存在性，字符串直接用、数字转字符串——Phase 6.1）、sign 对得上（请求原文里的 sign 和入队时的 sign 一致；自己发的群红包
// 没有 sign，DK 那里跳过校验——Phase 6 不抢自己的，所以这里恒做校验）；
// 都通过才把 timingIdentifier 填进参数，起一个开红包操作（延迟 0，立即开）
// 放进任务队列（并发最多 5 个）。
// 安全：%orig 永远先调；队列为空（不是我们发起的查询，比如用户手动抢红包）
// 就直接返回；整个方法包在 @try/@catch 里，异常静默跳过。
// =========================================================================

%hook WCRedEnvelopesLogicMgr

- (void)OnWCToHongbaoCommonResponse:(HongBaoRes *)arg1 Request:(HongBaoReq *)arg2 {
    %orig;
    @try {
        if (!WCPAutoGrabRedPacketEnabled()) return;
        if (!arg1 || arg1.cgiCmdid != 3) return;
        WCPHBParam *hbParam = [[WCPHBParamQueue sharedQueue] dequeue];
        if (!hbParam) return; // 不是我们发起的查询（比如手动抢红包），不处理

        NSData *respData = arg1.retText.buffer;
        if (!respData.length) return;
        id respObj = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
        if (![respObj isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *resp = respObj;
        // 自己已经抢过
        if ([resp[@"receiveStatus"] integerValue] == 2) return;
        // 红包被抢完
        if ([resp[@"hbStatus"] integerValue] == 4) return;
        // 没有这个字段会被判定为使用外挂。
        // DK 只判断存在性（dkhelperDylib.xm:338：if (!responseDict[@"timingIdentifier"]);
        // Phase 6 原来只认 NSString——8.0.79 若返回数字会被直接放弃，白白漏抢。
        // 这里按 DK 的语义对齐：字符串直接用，数字转成字符串，其他类型/空值才放弃。
        id timingIdObj = resp[@"timingIdentifier"];
        NSString *timingId = nil;
        if ([timingIdObj isKindOfClass:[NSString class]]) timingId = timingIdObj;
        else if ([timingIdObj isKindOfClass:[NSNumber class]]) timingId = [timingIdObj stringValue];
        if (!timingId.length) return;

        // sign 校验：请求原文里的 sign 必须和入队时的 sign 一致。
        // 自己发的群红包没有 sign，DK 那里跳过校验；Phase 6 不抢自己的，
        // 所以 isGroupSender 恒为 NO，这里恒做校验。
        if (!hbParam.isGroupSender) {
            NSString *reqSign = WCPHBRequestSign(arg2);
            if (!reqSign.length || ![reqSign isEqualToString:hbParam.sign]) return;
        }

        hbParam.timingIdentifier = timingId;
        WCPHBReceiveOperation *op = [[WCPHBReceiveOperation alloc] initWithRedEnvelopParam:hbParam delay:0];
        [[WCPHBTaskManager sharedManager] addNormalTask:op];
    } @catch (NSException *e) {
        // 解析/调用异常就静默跳过，不影响其他红包和消息流程。
    }
}

%end


// =========================================================================
// 加载弹窗已按用户要求去掉：插件静默加载，不再弹任何提示。
// 想确认插件是否加载成功，进微信设置看有没有“汉伯格”那一行。
// =========================================================================
