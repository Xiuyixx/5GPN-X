# 安装、升级与排障

本文是 5GPN-X 的安装操作指南。想快速开始时只需执行 README 中的命令；本页用于需要升级、自动化安装或排查失败的场景。

[返回首页](../README.md) · [日常管理与配置参考](GUIDE.md)

## 1. 安装前检查

- 使用 Ubuntu 20.04+、Debian 11+、RHEL 8+ 或 Fedora 39+。
- 架构为 `amd64` 或 `arm64`，内存至少 512 MB（推荐 1 GB 以上）。
- 以 root 运行，并准备公网 IPv4。
- 将一个域名的 A 记录指向服务器公网 IP；安装脚本会再次验证。
- 检查端口：公网 TCP 853（DoT）、TCP 80（证书验证），需要时开放 TCP 8111（iOS 描述文件）；指定私网需要 TCP 80/443 和 UDP 443。默认 `FIREWALL_MODE=preserve`，脚本不会接管主机防火墙。

## 2. 首次安装

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh | sudo bash
```

按提示输入域名；证书邮箱可通过 `EMAIL` 设置。已有证书会复用，没有证书时才申请 Let's Encrypt 证书。

无交互环境请预先提供至少 `DOMAIN`（可选 `EMAIL`）：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh | \
  sudo env DOMAIN=dns.example.com EMAIL=admin@example.com bash
```

安装日志写入 `/var/log/5gpn-install.log`。源码默认放在 `/opt/5gpn-source`，运行数据放在 `/opt/5gpn`，两者分开以避免升级覆盖配置。

环境变量必须传给管道右侧的安装进程，不能只写在 `curl` 前面。交互安装从 `/dev/tty` 读取；自动化执行应确保没有交互终端，或预先提供所需设置。

### 固定到已审核提交（可选）

管道入口默认解析 GitHub `main` 的完整提交；如需固定版本，可设置 `PGW_COMMIT` 为 40 位完整 SHA。自定义源码目录使用 `PGW_SRC_DIR`，必须是独立、非符号链接且父目录不可被普通用户写入的路径。

## 3. 升级

重复执行同一条安装命令即可。脚本会自动识别首次安装、旧安装和当前提交：

- 保留域名、DNS、出口、规则、证书和 Bot 状态；不会重新运行首次安装向导。
- 先在 `/var/backups/5gpn/upgrade.*` 保存 root-only 备份和日志。
- 只重启升级前已经运行的服务，不会启用原先停用的可选服务。
- 升级失败会保留 `.install-attempt`、备份和日志；修复问题后重跑即可。
- 有未提交修改的 Git 源码会先备份；非 Git 源码目录不会被自动覆盖。

完整 Git checkout 中的 `install.sh` 直接使用本地源码，不会自动拉取新提交。手动维护源码时，先自行检出已审核提交，再运行 `sudo ./install.sh --upgrade`；这一方式不经过管道入口的提交标记发布流程。一般用户仍建议重跑上面的管道命令。

`--status`、`--update-rules` 等管理参数会转发给已有的 `/opt/5gpn/bin/5gpn-ctl`，不会误触发安装或升级。

### 升级保护与限制

