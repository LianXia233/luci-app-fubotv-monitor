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

## Unreleased

- 待补充
