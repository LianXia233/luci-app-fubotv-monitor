# Changelog

## v1.0.0 - 2026-09-05

- 初始版本：FuBoTv 监控 Luci 插件
- 上报 CPU / RAM / LAN 接口带宽占用率至 ESP8266 天气时钟
- 上报协议兼容原 Windows 上位机：`GET /PCM?T1=<cpu>&T2=<ram>&T3=<vol>`
- 上报目标 IP / 端口 / 路径 / 鉴权参数均可自定义（UCI 配置）
- 守护进程常驻（procd 托管），首拍建立差值基准，第二拍起正常上报
- 界面：LuCI 配置页 + 实时仪表盘（2 秒轮询），含连通性测试
- 采集库与上报守护进程用 ucode 实现，后端经 rpcd 暴露 ubus 接口 `luci.fubotv`
- 修复：移除 `LUCI_DEPENDS` 中已废弃的 `ucode-mod-json` 依赖。OpenWrt 25.x 的 JSON 能力已内置进 `ucode`/`libucode` 核心（`import * as json from 'json'` 解析为内置模块），原 `ucode-mod-json` 包在 25.x 仓库中不存在，会导致 `apk add` 报 `ucode-mod-json (no such package)` 而安装失败
- 修复：上报方法由 GET 改为 POST 表单（实机协议验证）。设备仅接受 `POST /PCM`（GET 返回 404），凭据 `admin=root` 为表单首字段，成功响应正文为回执令牌 `0637`；守护进程与连通性测试均按 POST 发送，测试弹窗显示完整请求与设备响应

## Unreleased

- 待补充
