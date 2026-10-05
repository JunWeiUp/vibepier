# VibePier Claude Code Mods prototype / 原型

This source is **disabled by default** and is not installed by build/test commands.
It needs Claude Code **2.1.287+**, the target runtime's generated types, an exact
reviewed version in Mac configuration, and an explicitly issued session binding.
The inspected standalone CLI 2.1.283 cannot enable this driver. Desktop's Code
runtime must be checked separately; Chat, Cowork and Claude Cloud are unsupported.

本插件仅连接 Mac 明确绑定的原生 Code 会话。构建不会升级 Claude、安装插件或启动模型任务。
绑定文件应放入 Mac 自有私有目录，目录 0700、文件 0600；从 Mac 的
`ClaudeModsBrokerDriver.issueBinding` + `writeBootstrap` 生成，令牌不属于插件包。
通过 `VIBEPIER_MODS_BINDING_FILE` 指定该文件的绝对路径，然后由用户明确加载
`--plugin-dir <此目录>`。不要把文件或令牌提交到仓库、命令行参数或日志。

The token expires after 10 minutes and binds an exact native session, cwd,
runtime version, contract digest and instance epoch. Reload, session end,
clear/resume/branch and rebinding revoke the old owner. A new binding is required.
The loopback broker rejects missing/wrong tokens, Origin headers, wrong Host,
non-loopback clients, ambiguous HTTP framing and unsupported actions. Only
bounded event reporting, polling, plain-text submit and exact-turn abort exist.
No shell, arbitrary RPC, permission override or automatic approval is exposed.

Read-only observation is available after binding. Writes need a separately
verified native contract and `nativeWritesVerified` from the Mac; a plugin ACK,
`turn.start`, `session.append` or `prompt.submit` completion never confirms
delivery. Mac must independently verify the native message/turn identity and
authoritative transcript via `confirmNativeEvidence`. Missing evidence remains
unknown. Submission is reserved in Mac and plugin stores before one native call;
reload/reconnect and a lost poll response never resubmit. Queue/steer are unsupported.

Run isolated tests with `node --test tests/*.test.mjs`. The fake Mods API does not
sign in, connect to a broker, load a native plugin, run commands or invoke a model.
After a compatible target exists, use its `claude plugin validate` and generated
types before separate native acceptance. Public documentation currently links
an older 2.1.277 type snapshot; that is evidence for API shape, not target acceptance.

Official sources: [Mods API](https://code.claude.com/docs/en/plugins/mods/api),
[create and version-specific types](https://code.claude.com/docs/en/plugins/mods/create),
[lifecycle and limits](https://code.claude.com/docs/en/plugins/mods/reference).
