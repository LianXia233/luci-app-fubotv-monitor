# Changelog

## v1.0.0 - 2026-09-05

- 初始版本：FuBoTv 监控 Luci 插件
- 上报 CPU / RAM / LAN 接口带宽占用率至 ESP8266 天气时钟
- 上报协议兼容原 Windows 上位机：`POST /PCM` 表单主体 `admin=root&T1=<cpu>&T2=<ram>&T3=<vol>`
- 上报目标 IP / 端口 / 路径 / 鉴权参数均可自定义（UCI 配置）
- 守护进程常驻（procd 托管），首拍建立差值基准，第二拍起正常上报
- 界面：LuCI 配置页 + 实时仪表盘（2 秒轮询），含连通性测试
- 采集库与上报守护进程用 ucode 实现，后端经 rpcd 暴露 ubus 接口 `luci.fubotv`
- 修复：移除 `LUCI_DEPENDS` 中已废弃的 `ucode-mod-json` 依赖。OpenWrt 25.x 的 JSON 能力已内置进 `ucode`/`libucode` 核心（`import * as json from 'json'` 解析为内置模块），原 `ucode-mod-json` 包在 25.x 仓库中不存在，会导致 `apk add` 报 `ucode-mod-json (no such package)` 而安装失败
- 修复：上报方法由 GET 改为 POST 表单（实机协议验证）。设备仅接受 `POST /PCM`（GET 返回 404），凭据 `admin=root` 为表单首字段，成功响应正文为回执令牌 `0637`；守护进程与连通性测试均按 POST 发送，测试弹窗显示完整请求与设备响应
- 修复（关键，实机 25.x 验证）：ucode 2026.07+ 全局 `join(arr, sep)` 在本机型返回 `null`（既非可用全局函数也非数组成员方法），导致三处依赖它的代码静默失效：
  - `json_encode()` 产出空串，`fs.writefile` 写入 0 字节状态文件，前端读不出任何指标（页面显示 `--`）；
  - `build_body()` 产出 `null`，上报主体为空；
  - `shquote()` 产出 `'null'`，curl 的 `-H`/`--data`/`URL` 参数全部变成字面量 `'null'`，curl 把 `'null'` 当主机名解析失败（报错「无法解析主机」），上报 100% 失败。
  已改用手动字符串拼接与 `replace()` 重写这三处，状态文件恢复为有效 JSON，上报成功率回到正常。
- 修复（关键）：`/usr/share/rpcd/ucode/luci.fubotv` 顶层 `return` 缺少 rpcd 要求的 `'luci.fubotv':` 包裹对象，导致 `ubus list luci.fubotv` 报 `Not found`、前端无法读取状态。已改为 `return { 'luci.fubotv': { status: {...}, test: {...} } }`。
- 修复（25.x 语法）：`import` 加载的 `.uc` 模块顶层必须用 `export { ... }` 导出（原 `return { ... }` 报 `Syntax error: return must be inside function body`）；文件首行 `#!/usr/bin/env ucode` 在 import 时会被当作代码解析而破坏模块，已移除所有 `.uc` 的 shebang；全局 `json(string)` 仅为解码器（无 `json.encode`），状态文件读取改用 `json(raw)` 解码、写入改用自写 `json_encode()`。
- 修复（前端）：LuCI 视图 `status.js` 的 `TypedSection` 原误用配置名 `main` 作为 section 类型，实机 UCI 类型为 `fubotv`，导致配置区显示「尚无任何配置」且缺少全局启用开关。已改为 `TypedSection, 'fubotv'` 并显式 `anonymous=false / addremove=false`，`enabled` 开关与全部配置项正常显示、可增改。
- 修复（实机踩坑）：`/etc/config/fubotv` 的 `auth` 选项被 LuCI 表单「保存并应用」误删（`auth` 字段原设 `rmempty=true`，空值即删除），导致上报主体丢失 `admin=root&` 前缀，ESP8266 因凭据缺失直接断连（curl 退出码 52/56、HTTP 0），连通性测试报「设备无响应」。已三重加固：① 后端 `uci_conf()` / `load_config()` 的 `auth` 缺省值改为 `admin=root`（配置缺项也不致失败）；② `status.js` 的 `auth` 字段 `rmempty` 改为 `false`，保存不再能误删；③ 设备配置补回 `option auth 'admin=root'`。

## v1.0.1 - 2026-09-05

- 变更：第三项指标由 LAN 接口带宽占用率(VOL) 改为 **CPU 温度(TEMP)**（°C，四舍五入取整）
  - 采集：`lib.uc` 新增 `cpu_temp()`，读 `/sys/class/thermal/thermal_zone*/temp`（毫摄氏度），除以 1000 后四舍五入取整；遍历各 zone 取第一个非零读数
  - 上报：表单主体第三项改为 `T3=<温度>`，协议仍兼容原 Windows 上位机：`POST /PCM` 主体 `admin=root&T1=<cpu>&T2=<ram>&T3=<temp>`
  - 状态：`/var/run/fubotv.status` 与 ubus `luci.fubotv status` 的 `vol` 字段改名为 `temp`，移除 `rx_bps`/`tx_bps`/`linkspeed`/`linkspeed_auto` 等 LAN 专属字段
  - 界面：仪表盘 VOL 卡片改为 TEMP 卡片（单位 °C、整数显示、>=70°C 红色 / >=55°C 黄色分档），配置项 `param_vol` 改名 `param_temp`（默认仍为 T3），删除不再使用的 `interface`/`linkspeed` 配置项
- 变更：上报间隔单位由**秒**改为**毫秒**（`interval`，范围 100-3600000，默认 1000ms）
  - `report.uc` 的 tick 装载值不再 ×1000，直接按毫秒装填 uloop 定时器
  - 界面表单校验范围与状态条单位同步改为 ms
  - 注意：旧配置中的秒值（如 `option interval '2'`）升级后语义变为 2ms，会被钳制到最小 100ms；建议升级后手动改为毫秒值（如 `1000`）
  - 注意：升级后需在设备上将 UCI 的 `param_vol` 改名为 `param_temp`（或删除旧项用默认值），否则上报第三项回退为默认 T3

## Unreleased

- 待补充
