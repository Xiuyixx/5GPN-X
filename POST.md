# kfchost 5gpn 服务端反代网关 | 客户端只配一个 DNS,被墙域名自动走代理(开源)

发个东西。这是给 **kfchost 的 5gpn(5G 专网)** 配套的一套服务端透明反代网关 —— 跑在 5gpn 服务器上,给专网里的终端做智能 DNS + SNI 透明代理。客户端不用装任何东西,把 DNS 指过去就能用。代码开源,MIT 协议。

仓库:https://github.com/lingchenfs1/5gpn

一键安装(交互输入你自己的域名):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/install.sh)"
```

## 思路

把"分流 + 代理"全放到网关侧,客户端只配一个 **DoT(DNS over TLS)** 就完事:

- 被墙域名 → 智能 DNS 把它解析成**网关自己的 IP**,流量被引进网关的 SNI 透明代理再转出去
- 国内域名 → 国内 DNS 并发竞速,正常直连
- 其它海外域名 → 海外 DNS 池

全程不解密 TLS,只看 SNI,所以性能很高。Android 填个私人 DNS、iOS 扫码装个描述文件、电视盒子/游戏机改下 DNS 都能用,省去每台设备装客户端。

## 架构

```
客户端 (DoT 853)
   │
   ▼
dnsdist ── 被墙域名 ──► 返回网关IP ──► sniproxy   (TCP 80/443)
   │                                  quic-proxy (UDP 443 / HTTP3)
   ├── 国内域名 ──► 国内 DNS 并发竞速
   └── 海外域名 ──► 海外 DNS 池
                                          │
                                          ▼
                            出口层:直出 / WireGuard / SOCKS5 / Shadowsocks
```

## 特性

- **国内 DNS 并发竞速**:同时并发查多个国内公共 DNS 的 UDP 53,150ms 没结果就并发改走国内 TCP 53(对付 UDP 污染/限速),再不行才上海外兜底。
- **QUIC/HTTP3 也走透明代理**:老 sniproxy 只管 TCP,这里用 Go 标准库实现了一个 QUIC SNI 代理(按 RFC 9000 解 Initial 包抠 SNI),纯标准库零依赖。
- **出口可切换、可按域名分流**:出口在路由层实现(打 mark + 策略路由 → 选定的隧道/TUN),TCP 和 QUIC 全自动跟着走。支持直出 / WireGuard / SOCKS5(含 socks5h 远程 DNS)/ Shadowsocks / SS2022。
- **按域名分流到不同出口**:可写一份域名分流规则,把不同网站分到不同出口/直连/拒绝;规则集支持本地域名表和远程 URL,会编译成紧凑的二进制规则集(40 个列表实测占 200 多 KB、运行内存约 30MB)。
- **低内存模式(自动)**:内存 ≤ 1GB 自动开启,缩缓存、调 sysctl、按需启动服务、限 Go 内存；安装时可交互输入自定义 swap 大小（数字默认按 `G`，也支持直接写 `0.5G/1G/2G`），若不需要可输入 `0` / `n` / `no` / `skip` 跳过，脚本会按输入决定是否创建 swap，并把编译限制为单线程防 OOM。512MB 也能跑。
- **Telegram Bot 运维**:中文菜单,状态(含 CPU/内存/连接数/实时流量)、切换/添加/删除出口、分流规则、更新规则、续期证书、重启、看日志、出 iOS 二维码;只有白名单 ID 能操作。

## 装好之后

客户端把 DoT 指到你的域名即可。服务器侧常用命令:

```bash
sudo ./install.sh --status         # 运行状态 + 当前出口
sudo ./install.sh --set-exit <名字|local>   # 切出口
sudo ./install.sh --check-exits    # 检查各出口节点是否可达
sudo ./install.sh --import-rules <规则文件>  # 导入域名分流规则
```

## 注意

- 多出口分流时,**某个出口节点挂了会黑洞掉走它的全部流量**(包括兜底规则)。排查"突然全打不开"先 `--check-exits` 看一眼节点死活,能省一大圈。
- 仅用于合法的跨境业务互通与技术研究,请遵守当地法律法规。

## 支持的系统

Ubuntu 20.04+ / Debian 11+ / CentOS·Rocky·Alma 7-9 / RHEL 8-9 / Fedora 39+,x86_64 / ARM64,需公网 IPv4 + 一个你能管理 DNS 的域名。

---

仓库:https://github.com/lingchenfs1/5gpn,MIT 协议,欢迎 issue / PR。
