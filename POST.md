# 5GPN-X 服务端透明代理网关 | 客户端只配一个 DNS，国际流量自动进入网关

发个东西。这是给 **kfchost 的 5gpn(5G 专网)** 配套的一套服务端透明代理网关 —— 跑在 5gpn 服务器上，给专网里的终端提供智能 DNS、SNI/QUIC 转发、mihomo 多协议出口和智能分流。客户端不用安装代理软件，把 DNS 指过去就能用。代码开源，MIT 协议。

仓库：https://github.com/Xiuyixx/5GPN-X

一键安装(交互输入你自己的域名):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh)"
```

## 思路

把“分流 + 代理”全放到网关侧，客户端只配一个 **DoT（DNS over TLS）** 即可：

- ChinaList 国内域名 → 国内 DNS 并发竞速，保持本地访问体验
- `172.22.0.0/16` 私网客户端的非 ChinaList IPv4 → 返回**网关自己的 IP**，流量进入 wa-shim / sniproxy / quic-proxy，再从当前出口发出
- 其他公网 DoT 客户端的非 ChinaList 查询 → 海外 DNS 池正常解析，不执行私网劫持

网关不解密 TLS：HTTPS/QUIC 只读取握手中的 SNI，WhatsApp Patch 只识别无 SNI Noise 连接的协议前缀。Android 填私人 DNS、iOS 扫码安装描述文件、电视盒子或游戏机修改 DNS 即可使用，省去每台设备安装客户端。

## 架构

```
客户端 (DoT 853)
   │
   ▼
dnsdist ── 私网非 ChinaList ──► 返回网关IP ──► wa-shim    (TCP 443 / WhatsApp Noise)
   │                                  sniproxy   (TCP 80/443 SNI/Host)
   │                                  quic-proxy (UDP 443 / HTTP3)
   ├── 国内域名 ──► 国内 DNS 并发竞速
   └── 其他公网 DoT 非 ChinaList ──► 海外 DNS 池
                                          │
                                          ▼
                            出口层:直出 / WireGuard / mihomo 多协议 TUN
```

## 特性

- **国内 DNS 并发竞速**:同时并发查多个国内公共 DNS 的 UDP 53,150ms 没结果就并发改走国内 TCP 53(对付 UDP 污染/限速),再不行才上海外兜底。
- **QUIC/HTTP3 也走透明代理**:老 sniproxy 只管 TCP,这里用 Go 标准库实现了一个 QUIC SNI 代理(按 RFC 9000 解 Initial 包抠 SNI),纯标准库零依赖。
- **mihomo 多协议出口**:出口在路由层实现(打 mark + 策略路由 → 选定的隧道/TUN),TCP 和 QUIC 全自动跟着走。支持直出、WireGuard、SOCKS5/SOCKS5H、SS/SS2022、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS 和 HTTP/HTTPS。
- **智能分流与规则提供器**:mihomo `smart` 出口可把域名、IP、GEOSITE、GEOIP 和 RULE-SET 分到不同出口/直连/拒绝。支持 `.mrs`、Clash YAML 和纯文本规则集，远程 provider 由内核定时更新；可整份导入，也可原子添加单条规则或规则集 URL。
- **iOS WhatsApp 无 SNI 补丁**:wa-shim 只处理客户端网段内以 `ED` / `WA` 开头的 WhatsApp Noise 连接，普通 TLS 和异常路径 fail-open 到 sniproxy，不解密业务内容。
- **低内存模式(自动)**:内存 ≤ 1GB 自动开启,缩缓存、调 sysctl、按需启动服务、限 Go 内存；安装时可交互输入自定义 swap 大小（数字默认按 `G`，也支持直接写 `0.5G/1G/2G`），若不需要可输入 `0` / `n` / `no` / `skip` 跳过，脚本会按输入决定是否创建 swap，并把编译限制为单线程防 OOM。512MB 也能跑。
- **Telegram Bot 运维**:中文菜单,状态(含 CPU/内存/连接数/实时流量)、切换/添加/删除出口、分流规则、更新规则、续期证书、重启、看日志、出 iOS 二维码;只有白名单 ID 能操作。

## 装好之后

客户端把 DoT 指到你的域名即可。服务器侧常用命令:

```bash
sudo ./install.sh --status         # 运行状态 + 当前出口
sudo ./install.sh --set-exit <名字|local>   # 切出口
sudo ./install.sh --check-exits    # 检查各出口节点是否可达
sudo ./install.sh --import-rules <规则文件>  # 导入域名分流规则
sudo ./install.sh --add-rule 'DOMAIN-SUFFIX,openai.com,us'
sudo ./install.sh --add-ruleset 'https://example.com/openai.mrs' us
sudo ./install.sh --set-exit smart # 启用 mihomo 智能分流
```

## 注意

- 多出口分流时,**某个出口节点挂了会黑洞掉走它的全部流量**(包括兜底规则)。排查"突然全打不开"先 `--check-exits` 看一眼节点死活,能省一大圈。
- 仅用于合法的跨境业务互通与技术研究,请遵守当地法律法规。

## 支持的系统

Ubuntu 20.04+ / Debian 11+ / CentOS·Rocky·Alma 7-9 / RHEL 8-9 / Fedora 39+,x86_64 / ARM64,需公网 IPv4 + 一个你能管理 DNS 的域名。

---

仓库：https://github.com/Xiuyixx/5GPN-X，MIT 协议，欢迎 issue / PR。