- “当前版本”按成功部署的完整提交 SHA 判断，不只比较 `VERSION`。成功后写入 `/opt/5gpn/.installed-commit`；解析分支或升级失败不会冒充成功。
- 升级会迁移托管模板并按现有设置重新生成配置，不重新申请证书，也不执行或重写 `tgbot.env`；自定义 `TG_STATE_FILE` 保持原位。
- 事务内失败会尝试恢复已快照的程序、托管配置及活动服务；恢复失败时保留快照位置。失败标记包括 `.install-attempt` 和 `.upgrade-attempt`，以终端提示为准。
- 离线升级使用已有规则缓存，不自动联网补齐。缓存缺失、为空或非法时拒绝发布并指出文件；ChinaList 允许 `cn`、`top`、`wang` 和 Punycode 顶级后缀。请先排查缓存，不要删除现有规则来绕过校验。
- 旧的非 Git `/opt/5gpn` 运行目录不必删除或改名。只有源码目录不算已安装；运行配置不完整时会拒绝升级，避免覆盖。源码检出或备份失败会保持旧源码不变。
- 不自动迁移古老的 dnsdist-only 部署或任意手工修改的 systemd 配置。旧 sing-box 出口的迁移限制见 [常见问题](GUIDE.md#常见问题)。

## 4. 常用管理命令

```bash
sudo /opt/5gpn/bin/5gpn-ctl --status
sudo /opt/5gpn/bin/5gpn-ctl --update-rules
sudo /opt/5gpn/bin/5gpn-ctl --renew-cert
sudo /opt/5gpn/bin/5gpn-ctl -ios
sudo /opt/5gpn/bin/5gpn-ctl --list-exits
sudo /opt/5gpn/bin/5gpn-ctl --check-exits
sudo /opt/5gpn/bin/5gpn-ctl --uninstall
```

需要变更 DNS、出口、规则或 Telegram Bot 时，请看 [日常管理与配置参考](GUIDE.md)。不要直接编辑生成配置；优先使用 `5gpn-ctl`。

## 5. 失败排查

### 安装或升级失败

先查看最后的错误和日志：

```bash
sudo tail -n 100 /var/log/5gpn-install.log
sudo find /var/backups/5gpn -maxdepth 2 -type f -name '*.log' -print
```

确认域名解析、公网 IPv4、磁盘空间和控制台访问正常，再重试。备份中可能包含私钥和 Token，请限制访问权限。

### 服务状态和日志

```bash
sudo systemctl --failed
sudo systemctl status mosdns sniproxy wa-shim quic-proxy 5gpn-tgbot
sudo journalctl -u mosdns -u sniproxy -u wa-shim -u quic-proxy -u 5gpn-tgbot -n 100 --no-pager
```

服务名称可能因出口配置带有 `5gpn-mihomo@*` 实例；用 `systemctl list-units '5gpn-*'` 查看完整列表。

### 证书签发失败

确认 A 记录已指向本机，且公网可以访问 TCP 80。脚本会在签发或续期时临时调整 sniproxy 和 80 端口规则，完成后恢复。

### DoT 测试

下面命令要求 `dig` 支持 `+tls`（较老版本可能不支持）：

```bash
dig +tls @dns.example.com -p 853 youtube.com
```

如果只有部分域名异常，先运行 `--update-rules`；如果所有查询失败，先检查 `mosdns` 状态、853 端口和域名证书。

## 6. 安全边界

安装会修改系统服务、路由和网络规则，建议在维护窗口操作并保留云厂商控制台。默认不清空主机防火墙；`FIREWALL_MODE=auto` 增量放行所需端口，`FIREWALL_MODE=managed` 才会接管 INPUT 防火墙，使用前请确认 SSH 端口。

mihomo 和 mosdns 默认使用锁定版本及 SHA256 校验。通过 `MIHOMO_VERSION` 或 `MOSDNS_VERSION` 覆盖版本会跳过对应锁定摘要校验，并在安装时警告。

管道安装意味着信任本仓库 GitHub `main`；固定 SHA 可以复现源码，但不是发布签名认证。首次安装涉及的系统包、网络规则和服务更改不支持跨阶段全量回滚；升级中的局部事务保护也不等于整台主机能原子恢复。

### iOS 通知延迟 / 打开应用才收到

`push.apple.com` 及其子域默认返回真实地址，避免 APNs 的 TCP/5223 连接被送到不支持该端口的网关；显式 `--proxy-domain` 覆盖仍优先。设备所在的蜂窝/专网需允许直达 Apple TCP/5223（443 回退），不应仅在本网关开放入站 5223 来代替。

升级后切换一次飞行模式，让 iOS 重建 DNS 和 APNs 连接，然后锁屏空闲 5–10 分钟，由另一设备发送消息验证。不要强制结束应用。若仍延迟，应检查实际 APNs DNS 响应、设备到 Apple 的路由及端口、iOS 通知权限/专注模式/定时摘要；只验证服务启动或 DNS 正常不能证明推送已恢复。

历史性能档的 30 秒 TCP conntrack 超时会迁移到 86400 秒；essential 档和自定义超时不变。可只读核对：`sysctl net.netfilter.nf_conntrack_tcp_timeout_established`。不要清空 conntrack 或重装描述文件来诊断。
