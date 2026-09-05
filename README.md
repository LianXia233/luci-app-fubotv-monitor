# luci-app-fubotv-monitor

在 ImmortalWrt / OpenWrt 路由器上，把 CPU、内存与 LAN 接口占用率周期上报给 ESP8266「WiFi 天气时钟 / B站小电视」，由时钟屏幕直接显示。

协议与原版 Windows 上位机 `FuBoTv电脑性能监控.exe` 完全兼容，可直接替换掉常开的那台 Windows 机器。

- 后端：ucode（采集、上报、rpcd 接口）
- 前端：LuCI JS 视图（实时仪表盘 + 配置表单）
- 目标平台：ImmortalWrt 主线 / OpenWrt 23.05 及以上（LuCI 2.0，需 `rpcd-mod-ucode`）

---

## 一、工作原理

```
procd 守护进程 (ucode + uloop)
    |
    |-- /proc/stat      -> CPU 占用率   (T1)
    |-- /proc/meminfo   -> 内存占用率   (T2)
    |-- /proc/net/dev   -> LAN 带宽占用 (T3, VOL)
    |     速率基准优先读 /sys/class/net/<if>/speed，
    |     网桥则遍历 brif/ 成员口取最大值，取不到才回退到 UCI 的 linkspeed
    |
    +-- HTTP POST --> http://<时钟地址>/PCM
    |                 表单主体: admin=root&T1=<cpu>&T2=<ram>&T3=<vol>
    |                 每秒/每 N 秒一次，最新结果写入 /var/run/fubotv.status
```

LuCI 界面通过 `luci.fubotv.status` 读取状态文件，每 2 秒刷新一次仪表盘。

### 协议细节

协议已于 2026-09-05 在实机（192.168.88.244）验证，要点：

- **必须 POST 表单主体**（`Content-Type: application/x-www-form-urlencoded`），
  设备对 `GET /PCM` 返回 404——原版 exe 就是 POST，静态分析阶段误判为 GET
- **凭据 `admin=root` 是表单首字段**，无前导 `&`；凭据缺失或错误时设备直接
  断开连接，不返回任何 HTTP 响应（客户端表现为连接重置）
- 成功响应：`HTTP 200`，正文为固定回执令牌 **`0637`**，本插件以
  「200 + 令牌 0637」作为成功判据

请求格式：

```
POST http://<host>[:port]<path> HTTP/1.1
Content-Type: application/x-www-form-urlencoded

admin=root&T1=<cpu>&T2=<ram>&T3=<vol>
```

默认即原版上位机的格式：

```
POST http://192.168.88.244/PCM
主体: admin=root&T1=25&T2=60&T3=3
```

数值一律取整（时钟屏幕空间有限），保留 0-100 区间。

### 三项指标的口径

| 指标 | 默认参数名 | 计算方式 | 说明 |
|---|---|---|---|
| CPU | `T1` | `(Δtotal - Δidle) / Δtotal` | 读 `/proc/stat` 汇总行，idle 计入 `idle + iowait`，与 `top` 口径一致 |
| RAM | `T2` | `(MemTotal - MemAvailable) / MemTotal` | 用 `MemAvailable` 而非 `MemFree`，已扣除可回收的 buff/cache，与 `free` 的 available 列一致 |
| VOL | `T3` | `(rx_bps + tx_bps) / 2 / link_speed` | LAN 接口带宽占用百分比。全双工链路上下行各占一条通道，故取收发均值对单向带宽求百分比 |

**需要注意**：CPU 与 VOL 是差值型指标，必须在进程内保留上一次快照。这意味着采集逻辑只能常驻运行，不能每次上报重新 exec 一个进程——这也是本插件用守护进程而非 cron 的原因。服务启动后第一拍只建立基准，**第二拍起才有有效数据**。

---

## 二、安装

### 方式一：随固件编译

把本目录放到 `feeds/luci/applications/`（或 ImmortalWrt 的 `package/`）下：

```bash
cp -r luci-app-fubotv-monitor <SDK>/package/
cd <SDK>
./scripts/feeds install -a
make menuconfig    # LuCI -> Applications -> luci-app-fubotv-monitor
make package/luci-app-fubotv-monitor/compile V=s
```

产物在 `bin/packages/<arch>/luci/luci-app-fubotv-monitor_*.ipk`。

### 方式二：已有设备安装

先装依赖，再拷文件：

```bash
opkg update
opkg install curl ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus \
             ucode-mod-uloop rpcd-mod-ucode
```

```bash
scp -r luci-app-fubotv-monitor/root/*   root@192.168.1.1:/
scp -r luci-app-fubotv-monitor/htdocs/* root@192.168.1.1:/www/

ssh root@192.168.1.1 '
chmod 0755 /usr/share/fubotv/*.uc /usr/share/rpcd/ucode/luci.fubotv /etc/init.d/fubotv
/etc/init.d/fubotv enable
/etc/init.d/fubotv start
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
'
```

> 从 Windows 拷贝或从未设置可执行位的 git checkout 部署时，`chmod` 一步不可省略。
> ucode 脚本是 `/usr/bin/ucode` 解释执行的，shebang 只是兜底，但 `report.uc` 由 procd 显式调用 `ucode` 解释器，所以只要 `report.uc` 有读权限即可运行；`init.d/fubotv` 与 `luci.fubotv` 则必须有可执行位。

---

## 三、配置

界面路径：**服务 -> FuBoTv 上报**

### UCI 配置项

配置文件 `/etc/config/fubotv`，section `main`：

