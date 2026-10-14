# Entoma 设备后修复交付 — 2026-10-15

总体：**PARTIAL / RELEASE BLOCKED**。已完成授权范围内的代码修复、可执行真机测试、构建和独立复审材料；长期 macOS 授权体验、Windows 实机以及新的正式独立审核仍未闭环。没有创建 Release、对外分发、修改生产/Solution/V2Board 或执行真实资金业务。

## Git 与审核边界

PR #2 已正常合并，合并提交及最终 main 为 `0c77d0b8f337405fbacea833cb7db5b4dbe8846a`。合并前已核对审核 Head、三端 CI、Base、无运行时新增差异及无生产部署触发；合并树与已审核树一致。

| 独立变更 | PR / Base | 精确运行时代码 / CI | 状态 |
| --- | --- | --- | --- |
| SEC-001 Journal | [#3](https://github.com/pixingzoudaiyuexing/Entoma/pull/3)，main 0c77d0b8 | `f49b44576b17f72c43920f79e80bb44f7811f660`；[38536044433](https://github.com/pixingzoudaiyuexing/Entoma/actions/runs/38536044433) | Draft，三端 CI success，正式 Security Delta Re-review REQUIRED/PENDING |
| macOS 生命周期/权限 | [#4](https://github.com/pixingzoudaiyuexing/Entoma/pull/4)，main 0c77d0b8 | `1f11aa89f7038f45d26bacc599798edb25483352`；[38543405272](https://github.com/pixingzoudaiyuexing/Entoma/actions/runs/38543405272) | Draft，三端 CI success；文档 Head `2bbd1eb207c9cb44e47622f25423f1352bf1314c`；正式审核 PENDING |
| NET-001 Android 原生核心 | [#5](https://github.com/pixingzoudaiyuexing/Entoma/pull/5)，stacked on #3 f49b445 | `95285a5f9485c8a9ace615d76c171490fa48d8cc`；[38594076691](https://github.com/pixingzoudaiyuexing/Entoma/actions/runs/38594076691) | Draft，普通运行候选三端 CI success；后续b8f03da/8449bd8仅测试门控Go/Dart readback、外置收集与文档，其诊断构建另记；正式审核 PENDING |

三个 PR 保持隔离，没有自动合并。#3+#5 和 #4 的**组合代码尚未构建/实机验收**；不得把各自 CI 当成组合候选通过。正式复审后应建立精确组合候选并复核再合并。mihomo pin 仍为 `413467ae6b3665fa63d072f18dfccd871c9cda6a`，变更由 `patches/` 明确携带；子模块工作树显示这些已知补丁，非未知变更，未 reset/clean。

## Finding 逐项结论

| Finding | 最终处理状态 | 实现与边界 |
| --- | --- | --- |
| ENTOMA-SEC-001 | FIX READY / 正式审核待完成 | 显式关闭 secure-storage 10.0.0 自动 reset/migration；保留既有算法与键空间；独立非敏感 witness + all-account secure Journal，缺项/损坏/dirty/回滚不一致/失败写入一律 fail closed。登录、只读与缓存代理尽量可用；登出、重新登录、设置重置均不能清除金融未知保护。 |
| ENTOMA-NET-001 | 本 Huawei 重连修复 PASS / 正式审核待完成 | 单独修正设备名被压力测试否证；最终使用实际 TUN 名严格绑定 + wildcard 本地转发监听，失败拒绝启动，修复部分启动 FD/stack 清理。mixed 默认及 pinned 内核不变。其他 ROM/IPv6/性能能耗未验收。 |
| ENTOMA-PKG-001 | 目标普通包真机测试 PASS（限定范围） | 实际使用 `com.entoma.client`、诊断关闭的普通 APK，非 QA 包。Owner 授权移除旧 CI 签名测试数据后全新安装；固定本地签名后 install-r/冷启动保持成功。**旧 CI 签名原地升级保留数据未验证**，固定签名发行治理仍待补。 |
| macOS 重复授权 / 历史 TUN 超时 | PARTIAL | 共用精确 network right/串行写入/归属快照；正常退出等待恢复；授权/进程启动 5 分钟与 IPC 60 秒分别计时。实机代理、TUN 重连/退出恢复通过；本机 network right 委托 nonshared/30 秒策略，短时间复用有效，过期仍需授权，长期免弹窗未实现。 |
| Windows 新包与 TUN | BLOCKED | 账号锁定且服务商 VNC 维护；未再次尝试登录，也未做无带外恢复的 TUN 操作。CI 安装包含八个 MSVC Runtime DLL，实际新包安装/运行/TUN仍待验收。 |

## Android 实机与异常证据

设备 Huawei CDY-AN90，Android 10 / API29，arm64，kernel 4.14.116，安全补丁 2020-11-01。测试使用已有 STG 普通账户，仅登录/安全读取/订阅和代理流量，不做真实付款或其他业务写操作。

| 操作与实际结果 | 证据（正式目录下） | 判定 |
| --- | --- | --- |
| secure-storage 原生隔离密文异常：旧 reset 选项删除异常项并返回缺失；新选项报错并保留密文与 sibling fixture | `dist/post-device/0c77d0b8/sec-native-device-verified.log`，instrumentation code -1，三断言 true | PASS。未损坏真实账户 Journal；fixture 数据文件隔离，但插件 wrapped-key/Keystore alias 为 app-wide，未删除密钥 |
| 缺项、dirty、损坏、写入中断、账户切换、登出只剩 Journal、重新登录、identity refresh、组件锁定提示 | `test/solution_journal_integrity_test.dart`；baseline red/恢复 green/dirty mutation 日志保留 | 单元/组件/异常注入 PASS；不冒充所有故障均在真实账户 Keystore 诱发 |
| 原始 mixed/ON 30 次重连 2 失败；复原基线 100 次 1 失败；仅名称修正 100 次仍有 2 ECONNREFUSED 与 1 TLS 失败 | `net-forwarder-stress-baseline.json`、`net-baseline-reversal-100.json`、`net-fixed-100.json` | 已保留根因干预对照，未把短暂通过当最终修复 |
| 严格绑定实验 100 次默认 TLS HTTPS 200，均 TUN/选定节点，最终停净 | `net-enforce-candidate-100.json` | PASS（实验干预）。source 字段为实验基线8e78b8f，不是最终95285；没有100次独立 shell/有效 LAN 正对照 |
| 六组合各3次：mixed/system/gvisor × VPN HTTP Proxy ON/OFF；实际 native readback 正确；18个应用 TUN/selected-chain + 18独立 shell HTTPS200 | `net-final-matrix-controlled.json`，source32cf941 | PASS，12个 mixed/system LAN 拒绝均有同手机 WLAN 正对照；18 starts/18 stops、0 VPN、FD关闭 |
| 最终95285：3次mixed/ON重连、3独立shell、3 LAN正对照/拒绝；owned pipe FD 到 TUN ioctl 失败后 EBADF；一个 paused 后台窗口 HTTPS200/TUN/selected node | `net-final-background-repeat.json` | PASS，**仅一个约27秒 paused 后台探针**；pipe fixture 不等于真实IPv6 bind失败 |
| 先前切换另一节点后 HTTPS200/TUN，但两个 run 的 selectedNodeObserved=false；恢复原节点后true | 上述 matrix/repeat `node_switch` / `node_restore` | 这两次未证实新节点链，不计PASS；缺失链证据的原因未确定，未宣称产品故障已修复 |
| 后补b8f03da直接核心Set/now/mode/chain、8449bd8再走实际selectedMap与controller序列；切换与切回均HTTPS200/defaultTLS/TUN/目标组/预期节点，persist与now均匹配 | `net-selector-readback.json`、`net-controller-readback.json` | 核心+持久化/控制器路径PASS，最终1/1停净；普通APK的物理节点卡点击→新节点链全程未单独记录；无新增产品修复 |
| 普通正式包冷启动登录保持、账户/5节点刷新、WLAN断开时错误提示且保留节点、WLAN恢复后首次/重连 HTTPS200 | `android-ordinary-package-proof.json`、`android-product-provenance.json` | PASS（普通包实机）；诊断 Go exports/Dart marker 均不存在 |
| 普通包 Rules / DIRECT / Rules 出口 hash A/B/A，A≠B，默认TLS、无显式代理 | `android-product-rule-control.json`、`android-product-direct-control.json`、`android-product-rule-restored.json` | PASS实际路由对照；与诊断版 selected-chain 读取分开，不宣称普通包每次读取了核心链 |
| 普通包正常断开，再停止自身进程；17890连接拒绝、sysfs无tun0、无app进程；WLAN开启，Rules模式，临时日志采集恢复关闭 | `android-ordinary-package-proof.json`、`android-product-mixed-port-cleanup.json` | PASS所列清理；adb netlink权限拒绝，完整路由表清理 NOT VERIFIED |

早期权限等待错误、错误IPv4探针HTTP400、原生fixture构建失败、一次 instrumentation/relaunch 后输入ANR均保留。ANR根因未确认，普通最终包冷启动响应且上述路径通过；不据此证明任意长期稳定。睡眠/长后台、真实核心崩溃恢复、广泛ROM/IPv6与能耗仍未验收。

Journal全部记录和 witness 同时永久丢失、匹配旧快照回滚、清数据/卸载、多设备竞争，纯客户端不能证明金融安全。后续需 Solution/V2Board 服务端幂等键、操作收据和权威对账契约；本轮未修改后端，也没有风险确认/重新登录/deleteAll解锁路径。

## macOS 实机证据

本机 arm64，macOS 15.7.4（24G517），实际运行本地 release App 源码1f11aa8。Entoma executable SHA-256 `cfa986fd431be97b279f0d72434336937f9ae9ba157b9954f28113b9a3c5bceb`，core `9d98a4fae374c7aae82988ab33f960789a15fa415dab101cb231f3f2e4ebefaf`。

系统代理设置为17890并回读；显式使用本地17890的默认TLS HTTPS200，目标日志证实选定节点非DIRECT。设置/恢复与显式代理转发分别验证，未单独记录遵循系统代理的URLSession/浏览器自动采用测试。短周期开关不新增SecurityAgent，关闭及 active-proxy 正常退出均恢复七个服务的代理/DNS/protocol快照。TUN管理员授权后UID0核心、utun6及默认TLS HTTPS200（无显式代理），路由/目标链一致；新鲜连续重连断开恢复七服务+接口；active-TUN正常退出在恢复授权期间保持GUI/core，Owner授权后全部恢复并退出。证据：`macos/https-chain-proof.json`、`tun-proof.json`、`tun-repeat-proof.json`、`active-proxy-quit-proof.json`、`active-tun-quit-final-proof.json`。

长时间初次会话七服务出现并发外部代理改动，完整初始快照恢复 **NOT CONFIRMED**；成功结论只针对连续 repeat 基线。未动其他代理应用、authdb、sudoers或安装Helper。授权取消、5分钟期限和root→GUI marker时序主要有自动测试，不宣称均做了活体故障注入。

重复授权UX仍阻断发布。最小后续候选为单独批准的签名 SMAppService helper：仅允许归属代理/DNS恢复和严格验证core启动，签名/Team鉴别调用方，拒绝任意命令/路径，串行及卸载撤权，不接收账户Token；需要发行签名和新安全审核。也可保持OS过期授权/用户手动网络设置。**本轮不引入常驻提权组件**。

## 测试、CI及可安装测试包

- SEC/NET 本地全量 Flutter **148 passed**；Mac分支 **151 passed**（不同分支，不相加为同一套）。Journal baseline/identity red→green 与 dirty-check mutation回归留存。
- Go核心 `CGO_ENABLED=0 go test -tags=with_gvisor ./...` PASS；sing_tun 有/无 gvisor 两种编译通过，Android CGo及原生构建通过。Swift production ownership seam **17 passed**，4个真实/bin/sh marker fixture、native plugin type-check、macOS release build PASS。
- Focused Dart analysis **0 error / 0 warning**，原有 style info 留存；本机 Flutter analyzer 曾有Unicode/LSP framing故障，未伪报其成功。三个精确运行候选的 CI 静态分析、测试及三端构建均success。
- 后续文档/外置Java与Python收集工具及b8f03da/8449bd8测试门控Go/Dart诊断改变，普通执行路径未变；新诊断原生/Android构建、分析、实机与最终148-test/Go回归单独记录，未继承旧CI声称已通过。未重复普通路径无变化的三端构建。未把构建或Mock当Windows实机PASS。三个PR的组合候选仍需复核。

| 测试安装包（均未正式发布） | 对应源码 | SHA-256 | 设备状态 |
| --- | --- | --- | --- |
| `dist/post-device/0c77d0b8/Entoma-95285a5-android-arm64-test.apk` | 95285a5，普通本地release构建，诊断关闭，固定开发签名 | `cd3514570166a46e2ea6c469e9d5669de7d943d33cb37de48ecd2444bd0f2066` | 此精确APK已在正式包名真机验收上述范围 |
| `dist/post-device/0c77d0b8/ci-net-95285a5/windows/Entoma-0.1.0-windows-x64-setup.exe` | 95285a5，CI38594076691 | `5a14c951af92e038f126b78ac02b12d0af879fbde4e5b3f825e64f68e8acc625` | 已取回；zip验证八MSVC DLL；新安装/DPAPI/WinINet/TUN/退出未实测 |
| `dist/post-device/0c77d0b8/ci-macos-1f11aa8/macos/Entoma-0.1.0-macos.pkg` | 1f11aa8，CI38543405272 | `f4b9508d11f551f337da4cb43fda8c640a3eaf0f7f470aa12fbb2f05d9d1bb85` | 已取回，PKG未签名；本轮真机运行同源码本地App，不冒充此精确CI PKG安装验证 |

以上包不包含所有三项PR组合。Android CI ephemeral签名包与本机固定签名包不同；不互相替代哈希/升级证据。二进制和原始测试证据保存在 ignored `dist/`，未把安装包或任何凭据提交Git。

后补工程诊断包 `Entoma-net-controller-8449bd8-arm64.apk` SHA-256为 `a5b9c4258bed79549eea469b010c0b0d386cd0b8262be6ac65b1bbac7a9c01ba`，仅用于上述节点链辨别，非交付普通包；测试后恢复普通cd351457包。第一次补测APK版本号较已装包低，安装被系统拒绝且保留原数据；随后统一versionCode14成功，失败构建/安装证据保留。

## 正式 Delta Re-review 精确材料

`dist/post-device/0c77d0b8/review/manifest.json` 保存三个独立patch与包哈希。Patch包含完整tracked源码差异（包括owned mihomo patch），无credential payload：

| Patch / git diff anchors | SHA-256 |
| --- | --- |
| `SEC-001.patch`：0c77d0b8→f49b445 | `8316ef0a8bf1cac4f39b96db3beb9a4f9d484473e78bfc0b29103c6be538e46a` |
| `MACOS.patch`：0c77d0b8→1f11aa8 | `d9fb15f0c0aba96daa5305ca48c6f6fa95541f56626fe819685dccbabe2e262b` |
| `NET-001.patch`：f49b445→95285a5 | `0c59684615932540ef33d78bdf90824b0e335973cc3b3986bc14c48ecb1d81e2` |
| `NET-001-TEST-DELTA.patch`：95285a5→8449bd8（测试诊断/收集与先前NET文档） | `ee95daa56aae3fc4390fd47a95de542568e09fac8cebef9c84b4bdd811fc16d9` |

完整实现与测试路径见各PR diff，以及 `SEC-001.md`、`NET-001.md`、#4的 `MACOS-NETWORK-STABILITY.md`。正式审核应重点审查金融fail-closed边界、all-account迁移/并发/identity、严格bind和部分构造清理、授权/exit/epoch/readiness权限边界。内部证据复核不能代替正式Reviewer。

## 下一阶段必要条件

1. 正式 Security/Native/Permission Delta Re-review通过，随后构建精确组合候选、三端回归及批准合并；当前不建议直接合并三个Draft。
2. macOS长期授权UX方案需上游单独批准；本轮没有引入新常驻特权组件。
3. 恢复Windows账号及实时VNC/KVM后，使用新包验证安装/MSVC、登录保持、系统代理、TUN真实节点和恢复；无带外恢复不测试TUN。
4. 普通包节点卡实际交互的完整链证据、广泛Android ROM/IPv6、真实故障/长后台、发行签名及保留数据升级仍需验收。公开内测/正式发布条件均未达到；可继续受控设备测试。

## Specialist 使用记录

agy Specialist Calls: **8**
- Research Scout: 0
- Root-Cause Challenger: 2
- Design Challenger: 1
- Test Designer: 0
- Embedded Reviewer: 5

Embedded Review Calls: **5 / 1 completed / 4 failed / 2 re-review**。
所有调用中2 completed、6 failed（超时/权限/旧模型路由失败）；失败调用也计数。新规则后的有效路线仅 `gemini-3.8-flash-high / high`，未绕过headless权限，未据同模型重复调用宣称跨模型独立意见。内嵌建议均经实际源码/故障回归裁决，正式独立审核仍为独立未完成门禁。
