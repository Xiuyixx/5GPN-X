# 项目结构与本地检查

[返回首页](../README.md) · [安装、升级与排障](INSTALL.md)

## 目录职责

- `install.sh`：唯一安装入口，同时把管理参数转给已安装的 `5gpn-ctl`。
- `lib/common.sh`：共享路径、日志、校验和基础工具。
- `lib/dns.sh`、`lib/rules.sh`：DNS、规则与配置事务。
- `lib/cert.sh`：证书申请和续期。
- `lib/services.sh`、`lib/exits.sh`：服务部署、出口和路由。
- `lib/host-setup.sh`：防火墙与内核调优。
- `lib/uninstall.sh`、`lib/update-rules.sh`：卸载与规则更新。
- `lib/*.py`、`lib/*.go`：Bot、配置生成器、兼容组件和 QUIC 代理。
- `docs/`：面向用户的安装、日常管理和配置参考；不要把实现细节堆回 README 主路径。
- `tests/`：按策略和行为分组的回归测试。

## 本地检查

完整检查与 CI 接近：

```bash
shellcheck -x install.sh lib/*.sh
python3 -m py_compile lib/*.py
ruff check lib/ tests/
for t in tests/*.sh; do bash "$t"; done
for t in tests/*.py; do python3 "$t"; done
for t in tests/*.ps1; do pwsh -NoProfile -File "$t"; done
```

APNs DNS 行为测试用真实 mosdns `5.3.4` 和回环假上游验证分流、后缀边界、显式覆盖优先级、公网策略和 AAAA；不访问公网 DNS，也不改主机配置。使用已核验的锁定二进制：

```bash
PGW_TEST_MOSDNS=/absolute/path/to/mosdns python3 tests/test_apns_dns_integration.py
```

未设置该变量时此项跳过；Ubuntu CI 下载并校验项目锁定二进制后强制执行。此测试不代表 iPhone 锁屏推送或设备所在网络直达 APNs 已验收。

QUIC 代理测试需要 Go：

```bash
tmp=$(mktemp -d)
cp lib/quic-proxy.go lib/quic-proxy_test.go "$tmp"/
(cd "$tmp" && go mod init quic-proxy >/dev/null && go vet ./... && go test ./...)
rm -rf "$tmp"
```

测试应在隔离环境中运行；不要在真实服务器上执行安装、升级、卸载或依赖系统服务的测试。修改用户可见文档时，检查 README 中的链接和 `tests/*README*`、PowerShell 文档策略测试。
