# WeChat 插件入门 - 制作步骤（零基础版）

目标：做一个 iPhone 版微信插件，用开发者证书签名注入安装，不用越狱、不用巨魔、不用 Mac。

先定好路线：插件 = 一个 dylib 文件，微信启动时加载它。
我们先做最小的版本：微信打开 2 秒后弹一个窗“插件已加载”，跑通注入流程，再上真功能。

---

## 第 1 步：准备 3 样东西

1. 解密版微信 IPA（App Store 直接下的 IPA 是加密的，注入不了）
2. 开发者证书：.p12 + .mobileprovision，你说你有了，就用你那个
3. 这个架子里的代码：`WeChatPlugin/Tweak.x`

## 第 2 步：理解插件长什么样

- `WeChatPlugin/Tweak.x`：插件的全部代码，现在只有 1 个功能——启动后弹窗。
  想加功能，就是在这里加 Hook：找到微信内部的一个方法，把它换成自己的。
  比如防撤回，思路就是拦截撤回消息的方法，让它不执行。不同微信版本方法名会变，正式做要先导出当前版本的头文件确认。
- `WeChatPlugin/Makefile`：编译配置，不用改。
- `WeChatPlugin/control`：插件的包名、版本号。
- `WeChatPlugin/WeChatPlugin.plist`：只让插件在微信里生效（com.tencent.xin）。

零基础先记住一句话就行：改功能 = 改 `Tweak.x`。

## 第 3 步：编译出 dylib（不用 Mac）

把这个文件夹传到 GitHub 公开/私有仓库，里面已经带了 `.github/workflows/build.yml`。

操作：
1. 进仓库 → Actions → 选 Build WeChatPlugin → Run workflow
2. 等它跑完，在 Artifacts 里下载 `WeChatPlugin-dylib`
3. 里面就是编译好的 `WeChatPlugin.dylib`

这一步就是在 GitHub 的 Mac 服务器上编译，你本地不用装 Xcode。

## 第 4 步：把 dylib 注入微信 IPA

用 ESign / AltStore 这类签名工具最省事，流程都一样：

1. 打开 ESign，导入解密版微信 IPA
2. 在“注入动态库 / Inject Dylib”里，选第 3 步编好的 `WeChatPlugin.dylib`
3. 导入你的开发者证书（.p12 + .mobileprovision）
4. 签名，生成一个新的 IPA

手动注入的原理也一样：解压 IPA → 把 dylib 放进 `Payload/WeChat.app/Frameworks/` → 用 insert_dylib 给主程序加一条加载指令 → 重签。ESign 是把这几步帮你做了。

## 第 5 步：安装、测试

1. 把签名好的 IPA 装到手机上
2. 打开微信，等 2 秒
3. 如果弹出“插件已加载”，说明注入成功，整条路跑通了

如果没弹窗：先检查 IPA 是不是解密版、dylib 有没有注入成功、证书有没有过期。

## 第 6 步：再做真功能

跑通弹窗之后，再按这个顺序加功能：

1. 先定一个功能，比如防撤回、消息增强、界面改动，只做一个
2. 导出当前微信版本的类头文件，找到对应的类和方法
3. 在 `Tweak.x` 里用 `%hook 类名` + 方法名写 Hook
4. 重新走第 3-5 步编译、注入、安装测试

不要一次加好几个功能，出问题不好定位。

## 第 7 步：迭代

每次只改一小点，改完就编译测试。插件开发大部分时间都在“改一点、测一下”这个循环里。

---

## 文件清单

- `WeChatPlugin/Tweak.x` - 插件代码
- `WeChatPlugin/Makefile` - 编译配置
- `WeChatPlugin/control` - 包信息
- `WeChatPlugin/WeChatPlugin.plist` - 只在微信生效
- `.github/workflows/build.yml` - 无 Mac 编译
