# Current contracts only / 仅保留当前契约

本轮按用户要求清理旧版本执行回退。目标是当前格式的单一路径；未知版本、缺少声明和不完整授权明确拒绝，不自动降级。

## 当前协议与标识

| 边界 | 当前契约 | 为什么保留 |
| --- | --- | --- |
| 手机会话业务 | Agent Session profile 2 | 创建、选项、列表、快照、消息、审批及回执使用结构化当前协议 |
| 已授权加密封装 | 当前 session1/AES-GCM 与安全握手2 | profile 2 位于现用加密封装内；封装名称中的1不是旧业务回退 |
| 中继角色 | Mac host relay2；Android client relay1 | 这是当前两种角色的组合；只移除旧 host relay1 单手机兼容 |
| 中继配对码 | vibepierrelay1 | 当前有效配对编码，不重新编号或破坏既有授权 |
| 原生 Agent adapter | codex.currentV1、claude.currentV1 | 当前已持久化的 adapter 身份，内部操作转换不是旧手机协议执行 |
| 原生 IPC/日志 | 方法各自声明的版本 | 按实际原生接口核验；不能把所有1号版本当作弃用 |
| 私有存储 | 当前Keychain/Keystore与现有加密记录格式 | .v1/version=1等名称仍可能是当前schema；不按字符串批量改名 |

## 全新安装前提

用户明确要求：视为旧客户端全部移除，所有客户端使用最新代码全新安装。产品不提供旧版自动升级迁移、旧索引加载或旧协议降级。首次启动只创建当前schema；遇到旧格式明确拒绝，不读取旧密钥、旧偏好或旧消息执行记录来继续执行。

`AgentSessionDirectory` 仅接受当前支持的 adapter/provider 和正确引用，不加载退役记录。此次现场故障中，旧 ZCode 的44条会话与8个项目已经从当前索引删除；125条Codex/Claude会话与60个项目的引用保持不变。该次处理仅为本地排障操作，脚本和备份保留于本地证据，不作为运行时兼容功能。备份不会被应用加载。

不支持格式的操作不得重新进入执行路径。未知结果拒绝重放仍是当前安全规则；拒绝旧格式不等于继续兼容它。

## 验证要求

- 未协商当前会话协议时，不得发出旧会话业务请求。
- 未知provider、旧adapter、旧schema和错误身份只能拒绝，不能映射为Codex或默认放行。
- 当前媒体/APK下载按二进制通道验证身份、哈希、进度和取消；测试使用当前协议或明确注入的合成数据。`attachmentPreview` 是当前小缩略图契约，继续保留，不作为文件下载回退。
- 全新空存储可以初始化；已有损坏或旧数据不能靠清空或回退获得“成功”。
- 发布前分别验证当前版本互通、旧请求拒绝、未知操作不重放，以及升级数据预检与备份。

## English summary

Runtime paths use current contracts and reject unsupported versions without downgrade. Session profile 2 still uses the current encrypted session envelope. Relay host2/client1, native method versions and persisted adapter names are role-specific current contracts, not reasons to restore old application behavior. Assume fresh installation of current clients. There is no runtime migration of old indexes, settings or credentials. The one-off local repair is diagnostic evidence, not a supported compatibility path. Unknown effects must never be replayed.
