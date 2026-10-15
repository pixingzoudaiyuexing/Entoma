# Windows VNC 实机验收补充 — 2026-10-15

结论：**Windows 核心连接场景 PASS（限定范围），完整平台验收 PARTIAL**。
VNC 已恢复且成功登录、实时鼠标/键盘控制及测试中持续可用；原 RDP 仍返回 `0xd07`，没有修改锁定策略、密码、RDP 服务或绕过认证。
本轮只测试既有源码/构建，不修改运行时代码，不创建 Release、不合并待审核 PR、不执行真实资金/其他业务写操作。

## 精确设备与安装身份

- 实际控制台：Owner 授权的 Windows 11 Pro，`10.0.26300` / build `26300`，x64 云主机；系统账户登录与 VNC 网页连接认证分开处理，报告不保留凭据或控制台 token URL。
- 普通产品运行候选：`95285a5f9485c8a9ace615d76c171490fa48d8cc`，CI [38594076691](https://github.com/pixingzoudaiyuexing/Entoma/actions/runs/38594076691)。不含 macOS PR #4 组合。
- 精确安装程序：`Entoma-0.1.0-windows-x64-setup.exe`，SHA-256 `5a14c951af92e038f126b78ac02b12d0af879fbde4e5b3f825e64f68e8acc625`。从既有 CI artifact 下载至测试机，远端哈希 gate 为 true 后启动安装；未经 Release 或公共下载站分发。
- 已安装 `Entoma.exe` SHA-256 `6b50bf6073cf12583e71f526c61f583168535dd3223cb5c9b74e79ca3792f3cf`，`FlClashCore.exe` SHA-256 `5a2f5bf0b83fbad7608838683dc189d2bc345fe9e1d9c0ff4dd87b64ab1ba09d`，逐项与同 CI ZIP 比较均 true。
- 安装目录实际有八个 MSVC DLL：concrt140、msvcp140、msvcp140_1、msvcp140_2、msvcp140_atomic_wait、msvcp140_codecvt_ids、vcruntime140、vcruntime140_1。新包安装/启动通过；**此设备已人工装过运行库，干净系统运行库自给 NOT TESTED**。未卸载系统运行库作破坏性对照。

## 实际操作与判定

| 场景 | 操作和证据 | 结果 |
| --- | --- | --- |
| 安装/启动 | 远端 installer_hash_match、gui_match、core_match 均 true；Inno 安装完成，普通新包显示本地界面 | PASS；未验证干净OS或发行签名 |
| 登录/账户/订阅 | 使用已有 STG 普通账户真实登录，账户/套餐/余额/流量显示；刷新订阅，节点与自动/故障转移组显示，test 节点约104–114ms | PASS；原始业务 payload/密码/Token不保存 |
| 冷启动保持 | 活动系统代理正常退出后、活动TUN退出后分别冷启动，无需重输登录且账户/节点保留 | PASS；这是行为验证，不读取 DPAPI 明文或声称覆盖全部存储异常 |
| 系统代理 | TUN关闭、系统代理开启、Rules/test；实际WinINet flags9→3、serverLength14、bypassLength168、PAC0；.NET HttpClientHandler遵循GetSystemWebProxy，默认TLS HTTPS200 | PASS，目标Cloudflare核心日志匹配选定test链，排除DIRECT；非显式127.0.0.1代理替代验收 |
| 活动系统代理正常退出 | 退出日志搜索后正常关闭；实际WinINet四值Ordinal逐项与基线相等、进程0、7890/17890监听0、网卡/路由/DNS序列化快照与基线相同 | PASS；搜索态关闭问题另列，未用强杀替代正常退出 |
| Windows TUN首次 | 系统代理关闭、虚拟网卡开启、Rules/test；实际Entoma网卡ifIndex10 Up，目标Find-NetRoute选择Entoma；HTTP UseProxy=false/defaultTLS/200 | PASS；核心目标日志源198.18.0.1、选定test非DIRECT，VNC持续可操作 |
| TUN断开与连续重连 | 首次断开恢复完整WinINet/网络快照、目标监听0；随后两次重连，各有UseProxy=false/defaultTLS HTTPS200 | PASS所列三次连接，不是100次压力测试。第一次重连同出口hash但未单独保存其完整目标链；第二次与后续切换链另有截图 |
| 实际UI节点切换 | 普通包真实节点卡 test→另一SS节点（名称显示套餐到期日期）；新HTTPS200且Cloudflare日志明确新节点；再点击恢复test | PASS切换到新节点的实际转发；切回后的专门逐链截图未另采，之后核心恢复HTTPS出口与test一致 |
| 后台 | GUI在后台，独立PowerShell请求HTTPS200，连接及VNC正常 | PASS短窗口，不是睡眠/唤醒或长时间后台/能耗验收 |
| 核心异常退出/重新连接 | 先读唯一核心PID2624及路径，命令再次核对路径等于已验证安装目录后仅停止该PID；GUI回到未连接，主动点击Connect重新起核心，UseProxy=false/defaultTLS HTTPS200 | PASS该恢复路径；未扩大到任意进程/系统崩溃；恢复后未另外记录完整selected-chain，仅同出口hash |
| 活动TUN正常退出 | 在非搜索态按窗口正常退出；GUI/core0、监听0、原WinINet及网卡/路由/DNS快照完全一致 | PASS，与Mac测试分开，不继承其他分支结论 |
| API离线刷新/LKG | 核心断开时添加仅GUI TCP443的唯一临时阻断规则后点刷新；未得到可确认的API错误，不能证明故障已成功注入；只精确移除本规则并回读剩余规则数0，系统三profile仍Enabled | NOT VERIFIED；没有关闭防火墙/网卡/全局DNS，不将无错误当离线PASS，也不声称持续代理时API隔离 |
| 登出及凭据清理行为 | 用户主动确认登出；正常退出后冷启动仍登录页、邮箱/密码为空；节点页“暂无代理” | PASS行为，不读凭据、不删除Journal，不执行deleteAll |
| 最终清理 | 再次原生查询：flags9、server/bypass/PAC长度0、四值exactly restored、network restored true、process0、listener0，临时规则已为0 | PASS；测试终端保持可用，Owner的VNC页保留 |

## 原生验证方式

只读测试 `WinInetQuery.cs` 在实际 x64 PowerShell Add-Type 编译成功，调用 `InternetQueryOptionW(INTERNET_OPTION_PER_CONNECTION_OPTION=75)`，查询 FLAGS_UI、SERVER、BYPASS、PAC 四项。失败抛错，API字符串GlobalFree、自分配buffer FreeHGlobal；不调用InternetSetOption、不写系统配置。原值只放本次PowerShell内存，仅输出flags、长度和canonical SHA。

原始四项 flags9 + 三空串，canonical SHA-256（EW1、UInt32 flags、三个BinaryWriter长度前缀字符串）：`443781f3aadc84e7837a03016461c84f663dfd07289acee97a0ff11ad3e042b0`。恢复同时做Ordinal逐值比较，未用Registry/WinHTTP代替WinINet。

网络基线包含隐藏网卡ifIndex/name/status、全部Get-NetRoute的destination/nextHop/interface/metric及DNS服务器，排序后JSON比较；不将这些原始IP公开到报告。监听检查覆盖实际旧/新配置7890/17890，进程仅Id/Path，不读取带IPC proof的CommandLine。

HTTPS探针默认TLS、禁用重定向、独立HttpClient和20秒期限。系统代理模式显式使用GetSystemWebProxy；TUN模式UseProxy=false。只输出状态、长度、出口SHA，不输出trace body/IP。系统代理、首次TUN及两次重连/新节点/故障恢复HTTPS均为200，所存出口hash一致；没有另做同一探针在同网络DIRECT的独立负对照，不能从已知服务器地址推导该对照已通过。明确节点证明来自同期目标核心日志，不单靠UI/出口hash。

## 发现的非阻断问题与限制

**ENTOMA-UX-001 / 日志搜索期间窗口关闭无反馈**：Logs→搜索任意文字→点标题X或Alt+F4，窗口/核心保持运行；退出搜索后正常关闭，网络完整恢复。`widgets/scaffold.dart` 搜索态创建 `SystemBackBlock`，其设置 `backBlockProvider=true`；`controller.handleBackOrExit()`直接return，导致桌面关闭被页面Back保护吞掉。不是网络恢复失败证据。

最小后续建议：区分桌面window-close与Android/page Back，保留真正loading/modal保护；可先退出搜索或明确提示，不无条件清空所有backBlock。补搜索态desktop-close及Android Back组件回归。本轮只记录，无产品修复，未扩大安全/原生权限变更。

控制台有输入法/焦点/字符传输延迟，保留失败命令与纠正记录；未执行的乱码在Enter前清除。一次重连探针因空格/字符丢失报CommandNotFound，随后精确短命令通过，前者算测试设施失败而非客户端网络失败。最初误将VNC网页连接密码用于Windows登录，收到澄清后纠正；没有将其值保存到文件或重复猜测。

RDP `0xd07`依旧，VNC成功不等于RDP修复。未重置密码/锁定策略、开启旧常驻helper或修改远程服务。runas在现有Administrator控制台上下文启动成功，未另外验证普通标准用户/显式UAC取消。系统睡眠/唤醒、完整断网恢复、API超时、纯源站隔离、恶意外部代理修改保留、干净OS依赖及全部三PR组合仍NOT TESTED/NOT VERIFIED。

## Evidence 与发布门禁

本地目录：`dist/post-device/0c77d0b8/windows-vnc-20261015/`。包含原始截图、只读测试代码、预检/安装/结果JSON与SHA manifest；截图原始内容实际为JPEG（早期文件后缀.png），原件保留，最终另保存规范PNG `final-network-restored-verified.png`。无密码、Token、raw订阅、credential URL或原始业务响应提交Git。

Windows环境不再阻断上述核心场景；整个平台验收仍PARTIAL。SEC/NET/macOS正式Delta Re-review仍REQUIRED/PENDING，macOS长期授权UX和精确组合候选回归仍阻断公开内测/正式发布，不建议自动合并。没有新运行时代码，不重复三端构建；沿用精确95285a5成功CI并核验远端实际安装二进制。

本次 Windows 跟进 `agy Specialist Calls: 0`（五种模式均0），`Embedded Review Calls: 0 / 0 completed / 0 failed / 0 re-review`。Codex只读子代理提供查询代码/证据挑战，不替代正式独立审核。此前连续修复任务agy累计8次，原报告保留。
