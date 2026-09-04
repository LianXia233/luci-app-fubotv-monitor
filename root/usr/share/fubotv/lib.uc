#!/usr/bin/env ucode
'use strict';
/*
 * fubotv-monitor -- 系统指标采集库
 *
 * 提供三项指标，与原版 Windows 上位机的 T1/T2/T3 一一对应：
 *   CPU -- 处理器总占用率(%)
 *   RAM -- 内存占用率(%)
 *   VOL -- LAN 接口带宽占用率(%)（全双工链路，取收发均值占单向带宽的百分比）
 *
 * CPU 与 VOL 均为差值型指标，需要在进程内保留上一次快照，
 * 因此调用方必须常驻（由 procd 托管的守护进程），不能每次重新 exec。
 */

import { open, close, read, readdir } from 'fs';

/* ---------------------------------------------------------------- 基础工具 */

function readfile(path, limit) {
	let fh = open(path, 'r');

	if (!fh)
		return null;

	let data = read(fh, limit || 1048576);

	close(fh);

	return (data != null) ? data : '';
}

function lines(str) {
	if (str == null || str == '')
		return [];

	return split(str, '\n');
}

function fields(str) {
	if (str == null)
		return [];

	return split(trim(str), /\s+/);
}

function clamp_pct(v) {
	if (v == null || v != v)
		return 0;
	if (v < 0)
		return 0;
	if (v > 100)
		return 100;

	return v;
}

function round1(v) {
	return int(clamp_pct(v) * 10 + 0.5) / 10;
}

/* 单引号包裹并转义内部单引号，供拼接 shell 命令时使用 */
function shquote(s) {
	return "'" + join(split('' + s, "'"), "'\\''") + "'";
}

/* --------------------------------------------------------------- CPU 占用率 */

let cpu_prev = null;

/*
 * /proc/stat 首行为汇总行:
 *   cpu user nice system idle iowait irq softirq steal guest guest_nice
 * 占用率 = (delta_total - delta_idle) / delta_total
 * 其中 idle 计入 idle + iowait，与 top / htop 口径一致。
 */
function cpu_usage() {
	let data = readfile('/proc/stat', 65536);

	if (!data)
		return 0;

	let parts = fields(lines(data)[0]);

	if (parts[0] != 'cpu' || length(parts) < 9)
		return 0;

	let user    = int(parts[1]) || 0;
	let nice    = int(parts[2]) || 0;
	let system  = int(parts[3]) || 0;
	let idle    = int(parts[4]) || 0;
	let iowait  = int(parts[5]) || 0;
	let irq     = int(parts[6]) || 0;
	let softirq = int(parts[7]) || 0;
	let steal   = int(parts[8]) || 0;

	let total    = user + nice + system + idle + iowait + irq + softirq + steal;
	let idle_all = idle + iowait;

	let usage = 0;

	if (cpu_prev != null) {
		let d_total = total - cpu_prev.total;
		let d_idle  = idle_all - cpu_prev.idle;

		if (d_total > 0)
			usage = (d_total - d_idle) * 100 / d_total;
	}

	cpu_prev = { total: total, idle: idle_all };

	return round1(usage);
}

/* --------------------------------------------------------------- 内存占用率 */

/*
 * 使用 MemAvailable 而非 MemFree：前者已扣除可回收的 buff/cache，
 * 与 free(1) 的 available 列口径一致，不会因文件缓存而虚高。
 */
function mem_usage() {
	let data = readfile('/proc/meminfo', 65536);

	if (!data)
		return 0;

	let total = 0;
	let avail = 0;
	let have_avail = false;

	for (let line in lines(data)) {
		if (match(line, /^MemTotal:/))
			total = int(fields(line)[1]) || 0;
		else if (match(line, /^MemAvailable:/)) {
			avail = int(fields(line)[1]) || 0;
			have_avail = true;
		}
	}

	if (total <= 0 || !have_avail)
		return 0;

	return round1((total - avail) * 100 / total);
}

/* ------------------------------------------------------------ 接口收发字节 */

function iface_bytes(ifname) {
	let data = readfile('/proc/net/dev', 131072);

	if (!data)
		return null;

	for (let line in lines(data)) {
		let pos = index(line, ':');

		if (pos < 0)
			continue;

		if (trim(substr(line, 0, pos)) != ifname)
			continue;

		let f = fields(substr(line, pos + 1));

		if (length(f) < 9)
			return null;

		return { rx: int(f[0]) || 0, tx: int(f[8]) || 0 };
	}

	return null;
}

/*
 * 探测接口速率(Mbps)。
 * 1) 直接读 /sys/class/net/<if>/speed
 * 2) 若是网桥(br-lan)，遍历 brif/ 成员口取最大速率
 * 3) 都拿不到则返回 null，由调用方回退到 UCI 里的 linkspeed
 */
function iface_speed_mbps(ifname) {
	let s = readfile('/sys/class/net/' + ifname + '/speed', 64);

	if (s != null) {
		let v = int(trim(s)) || 0;

		if (v > 0 && v < 1000000)
			return v;
	}

	let members = readdir('/sys/class/net/' + ifname + '/brif');

	if (members) {
		let best = 0;

		for (let m in members) {
			let ms = readfile('/sys/class/net/' + m + '/speed', 64);

			if (ms == null)
				continue;

			let v = int(trim(ms)) || 0;

			if (v > best && v < 1000000)
				best = v;
		}

		if (best > 0)
			return best;
	}

	return null;
}

/* ------------------------------------------------------- LAN 带宽占用率(VOL) */

let vol_prev = null;
let vol_rate = { rx: 0, tx: 0 };

function vol_usage(ifname, fallback_mbps) {
	let cur = iface_bytes(ifname);

	if (!cur)
		return 0;

	let now = time();

	/* 首次调用或接口变更时只建立基准，本拍返回 0 */
	if (vol_prev == null || vol_prev.iface != ifname) {
		vol_prev = { iface: ifname, rx: cur.rx, tx: cur.tx, t: now };
		vol_rate = { rx: 0, tx: 0 };
		return 0;
	}

	let d_rx = cur.rx - vol_prev.rx;
	let d_tx = cur.tx - vol_prev.tx;
	let dt   = now - vol_prev.t;

	vol_prev = { iface: ifname, rx: cur.rx, tx: cur.tx, t: now };

	if (dt <= 0)
		return 0;

	/* 接口被删除重建或计数器溢出时会出现回绕，丢弃该拍 */
	if (d_rx < 0)
		d_rx = 0;
	if (d_tx < 0)
		d_tx = 0;

	let mbps = iface_speed_mbps(ifname);
	let speed = (mbps != null) ? mbps : (int(fallback_mbps) || 0);

	if (speed <= 0)
		return 0;

	let rx_bps = d_rx * 8 / dt;
	let tx_bps = d_tx * 8 / dt;

	vol_rate = { rx: int(rx_bps), tx: int(tx_bps) };

	/* 全双工：上下行各占一条通道，取均值对单向带宽求百分比 */
	return round1((rx_bps + tx_bps) / 2 * 100 / (speed * 1000000));
}

/* ------------------------------------------------------------------ 导出 */

return {
	readfile: readfile,
	lines: lines,
	fields: fields,
	clamp_pct: clamp_pct,
	round1: round1,
	shquote: shquote,
	cpu_usage: cpu_usage,
	mem_usage: mem_usage,
	vol_usage: vol_usage,
	vol_throughput: function() { return vol_rate; },
	iface_bytes: iface_bytes,
	iface_speed_mbps: iface_speed_mbps
};
