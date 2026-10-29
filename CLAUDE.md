# gang-launchpad：给 agent 的协作须知

## 这是公开仓库

`gangfun/gang-launchpad` 是 **public** 仓库。凡是推到 GitHub 的内容，任何人都能看到，而且删不干净（fork、缓存、镜像、通知邮件都会留着），包括：

- commit 和分支名；
- PR 标题、描述和评论、review，以及 issue；
- `docs/`、`broadcast/`、`script/` 下的所有文件。

所以 commit、push、开 PR、写评论之前，先确认里面**没有**下面这些：

- **密钥类**：私钥、助记词、API key（BscScan / Etherscan 等）、带 token 的 RPC 地址（QuickNode 之类）、`.env` 的内容、Telegram / 告警 bot token。只通过环境变量或命令行参数用，不写进文件、命令示例和日志摘录。
- **运维内部信息**：服务器 IP 和主机名、服务器上的路径、cron 配置、keeper 的私有发送通道、告警渠道、多签签名人、钱包和人的对应关系。
- **主网上还没修好的漏洞**：攻击步骤、受影响的合约或代币清单、能拿多少钱的估算，一律不写进 commit、PR 或 docs。要先修好上线，或者确认没人能借此获利，再公开。审计报告原文也一样。
- **个人信息**：邮箱、真名、聊天记录、dev 或用户的联系方式。
- **其他仓库的内部细节**：gangfun-server、gang-web-legacy 的实现、配置和运维细节。

## 做法

- push 前看一遍 `git show --stat` 和完整 diff；PR 描述发出前从头读一遍。
- 拿不准的，先问用户再发。不要先发、有问题再删：删掉之前就已经有人看到或缓存了。
- 发现已经泄露：马上告诉用户。密钥让用户轮换；不要自己改写已经推送的历史。
- `broadcast/` 只提交 forge 生成的部署记录。提交前确认里面没有私钥，也没有带 token 的 RPC 地址。
