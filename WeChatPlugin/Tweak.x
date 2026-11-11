// WeChatPlugin — Phase 1：设置入口 + 消息防撤回（适配微信 8.0.79）
//
// 来源：移植自 DKJone/DKWechatHelper v1.1.0（针对微信 8.0.38），按
// ~/workspace/your_files/WeChat-8.0.79-headers/DKWechatHelper-8.0.79-compat.md
// 的核对结果逐项改写，只保留 8.0.79 头文件里真实存在的类/方法声明。
// 详见同目录 phase1-NOTES.md。
//
// 包含：
//   1. %ctor：微信启动 2 秒后弹“插件已加载”（沿用入门架子的写法，connectedScenes
//      取窗口，不用已废弃的 keyWindow）。
//   2. 设置入口：在 NewSettingViewController reloadTableData 里加一行“微信小助手”，
//      点进设置页（WCPSettingsViewController，纯 UIKit 实现）。
//   3. 消息防撤回：hook CMessageMgr onNewSyncNotAddDBMessage:，解析撤回 sysmsg，
//      取回原消息后插一条本地拦截提示。默认开启，设置页开关控制。
//
// 不包含（后续阶段再做）：自动抢红包、步数、小游戏、CallKit、朋友圈转发、集赞、
// 好友检测、动态背景/启动图、反检测层。也不含 DK 的 CaptainHook、Cycript、Trace、
// 调试 NSLog hook、QGVAPlayer/.metal/vap 资源。

#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>


// =========================================================================
// 最小微信接口声明 —— 只声明本文件实际用到的类/方法，且只以 8.0.79 头文件为准。
// （不要照抄 DK 自带的 wechatHeaders，那是 8.0.38 的旧声明，里面有 8.0.79 已不
// 存在的 onRevokeMsg: 等内容。）
// =========================================================================

@interface MMServiceCenter : NSObject
- (id)getService:(Class)service;
// 由本文件 %hook MMServiceCenter 经 %new 加上的方法（8.0.79 原生没有）。
// 这里声明出来是为了让编译器认识它——Theos 默认 -Werror，未声明的方法调用会编不过。
+ (id)defaultCenter;
@end

@interface MMContext : NSObject
+ (id)currentContext;
@property (readonly, nonatomic) MMServiceCenter *serviceCenter;
@end

// 8.0.79 里 m_nsUsrName 等字段在父类 CBaseContact 上（CBaseContact.h:133），
// CContact 继承后仍可访问；DK 的旧声明把字段写在 CContact 上，已按报告 §4.2 移过来。
@interface CBaseContact : NSObject
@property (retain, nonatomic) NSString *m_nsUsrName;
@end

@interface CContact : CBaseContact
@end

@interface CContactMgr : NSObject
- (id)getSelfContact;
@end

@interface CMessageWrap : NSObject
@property (retain, nonatomic) NSString *m_nsContent;
@property (nonatomic) unsigned int m_uiMessageType;
@property (retain, nonatomic) NSString *m_nsToUsr;
@property (retain, nonatomic) NSString *m_nsFromUsr;
@property (nonatomic) unsigned int m_uiStatus;
@property (nonatomic) unsigned int m_uiCreateTime;
- (id)initWithMsgType:(long long)arg1;
@end

@interface CMessageMgr : NSObject
- (void)onNewSyncNotAddDBMessage:(id)arg1;
- (id)GetMsg:(id)arg1 n64SvrID:(long long)arg2;
- (void)AddLocalMsg:(id)arg1 MsgWrap:(id)arg2 fixTime:(BOOL)arg3 NewMsgArriveNotify:(BOOL)arg4;
@end

@interface WCTableViewManager : NSObject
@property (retain, nonatomic) NSMutableArray *sections;
- (id)getTableView;
@end

@interface WCTableViewSectionManager : NSObject
- (void)addCell:(id)arg1;
@end

@interface WCTableViewNormalCellManager : NSObject
// 注意：8.0.79 里没有 DK 用的三参数版 normalCellForSel:target:title:，
// 最短的是这个带 accessoryType: 的四参数版（WCTableViewNormalCellManager.h:29）。
+ (id)normalCellForSel:(SEL)arg1 target:(id)arg2 title:(id)arg3 accessoryType:(long long)arg4;
@end

@interface NewSettingViewController : UIViewController
- (void)reloadTableData;
@end


// =========================================================================
// 开关存储 —— NSUserDefaults，key 与 DK 保持一致（"preventRevoke"），
// 但默认开启：从未存过值时返回 YES（DK 原版默认是 NO）。
// =========================================================================

static NSString * const kWCPPreventRevokeKey = @"preventRevoke";

