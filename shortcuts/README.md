# 给 TA 发消息

这个快捷指令向 Tincall 当前正在通话的对方发送文字或截图，不选择另一位联系人，不新开对话。

## 运行流程

1. 检查是否正在通话；没有通话则提示并停止。
2. 选择截屏或文字。截屏会先让菜单退场，再截图、填写补充文字并确认；文字会打开输入框。
3. 发送前再次核对原通话。输入期间已挂断或换了一通电话时停止，不发到新通话。
4. 消息交给 App 后快捷指令结束，对方的回复仍在原通话中播放。当前正在回复时按 App 的忙碌状态提示处理。

## 从源码配置

公开源码只提供 `给TA发消息.unsigned.shortcut` 模板，不附带开发者已签名的个人成品。模板的 TeamIdentifier 为占位符；按自己的已安装 App 修改 TeamIdentifier、BundleIdentifier 和 App Intent 的应用标识，或在快捷指令 App 中重新选择对应的 Tincall 动作。

动作由 `ios/Tincall/App/TincallMessageIntent.swift` 和 `ios/Tincall/Core/TincallShortcutMessages.swift` 提供：先 CheckTincallCallIntent，再 SendTincallMessageIntent。发送前保留并复核原通话标识；不要删去这一步。

在支持签名的 macOS 快捷指令工具中，可对已经按本机 App 修改的模板执行：

```sh
shortcuts sign --mode anyone \
  --input shortcuts/给TA发消息.unsigned.shortcut \
  --output /tmp/tincall-send-message.shortcut
```

将自己生成的成品传到 iPhone 并导入，可绑定操作按钮、轻点背面或主屏幕。模板不能当作已签名成品直接安装；工具签名成功也不代表动作已匹配自己 App 或真机发送已通过。

## 验证

分别检查无通话时停止、文字输入、截图权限、发送前通话已变化时拒绝，以及消息进入原通话后的实际回复。不要用自动截图或真实发言代替用户确认。锁屏卡片的“打字回复”入口仍由 App 的通话文字视图处理。
