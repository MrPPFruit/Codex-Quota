# 安全说明

请通过 GitHub Security Advisory 私下报告安全问题，不要在公开 Issue 中披露凭据、账户数据或可利用细节。

Codex Quota 不读取 Codex 的认证文件，也不复制访问令牌。它只启动经过签名身份校验的 Codex `app-server` 子进程，并通过标准输入/输出读取当前账户的额度状态。

当前公开版本只发布源码，不附带未经 Apple 公证的二进制文件。
