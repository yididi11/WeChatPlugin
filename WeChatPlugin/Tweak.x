#import <UIKit/UIKit.h>

// WeChat 插件入门模板 - Hello World
// 目标：微信启动 2 秒后弹一个窗，证明插件已经注入成功。
// 这个版本不依赖微信内部类名，所以换微信版本也不容易失效。
// 真功能（比如防撤回）是在这个基础上，再去 Hook 微信内部的方法。

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *window = nil;
            // iOS 13+ 取 keyWindow 的兼容写法
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    window = ((UIWindowScene *)scene).windows.firstObject;
                    break;
                }
            }
            if (!window) {
                window = [UIApplication sharedApplication].keyWindow;
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

// ---------------------------------------------------------
// 进阶示例（先注释掉，别直接用）：防撤回的思路
// 微信不同版本类名/方法名会变，正式做之前要先用 class-dump / Frida
// 导出当前微信版本的头文件，确认方法名再写。
//
// %hook CMessageMgr
// - (void)onRevokeMsg:(id)arg1 {
//     // 不调用 %orig，就等于拦截了撤回
//     // return;
//     %orig;
// }
// %end
// ---------------------------------------------------------
