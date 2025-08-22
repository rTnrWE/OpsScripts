# 宝塔面板净化脚本 (BT Panel Purify Script)

本脚本用于对宝塔 Linux 面板进行净化，移除部分非必要功能（如日志上报、活动推荐等），使其更纯净、轻量。

## 功能

-   禁用面板操作日志 (request 日志) 的持续写入。
-   移除向宝塔官方的错误日志与使用信息上报。
-   关闭面板首页的活动推荐、广告和在线客服入口。
-   **安全可靠:** 所有修改前都会自动创建 `.bak` 备份，并提供恢复选项。

## 运行环境

-   支持 Debian / Ubuntu 系统。
-   已安装宝塔 Linux 面板。
-   请以 `root` 用户身份执行。

## 使用方法

在您的服务器终端中，执行以下一键命令即可：

### 推荐方式

```bash
wget -O bt_purify.sh https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/bt/bt_purify.sh && bash bt_purify.sh
```

### 管道方式 (不保存脚本文件)

```bash
curl -sSL https://raw.githubusercontent.com/rTnrWE/OpsScripts/main/bt/bt_purify.sh | bash
```

## 注意事项

-   本脚本会直接修改宝塔面板的核心 Python 文件，操作前请了解其风险。
-   脚本已内置备份与恢复功能，如遇面板异常，可运行脚本并选择“恢复”选项。
-   建议在纯净的宝-塔面板上首次安装后立即执行本脚本。