static BOOL WCPPreventRevokeEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kWCPPreventRevokeKey] == nil) return YES;
    return [defaults boolForKey:kWCPPreventRevokeKey];
}

static void WCPSetPreventRevokeEnabled(BOOL enabled) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kWCPPreventRevokeKey];
    [defaults synchronize];
}


// =========================================================================
// 设置页 —— 纯 UIKit 的 UITableView，不依赖微信的 WCTableViewManager /
// UiUtil / MMUIViewController，避免引入 DK 那些辅助类。
// =========================================================================

@interface WCPSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation WCPSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微信小助手";
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
    WCPSetPreventRevokeEnabled(sender.isOn);
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 6;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"消息防撤回";
    if (section == 1) return @"更多功能";
    return @"关于";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"开启后，对方撤回的消息仍会保留，并插入一条拦截提示（仅保存在本地）。防撤回可能被微信检测到，请注意账号风险。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseId = @"WCPSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseId];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.textColor = [UIColor labelColor];

    if (indexPath.section == 0) {
        // 防撤回开关（唯一可交互项）
        cell.textLabel.text = @"消息防撤回";
        UISwitch *revokeSwitch = [[UISwitch alloc] init];
        revokeSwitch.on = WCPPreventRevokeEnabled();
        [revokeSwitch addTarget:self
                         action:@selector(preventRevokeSwitchChanged:)
               forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = revokeSwitch;
    } else if (indexPath.section == 1) {
        // 占位行：后续阶段再实现
        NSArray *comingSoon = @[@"自动抢红包",
                                @"修改微信步数",
                                @"小游戏作弊（剪刀石头布 / 骰子）",
                                @"朋友圈转发",
                                @"集赞助手",
                                @"好友关系检测"];
        cell.textLabel.text = comingSoon[indexPath.row];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = @"即将推出";
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"当前版本";
            cell.detailTextLabel.text = @"Phase 1 · 适配微信 8.0.79";
        } else {
            cell.textLabel.text = @"来源";
            cell.detailTextLabel.text = @"移植自 DKWechatHelper v1.1.0";
        }
    }
    return cell;
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
// “微信小助手”，点进 WCPSettingsViewController。
// 改动（相对 DK）：
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
                                                      title:@"微信小助手"
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
// Hook 3：消息防撤回 —— CMessageMgr onNewSyncNotAddDBMessage:
// 做法与 DK 完全一致（DK 本来就没 hook onRevokeMsg:，所以它在 8.0.79 里消失
// 不影响这份代码）：撤回通知是以 <sysmsg type="revokemsg"> 的同步消息到达的，
// 解析出 session / newmsgid / 撤回者名字，用 GetMsg 取回被撤回的原消息，再用
// AddLocalMsg 插一条本地拦截提示；然后直接 return，不调 %orig，撤回就不生效。
//
// 相对 DK 加的保护（防闪退）：
//   - 解析不到 <session>/<newmsgid>/撤回者名字时，不拦截，走 %orig；
//   - GetMsg 取不到原消息（本地库里没有）时，不拦截，走 %orig。
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
    NSString *newMsgContent = @"";

    if ([revokemsg.m_nsFromUsr isEqualToString:selfContact.m_nsUsrName]) {
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

    CMessageWrap *newWrap = [[%c(CMessageWrap) alloc] initWithMsgType:0x2710];
    [newWrap setM_nsFromUsr:revokemsg.m_nsFromUsr];
    [newWrap setM_nsToUsr:revokemsg.m_nsToUsr];
    [newWrap setM_uiStatus:0x4];
    [newWrap setM_nsContent:newMsgContent];
    [newWrap setM_uiCreateTime:[arg1 m_uiCreateTime]];

    [self AddLocalMsg:session MsgWrap:newWrap fixTime:YES NewMsgArriveNotify:NO];
    return;
}

%end


// =========================================================================
// %ctor：加载成功标志 —— 微信启动 2 秒后弹“插件已加载”。
// 沿用入门架子的写法（connectedScenes 取窗口，不用已废弃的 keyWindow）。
// =========================================================================

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *window = nil;
            // iOS 13+ 取窗口的兼容写法
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    window = ((UIWindowScene *)scene).windows.firstObject;
                    break;
                }
            }
            if (!window) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        window = ((UIWindowScene *)scene).windows.firstObject;
                        break;
                    }
                }
            }
            UIViewController *root = window.rootViewController;
            if (!root) return;

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"插件已加载"
                                                                           message:@"WeChat 插件测试成功，注入流程跑通了。"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            [root presentViewController:alert animated:YES completion:nil];
        });
    }
}
