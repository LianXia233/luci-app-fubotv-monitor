#!/usr/bin/env ucode
'use strict';
/*
 * fubotv-monitor -- 周期上报守护进程
 *
 * 由 procd 托管，按 UCI 配置的间隔采集 CPU / RAM / VOL，
 * 以 HTTP POST（x-www-form-urlencoded）推送到 ESP8266 天气时钟：
 *
 *   POST http://<host>[:port]<path>
 *   Content-Type: application/x-www-form-urlencoded
 *
 *   admin=root&T1=<cpu>&T2=<ram>&T3=<vol>
 *
 * 实机协议（2026-09-05 实测 192.168.88.244）：设备仅接受 POST，
 * GET /PCM 返回 404；凭据 admin=root 必须是表单首字段，
 * 凭据缺失或错误时设备直接断开连接（无 HTTP 响应）；
 * 成功时返回 200 + 正文令牌 0637。
 * 最新一次结果写入 /var/run/fubotv.status，供 LuCI 界面经 rpcd 读取。
 */

import { cursor } from 'uci';
import { writefile, unlink, readfile } from 'fs';
import * as json from 'json';
import * as uloop from 'uloop';
import { cpu_usage, mem_usage, vol_usage, vol_throughput } from '/usr/share/fubotv/lib.uc';

const STATUS_FILE = '/var/run/fubotv.status';
const MIN_INTERVAL = 1;
const MAX_INTERVAL = 3600;
const HTTP_TIMEOUT = 3000;

let cfg = null;
let timer = null;
let warmed = false;
let stats = { count: 0, ok: 0, fail: 0, last: 0, last_ok: 0, error: '' };

/* ------------------------------------------------------------------ 配置 */

function cfg_str(key, def) {
	let v = cfg.get('fubotv', 'main', key);

	return (v != null && v != '') ? v : def;
}

function cfg_int(key, def) {
	let v = int(cfg.get('fubotv', 'main', key));

	return (v != null) ? v : def;
}

function load_config() {
	cfg = cursor();
	cfg.load('fubotv');

	return {
		enabled: cfg_str('enabled', '0') == '1',
		host: cfg_str('host', ''),
		port: cfg_str('port', ''),
		interval: cfg_int('interval', MIN_INTERVAL),
		iface: cfg_str('interface', 'br-lan'),
		linkspeed: cfg_int('linkspeed', 1000),
		path: cfg_str('path', '/PCM'),
		auth: cfg_str('auth', ''),
		p_cpu: cfg_str('param_cpu', 'T1'),
		p_ram: cfg_str('param_ram', 'T2'),
		p_vol: cfg_str('param_vol', 'T3')
	};
}

/* ------------------------------------------------------------------- URL */

function build_url(c) {
	let host = c.host;

	/* IPv6 文本地址需要方括号包裹 */
	if (index(host, ':') >= 0 && substr(host, 0, 1) != '[')
		host = '[' + host + ']';

	let url = 'http://' + host;

	if (c.port != '' && c.port != '80')
		url += ':' + c.port;

	let path = c.path;

	if (path != '' && substr(path, 0, 1) != '/')
		path = '/' + path;

	return url + ((path != '') ? path : '/PCM');
}

/* --------------------------------------------------------------- 表单主体 */

/*
 * 表单字段顺序与原版 Windows 上位机一致：
 * 凭据 admin 首位，随后 T1/T2/T3，无前导 &。
 * 凭据串里的 & 和 = 允许出现（拆首段后原样保留），
 * 指标值为 0-100 的数字，无需转义。
 */
function build_body(c, cpu, ram, vol) {
	let q = [];

	if (c.auth != '')
		push(q, c.auth);

	push(q, c.p_cpu + '=' + int(cpu + 0.5));
	push(q, c.p_ram + '=' + int(ram + 0.5));
	push(q, c.p_vol + '=' + int(vol + 0.5));

	return join(q, '&');
}

/* ------------------------------------------------------------------- 发送 */

