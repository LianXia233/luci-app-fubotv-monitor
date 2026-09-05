'use strict';
/*
 * fubotv-monitor -- 系统指标采集库
 *
 * 提供三项指标，与原版 Windows 上位机的 T1/T2/T3 一一对应：
 *   CPU  -- 处理器总占用率(%)
 *   RAM  -- 内存占用率(%)
 *   TEMP -- CPU 核心温度(°C，四舍五入取整)
 *
 * CPU 为差值型指标，需要在进程内保留上一次快照，
 * 因此调用方必须常驻（由 procd 托管的守护进程），不能每次重新 exec。
 * TEMP 为瞬时采样（读 thermal zone），无需快照。
 *
 * 适配 OpenWrt 25.x / ImmortalWrt SNAPSHOT 的 ucode 2026.07+ API：
 *   - fs 模块导出 readfile/writefile/open/unlink/lsdir（无 close/read/readdir）
 *   - 文件句柄自带 f.read() / f.close()
 *   - 顶层导出必须用 export { ... }（return { } 仅供 rpcd compile() 加载）
 *   - 无内置 json 编码器（全局 json() 仅为解码器）
 */

import * as fs from 'fs';

/* ---------------------------------------------------------------- 基础工具 */

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
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function read_text(path) {
	return fs.readfile(path);
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

/* --------------------------------------------------------------- CPU 占用率 */

let cpu_prev = null;

/*
 * /proc/stat 首行为汇总行:
 *   cpu user nice system idle iowait irq softirq steal guest guest_nice
 * 占用率 = (delta_total - delta_idle) / delta_total
 * 其中 idle 计入 idle + iowait，与 top / htop 口径一致。
 * 9 字段阈值兼容 5.18+ 内核（加入 guest / guest_nice）。
 */
function cpu_usage() {
	let data = read_text('/proc/stat');

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
 * 老内核可能没有 MemAvailable 字段，此时降级用 MemFree 估算。
 */
function mem_usage() {
	let data = read_text('/proc/meminfo');

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
		else if (match(line, /^MemFree:/) && !have_avail)
			avail = int(fields(line)[1]) || 0;
	}

	if (total <= 0)
		return 0;

	return round1((total - avail) * 100 / total);
}

/* ---------------------------------------------------------- CPU 温度(°C) */

/*
 * 读 /sys/class/thermal/ 下各 thermal_zone 目录的 temp 文件，
 * 内核以毫摄氏度给出。遍历各 zone，取第一个可读且非零的温度，
 * 除以 1000 得 °C，再四舍五入取整（int(m / 1000 + 0.5)）。
 * 路由器(如 mediatek/filogic)通常 thermal_zone0 即 CPU 封装温度。
 * 全部 zone 缺失/为零时回退 0（设备无可用传感器）。
 */
function cpu_temp() {
	let zones = fs.lsdir('/sys/class/thermal');

	if (zones) {
		for (let z in zones) {
			if (substr(z, 0, 12) != 'thermal_zone')
				continue;

			let raw = read_text('/sys/class/thermal/' + z + '/temp');

			if (raw == null)
				continue;

			let m = int(trim(raw)) || 0;

			if (m > 0)
				return int(m / 1000 + 0.5);
		}
	}

	return 0;
}

/* ------------------------------------------------------------------ 导出 */

export {
	clamp_pct,
	round1,
	shquote,
	cpu_usage,
	mem_usage,
	cpu_temp
};
