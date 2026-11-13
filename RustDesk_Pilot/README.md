# RustDesk Pilot (`rdpilot`)

非官方 RustDesk OSS 原生 DEB 部署及运维工具。适用于 **Debian 12+（amd64 / arm64）**，使用官方 GitHub Releases、systemd 和 UFW，不依赖 Docker。

## 安装与启动

```bash
curl -fsSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/RustDesk_Pilot/rdpilot.sh -o rdpilot.sh
chmod +x rdpilot.sh
sudo ./rdpilot.sh
```

第一次启动时可选择安装管理命令 `/usr/local/sbin/rdpilot`，以后运行 `sudo rdpilot`。

**注意：** 上面的 GitHub Raw 链接需要你先将本仓库中的 `rdpilot.sh` 上传到指定路径。建议正式生产使用前固定并审查脚本版本，不要无条件运行来源不明的远程脚本。

## 功能

- 审计 SSH 端口、监听端口及 UFW 规则；人工审核严格入站规则；120 秒以上的独立防火墙自动回退保护（当前默认 180 秒）。
- 查询 RustDesk Server 最新稳定版；匹配 CPU 架构；校验 GitHub Release asset SHA256；安装官方 `hbbs` / `hbbr` DEB。
- 原生 systemd 管理；首次安装生成 Ed25519 密钥，升级保留密钥和数据库。
- 按 RustDesk 官方客户端 `CustomServer` 格式生成导入字符串：JSON → URL-safe Base64（无填充）→ 反转。
- 默认关闭 RustDesk stdout/stderr 日志；需要时开启 30 分钟 journald 调试并通过 systemd timer 自动恢复。
- 手动升级、备份、数据恢复、缓存 DEB 版本重装、状态和网络诊断。

## RustDesk OSS 默认端口

| 协议 | 端口 | 用途 |
|---|---|---|
| TCP | 21115 | NAT 检测 |
| TCP/UDP | 21116 | ID/打洞 |
| TCP | 21117 | Relay |

不启用 Web Client 时默认不开放 21118/21119。SSH 和其他业务端口由实际扫描及人工确认决定。

## 安全提醒

1. **防火墙必须审核**：自动识别的监听端口不等于必须公网开放的端口。严格模式仅删除你明确选择的 UFW 规则，不会擅自清空 nftables、iptables 或云安全组。
2. **SSH 二次验证**：应用 UFW 后，请在 180 秒内另开 SSH 连接测试并确认，否则计划任务尝试恢复 UFW 配置。复杂网络、防火墙转发、Docker 环境应先人工审计；自动回退不能保证覆盖云安全组等外部因素。
3. **备份私钥**：`/var/lib/rustdesk-server/id_ed25519` 是服务器私钥，不得发送给客户端。备份保存在 `/var/lib/rdpilot/backups/`，建议额外加密异地保存。
4. **日志**：默认关闭 RustDesk 进程标准输出/错误；systemd 服务事件仍可能记录。30 分钟调试切换会重启 hbbs/hbbr。
5. **升级**：仅手动触发；升级前备份。旧版 DEB 重装不保证兼容新版数据库，必要时恢复对应数据备份。
6. **客户端地址**：公网出口 IP 可能不是可入站 IP（NAT/WARP 等），务必人工确认。
7. **软件包来源**：SHA256 取自 GitHub Release 资产摘要；摘要一致性不等于独立签名验证。

## 目录

- 管理命令：`/usr/local/sbin/rdpilot`
- RustDesk 数据：`/var/lib/rustdesk-server/`
- 管理器状态及备份：`/var/lib/rdpilot/`
- 管理器配置：`/etc/rdpilot/`
- 日志覆盖：`/etc/systemd/system/rustdesk-{hbbs,hbbr}.service.d/90-rdpilot-logging.conf`

## 官方参考

- [RustDesk Server Releases](https://github.com/rustdesk/rustdesk-server/releases)
- [RustDesk 客户端配置解析源码](https://github.com/rustdesk/rustdesk/blob/master/src/custom_server.rs)
- [RustDesk 客户端配置生成源码](https://github.com/rustdesk/rustdesk/blob/master/src/naming.rs)

> RustDesk Pilot 为非官方社区管理工具，与 RustDesk 官方项目无隶属关系。