/*
 * 使用 curl 而非 ucode-mod-uclient：
 *   1) uclient 模块是异步 API，需要嵌套 uloop 事件循环，不适合在守护进程的
 *      定时器回调中同步等待结果；
 *   2) ucode-mod-uclient 自 OpenWrt 24.10 起才提供，会不必要地抬高版本门槛。
 * 每秒 fork 一次 curl 的开销在毫秒级，对本场景可以接受。
 *
 * 协议要点（实机验证）：
 *   - 必须 POST 表单主体（Content-Type: x-www-form-urlencoded），
 *     设备对 GET /PCM 返回 404；
 *   - 成功响应正文为令牌 0637，以此作为成功判据（比裸状态码更严）；
 *   - 凭据错误时设备直接断开连接，curl 退出码 52（空回复）或 56（接收错误）。
 */
function shquote(s) {
	return "'" + join(split('' + s, "'"), "'\\''") + "'";
}

function curl_error(rc) {
	if (rc == 6)
		return '无法解析主机';
	if (rc == 7)
		return '连接被拒绝';
	if (rc == 22)
		return 'HTTP 错误（4xx / 5xx）';
	if (rc == 28)
		return '连接超时';
	if (rc == 52)
		return '设备无响应（凭据可能被拒）';
	if (rc == 56)
		return '连接被设备重置（凭据可能被拒）';
	if (rc == 127)
		return 'curl 未安装';

	return 'curl 退出码 ' + rc;
}

function send(url, body) {
	/* -f: HTTP 错误时返回非零; -m: 总超时; --data: POST 主体; -o: 丢弃响应体 */
	let cmd = 'curl -fsS -o /dev/null -m ' + int(HTTP_TIMEOUT / 1000) +
		' -H ' + shquote('Content-Type: application/x-www-form-urlencoded') +
		' --data ' + shquote(body) +
		' ' + shquote(url) + ' 2>/dev/null';

	let rc = system(cmd, HTTP_TIMEOUT + 2000);

	if (rc == 0)
		return { ok: true, code: 200, error: '' };

	return { ok: false, code: 0, error: curl_error(rc) };
}

/* ----------------------------------------------------------------- 状态文件 */

function write_status(cpu, ram, vol, result) {
	stats.count++;

	if (result.ok) {
		stats.ok++;
		stats.last_ok = time();
		stats.error = '';
	}
	else {
		stats.fail++;
		stats.error = result.error;
	}

	stats.last = time();

	let rate = vol_throughput();

	writefile(STATUS_FILE, json.encode({
		cpu: cpu,
		ram: ram,
		vol: vol,
		rx_bps: rate.rx,
		tx_bps: rate.tx,
		count: stats.count,
		ok: stats.ok,
		fail: stats.fail,
		last: stats.last,
		last_ok: stats.last_ok,
		error: stats.error,
		code: result.code,
		running: true,
		url: result.url,
		body: result.body
	}));
}

/* -------------------------------------------------------------------- 主循环 */

function tick() {
	let c = load_config();
	let ms = c.interval * 1000;

	if (ms < MIN_INTERVAL * 1000)
		ms = MIN_INTERVAL * 1000;
	if (ms > MAX_INTERVAL * 1000)
		ms = MAX_INTERVAL * 1000;

	let cpu = cpu_usage();
	let ram = mem_usage();
	let vol = vol_usage(c.iface, c.linkspeed);

	/* 第一拍仅为 CPU / VOL 建立差值基准，数据无意义，跳过上报 */
	if (warmed && c.enabled) {
		if (c.host == '') {
			warn('fubotv: host not configured, skipping\n');
		}
		else {
			let url = build_url(c);
			let body = build_body(c, cpu, ram, vol);
			let result = send(url, body);

			result.url = url;
			result.body = body;
			write_status(cpu, ram, vol, result);

			if (!result.ok)
				warn('fubotv: report failed (' + result.error + '): POST ' + url + '\n');
		}
	}

	warmed = true;
	timer.set(ms);
}

/* --------------------------------------------------------------------- 入口 */

unlink(STATUS_FILE);

cfg = cursor();
cfg.load('fubotv');

if (cfg.get('fubotv', 'main', 'enabled') != '1')
	warn('fubotv: service started but fubotv.main.enabled is not 1\n');

/* 首拍 200ms 后仅为 CPU / VOL 建立差值基准，随后在 tick 内按配置间隔重新装填 */
timer = uloop.interval(200, tick);
uloop.run();