| 选项 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `0` | 是否启用周期上报 |
| `host` | string | `192.168.88.244` | 时钟的 IP 或主机名，支持 IPv6（自动加方括号） |
| `port` | string | `80` | HTTP 端口，留空或 `80` 时 URL 中省略 |
| `interval` | int | `1` | 上报间隔（秒），范围 1-3600 |
| `interface` | string | `br-lan` | VOL 统计的 LAN 接口 |
| `linkspeed` | int | `1000` | 接口速率回退值（Mbps），仅在自动探测失败时生效 |
| `path` | string | `/PCM` | 上报路径 |
| `auth` | string | `admin=root` | POST 表单主体的首个字段（认证串），留空则不附加 |
| `param_cpu` | string | `T1` | CPU 参数名 |
| `param_ram` | string | `T2` | 内存参数名 |
| `param_vol` | string | `T3` | LAN 占用参数名 |

命令行配置示例：

```bash
uci set fubotv.main.enabled='1'
uci set fubotv.main.host='192.168.88.244'
uci set fubotv.main.interval='2'
uci set fubotv.main.interface='br-lan'
uci commit fubotv
/etc/init.d/fubotv restart
```

配置变更会经 procd 的 config 触发器自动重载服务，LuCI 界面点「保存并应用」即可。

### 上报间隔怎么选

原版上位机固定 1 秒。路由器上 1 秒也完全可以承受（单次采集只读三个 /proc 文件，开销在毫秒级），但如果时钟端刷新跟不上或你介意日志量，2-3 秒更稳妥。

---

## 四、验证与排错

### 界面自查

配置页顶部有三张实时卡片与状态条，可直观看到：

- 服务是否在运行
- 已上报次数、成功/失败计数
- 最近一次请求的完整 URL
- 失败原因（HTTP 状态码或连接错误）

点「连通性测试」会立即做一次 1 秒窗口采样并发送单条 POST 上报，弹出的通知里包含完整 URL、表单主体与设备响应（成功时应显示回执令牌 0637）。

### 手动复现请求

```bash
curl -v -X POST 'http://192.168.88.244/PCM' \
	-H 'Content-Type: application/x-www-form-urlencoded' \
	--data 'admin=root&T1=25&T2=60&T3=3'
```

返回 200 且正文为 `0637` 即说明地址、路径、认证串都正确。

**注意**：不要用 `curl 'http://<时钟>/PCM?...'`（GET）去验证——设备对 GET 返回 404，
这是排查时最常见的误判。

### 常用排查命令

```bash
# 服务状态
/etc/init.d/fubotv status
ubus call service list '{"name":"fubotv"}'

# 最近一次上报结果（含完整 URL 与错误）
cat /var/run/fubotv.status

# 守护进程日志
logread -e fubotv

# 手动前台运行，观察实时输出
ucode /usr/share/fubotv/report.uc
```

### 常见问题

**卡片一直显示 `--`**
守护进程刚启动，处于第一拍基准期，等一个间隔再看。若持续为 `--`，检查 `/var/run/fubotv.status` 是否存在。

**VOL 恒为 0**
接口名填错（用 `ip link` 确认），或该接口确实没有流量。千兆口下 100 Mbps 流量对应 VOL = 10%，小流量场景数值本来就很小，属正常。

**VOL 数值明显偏大**
速率基准探测失败，回退到了 `linkspeed`。界面上接口速率后面带 `*` 号即表示未自动探测到。此时手动把 `linkspeed` 改成实际速率即可。

**上报全部失败**
- 用 GET 而非 POST 验证（设备对 GET /PCM 返回 404，属预期行为）
- 认证串缺失或不是 `admin=root`（设备直接断连，无 HTTP 响应）
- 时钟与路由器不在同一网段
- 时钟固件不支持电脑性能监控（部分一代/二代固件无此功能）
- 时钟后台未开启对应主题

**界面报权限错误 / RPC 调用失败**
确认 `rpcd-mod-ucode` 已安装，且已执行 `/etc/init.d/rpcd restart`。可直接在命令行验证：

```bash
ubus -v list luci.fubotv
ubus call luci.fubotv status
```

---

## 五、目录结构

```
luci-app-fubotv-monitor/
├── Makefile                                            构建定义
├── htdocs/luci-static/resources/
│   ├── fubotv/dashboard.css                            仪表盘样式
│   └── view/fubotv/status.js                           LuCI JS 视图
└── root/
    ├── etc/config/fubotv                               UCI 默认配置
    ├── etc/init.d/fubotv                               procd 服务脚本
    └── usr/share/
        ├── fubotv/
        │   ├── lib.uc                                  指标采集库
        │   └── report.uc                               周期上报守护进程
        ├── luci/menu.d/luci-app-fubotv-monitor.json    菜单项
        └── rpcd/
            ├── acl.d/luci-app-fubotv-monitor.json      ACL 授权
            └── ucode/luci.fubotv                       rpcd ucode 后端
```

### 后端接口

`ubus` 对象 `luci.fubotv`：

| 方法 | 说明 |
|---|---|
| `status()` | 返回运行态、三项指标、上报统计、自动探测到的接口速率 |
| `test()` | 采样 1 秒后发送单条 POST 上报，返回成功与否、HTTP 状态码、设备响应、完整 URL 与表单主体 |

---

## 六、安全说明

- 上报为**明文 HTTP**，同网段设备均可观测到 CPU / 内存数据。泄露面很小，但如需规避，请配合 VLAN 隔离。
- `admin=root` 是时钟固件的硬编码凭据（POST 表单首字段），同网段任何人都能向时钟写入显示内容。这是原版上位机的既有设计，本插件为兼容而保留，可在配置中清空。
- 插件不含任何对外网的连接，目标地址完全由使用者指定。

---

## 七、许可

MIT
