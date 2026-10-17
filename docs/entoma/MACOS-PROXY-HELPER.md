# macOS 系统代理后台服务

Owner于2026-10-17批准：macOS最低13.0；采用管理员一次安装、launchd管理服务的方式，本地开发不要求付费Developer ID。此前SMAppService设计与审核上下文保留在PR #9及[原提交文档](https://github.com/pixingzoudaiyuexing/Entoma/blob/17b1835c715f5ea476269d5f0ef0896dce830b37/docs/entoma/MACOS-PROXY-HELPER.md)。此分支替代PR #9先前的SMAppService/强制Developer ID门禁，依赖#8的一键连接实现；不合并#8/#9或本分支，不自动安装服务或发布。

## 上游参考与取舍

核查 Clash Verge Rev `4337bd85758d54d7b9044b2da3c9ac1176eae1f3` 的
[src-tauri/src/core/service.rs](https://github.com/clash-verge-rev/clash-verge-rev/blob/4337bd85758d54d7b9044b2da3c9ac1176eae1f3/src-tauri/src/core/service.rs)
及其实际引用的[clash-verge-service-ipc v2.7.6](https://github.com/clash-verge-rev/clash-verge-service-ipc/tree/v2.7.6)：
`src/management.rs`通过osascript管理员提示调用安装工具，`src/bin/install_service.rs`发布root文件、launchctl bootout/bootstrap并等待服务可用。
旧clash-verge-service仓库已归档，不以旧666 socket权限实现作为模板。

仅借鉴安装、launchd与恢复机制，没有复制其代码/资源或引入Rust服务依赖。
Entoma继续使用已有NSXPC代理协议及SystemConfiguration，不开放通用核心启动、脚本、文件路径、命令执行或DNS/TUN接口。TUN仍在原权限边界内。

## 安装及调用

1. App普通启动、状态查询和系统代理开关不会安装服务或请求管理员权限。
2. 用户从设置→网络→系统代理服务点击“安装／更新”。系统osascript正常请求管理员授权，不收集密码。
3. 授权命令将App复制到root专有临时目录，用真实运行GUI的代码hash验证完整App及嵌套Helper的签名封印，再以同一架构执行快照内的Helper；命令路径、参数严格shell quoting，不从IPC接受命令。
4. 安装器再次核对App包签名、批准的代码hash、自己的运行代码与复制后的Helper身份。root只发布固定目录文件：
   - `/Library/PrivilegedHelperTools/EntomaProxy/EntomaProxyHelper`
   - 同目录`receipt.plist`（获准App/Helper CodeDirectory hashes，非Token）
   - `/Library/LaunchDaemons/com.entoma.client.proxy-helper.plist`
5. launchd以root启动受限Helper；它先恢复原网络Journal，再开放XPC并发布实际就绪回执。安装器等待回执，GUI还必须收到经身份验证的真实status回复才能显示服务可用。
6. 后续开关复用此服务，不再请求管理员密码。未安装/被替换/版本不匹配时准确失败，提示安装或更新，不伪报连接。

`bash tool/build_macos_proxy_helper.sh --embed OUTPUT APP`编译双架构13.0 Helper、ad-hoc签名并嵌入App，再重签App。可用现有签名身份覆盖`ENTOMA_HELPER_SIGNING_IDENTITY`，本地测试默认`-`，无付费证书要求。此脚本只制作App，不安装服务。CI PKG包含Helper，但无特权安装脚本；安装App本身不代表已安装服务。

## 最小身份边界

- 安装时将当前获准架构的确切App和Helper代码hash固定到root拥有的receipt；不是只信任包名、路径或同UID。
- NSXPC listener和connection使用macOS13公开code-signing-requirement API验证每条消息的真实代码身份；GUI对服务端同样校验。
- 允许有效ad-hoc签名；App和Helper都保留hardened runtime，拒绝get-task-allow和allow-dyld-environment-variables。本地ad-hoc Flutter App因无Team ID必须用LocalHelper.entitlements明确允许其动态库加载；此例外只给非特权GUI，root Helper仍拒绝disable-library-validation。使用付费签名身份时不添加此本地例外。安装后root文件/单pin、有限RPC边界不变；不把本地GUI对库加载的信任描述成生产签名隔离。
- daemon只接受当前控制台用户。已建立会话在用户切换后仍可恢复其原网络事务，但不能发起新的apply。
- 只安装与获准执行架构对应的Helper slice，不把universal包中未经当前运行身份确认的其他slice加入信任列表。App构建更新或切换执行架构导致hash变化时，需用户明确“安装／更新”并授权刷新pin；普通重启同一个包和日常代理开关不需要重新授权。这是本地adhoc测试的更新行为，不是额外证书体系。

## 升级、卸载及故障

固定root目录逐段O_NOFOLLOW打开，检查owner、模式、ACL、硬链接；写入采用同目录临时文件、fsync与rename。安装锁不删除/重建，拒绝并行安装。

升级先完成新包验证，再停止旧job，取得原`/Library/Application Support/Entoma/NetworkProxy/owner.lock`并确认CAS恢复，之后发布新文件。旧二进制/receipt持久备份保留到新daemon真实启动回执；失败恢复旧版本并重启，恢复失败准确返回错误。中断发布保留备份供下次受控修复，不把不完整安装当可用。

卸载先停止服务并确认原Journal恢复，再移除固定服务文件。失败保留恢复文件，不删除NetworkProxy Journal或锁inode，不覆盖其他程序更改的代理。App界面的卸载先请求drain+恢复确认；用户取消管理员卸载后服务保持安全drain，可通过明确“安装／更新”恢复可用状态。

## 验证及边界

`bash tool/test_macos_proxy_helper.sh`执行真实ad-hoc签名验证、匿名XPC正确/错误pin、限界输入、真实临时文件攻击路径、安装事务失败与既有Journal/CAS fixture，并双架构compile-only。网络快照、单owner lease、超时UNKNOWN、外部修改保护及原一键协调器测试继续保留。

实际root安装、launchd启动/升级/卸载、GUI多次开关和选定节点HTTPS仍必须在Owner许可后测试；未执行就不能宣称PASS。构建或匿名XPC测试不替代root服务实测。正式独立Delta Review仍是高风险权限变更的合并门禁。

本次不修改authdb/sudoers、不安装其他持久组件、不提升mihomo核心或读取账户Token。付费Developer ID不再是本地测试阻断；正式分发的签名、公证及平台安全提示属于后续发行要求。
