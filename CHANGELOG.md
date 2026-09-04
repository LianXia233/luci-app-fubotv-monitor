# Changelog

## v1.0.0 - 2026-09-05

- 初始版本：FuBoTv 监控 Luci 插件
- 上报 CPU / RAM / LAN 接口带宽占用率至 ESP8266 天气时钟
- 上报协议兼容原 Windows 上位机：`GET /PCM?T1=<cpu>&T2=<ram>&T3=<vol>`
- 上报目标 IP / 端口 / 路径 / 鉴权参数均可自定义（UCI 配置）
- 守护进程常驻（procd 托管），首拍建立差值基准，第二拍起正常上报
- 界面：LuCI 配置页 + 实时仪表盘（2 秒轮询），含连通性测试
- 采集库与上报守护进程用 ucode 实现，后端经 rpcd 暴露 ubus 接口 `luci.fubotv`

## Unreleased

- 待补充
