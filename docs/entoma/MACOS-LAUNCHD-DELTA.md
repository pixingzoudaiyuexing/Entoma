# launchd Helper Delta 审核范围

基线：PR #9 HEAD `17b1835c715f5ea476269d5f0ef0896dce830b37`，包含macOS13最低版本及PR #8一键协调器。新分支`codex/entoma-macos-launchd-helper`独立提交/PR；不修改原#8/#9，不合并main。

Owner批准一次管理员安装launchd服务，允许本地ad-hoc签名；移除SMAppService/DeveloperID强制门禁。保留有效代码身份校验，改为root安装时批准的CodeDirectory hash pin。

审核重点：

- 授权前运行GUI代码身份；授权后root私有完整App快照与嵌套签名封印验证；安装器复制后重验，防止user-writable源被替换后作为root执行。
- 固定root文件路径、O_NOFOLLOW、owner/mode/ACL/nlink，安装锁、持久旧版本备份与失败回滚。
- stop→原Journal锁/CAS恢复→publish→launchd bootstrap→真实启动ACK；失败保留可恢复状态。
- XPC双方每消息验证、当前控制台UID、有限输入；绝不引入任意命令/路径RPC。
- 卸载恢复前不得删文件；旧Journal与owner.lock inode不能重建或删除。
- App更新pin漂移可通过一次明确管理员更新恢复，普通开关不能意外安装。
- 既有一键连接、UNKNOWN/外部修改、TUN与账户行为不变。

测试/构建/实际设备结果与精确SHA随PR证据交付。未获Owner许可前不安装本机服务；未获Formal Independent Delta Review允许前不合并。无Release/生产部署。
