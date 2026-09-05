'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

/*
 * fubotv-monitor -- LuCI 视图
 *
 * 上半部分为实时仪表盘（CPU / RAM / TEMP），每 2 秒经 luci.fubotv.status 刷新；
 * 下半部分为 UCI 配置表单，保存后由 procd 的 config 触发器自动重载守护进程。
 */

var callStatus = rpc.declare({
	object: 'luci.fubotv',
	method: 'status',
	expect: { '': {} }
});

var callTest = rpc.declare({
	object: 'luci.fubotv',
	method: 'test',
	expect: { '': {} }
});

var refreshTimer = null;

/* ------------------------------------------------------------------ 工具 */

function pct(v) {
	var n = parseFloat(v);

	if (isNaN(n))
		return null;

	return Math.min(100, Math.max(0, n));
}

function level(n) {
	if (n === null)
		return 'ftv-lv-idle';
	if (n >= 85)
		return 'ftv-lv-high';
	if (n >= 60)
		return 'ftv-lv-mid';

	return 'ftv-lv-low';
}

/* 温度分档：>=70°C 高负载警示，>=55°C 偏热，其余正常 */
function tempLevel(t) {
	if (t === null)
		return 'ftv-lv-idle';
	if (t >= 70)
		return 'ftv-lv-high';
	if (t >= 55)
		return 'ftv-lv-mid';

	return 'ftv-lv-low';
}

function fmtNum(v, decimals) {
	return (v === null) ? '--' : v.toFixed(decimals === undefined ? 1 : decimals);
}

function pad2(n) {
	return (n < 10 ? '0' : '') + n;
}

function fmtTime(ts) {
	if (!ts)
		return _('从未');

	var d = new Date(ts * 1000);

	return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
		' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

/* ------------------------------------------------------------------ 卡片 */

function card(key, desc, value, foot, opts) {
	var isTemp = (opts && opts.temp);
	var n = isTemp ? parseFloat(value) : pct(value);
	var lvl = isTemp ? tempLevel(n) : level(n);
	var decimals = (opts && opts.decimals !== undefined) ? opts.decimals : 1;
	var unit = (opts && opts.unit) || '%';

	return E('div', { 'class': 'ftv-card ' + lvl }, [
		E('div', { 'class': 'ftv-head' }, [
			E('span', { 'class': 'ftv-key' }, key),
			E('span', { 'class': 'ftv-desc' }, desc)
		]),
		E('div', { 'class': 'ftv-num' }, [
			E('span', {
				'class': 'ftv-num-v',
				'data-ftv-value': key,
				'data-ftv-temp': isTemp ? '1' : '',
				'data-ftv-decimals': decimals
			}, fmtNum(n, decimals)),
			E('span', { 'class': 'ftv-num-u' }, unit)
		]),
		E('div', { 'class': 'ftv-bar' }, [
			E('div', {
				'class': 'ftv-bar-fill',
				'data-ftv-bar': key,
				'style': 'width:' + (n === null ? 0 : Math.min(100, Math.max(0, n))) + '%'
			}, '')
		]),
		E('div', { 'class': 'ftv-foot', 'data-ftv-foot': key }, foot || [])
	]);
}

function updateCard(key, value, foot) {
	var vEl = document.querySelector('[data-ftv-value="' + key + '"]');
	var bEl = document.querySelector('[data-ftv-bar="' + key + '"]');
	var fEl = document.querySelector('[data-ftv-foot="' + key + '"]');

	if (!vEl || !bEl)
		return;

	var isTemp = (vEl.getAttribute('data-ftv-temp') == '1');
	var decimals = parseInt(vEl.getAttribute('data-ftv-decimals'), 10);
	var n = isTemp ? parseFloat(value) : pct(value);
	var lvl = isTemp ? tempLevel(n) : level(n);

	vEl.textContent = fmtNum(n, isNaN(decimals) ? 1 : decimals);
	bEl.style.width = (n === null ? 0 : Math.min(100, Math.max(0, n))) + '%';

	var cardEl = vEl.parentNode.parentNode;

	if (cardEl) {
		cardEl.classList.remove('ftv-lv-low', 'ftv-lv-mid', 'ftv-lv-high', 'ftv-lv-idle');
		cardEl.classList.add(lvl);
	}

	if (fEl && foot) {
		fEl.innerHTML = '';
		fEl.appendChild(foot);
	}
}

/* ---------------------------------------------------------------- 状态条 */

function statusBar(st) {
	var on = (st.running === true);
	var cfg = (st.configured === true);
	var cls = (on && cfg) ? 'ftv-badge ftv-on' : 'ftv-badge ftv-off';
	var txt = on ? _('服务运行中') : (st.enabled ? _('服务未运行') : _('上报已禁用'));

	var items = [
		E('span', { 'class': cls }, [ E('span', { 'class': 'ftv-dot' }), txt ]),
		E('span', { 'class': 'ftv-meta' }, [ _('间隔'), ' ', E('b', {}, (st.interval || 100) + ' ms') ]),
		E('span', { 'class': 'ftv-meta' }, [ _('已上报'), ' ', E('b', {}, st.count || 0), ' ', _('次') ]),
		E('span', { 'class': 'ftv-meta' }, [ _('成功'), ' ', E('b', {}, st.ok || 0) ]),
		E('span', { 'class': 'ftv-meta' }, [ _('失败'), ' ', E('b', {}, st.fail || 0) ]),
		E('span', { 'class': 'ftv-meta' }, [ _('最近'), ' ', E('b', {}, fmtTime(st.last)) ])
	];

	if (st.error)
		items.push(E('span', { 'class': 'ftv-meta ftv-err' },
			[ _('错误'), ': ', E('b', {}, st.error) ]));

	if (cfg)
		items.push(E('span', { 'class': 'ftv-url' }, st.url || ''));

	return E('div', { 'class': 'ftv-status', 'id': 'ftv-status-bar' }, items);
}

function applyStatus(st) {
	var old = document.getElementById('ftv-status-bar');

	if (old && old.parentNode)
		old.parentNode.replaceChild(statusBar(st), old);

	updateCard('CPU', st.cpu);
	updateCard('RAM', st.ram);
	updateCard('TEMP', st.temp, tempFoot(st));
}

function tempFoot(st) {
	if (st.temp === null || st.temp === undefined)
		return E('span', {}, _('等待守护进程首拍上报'));

	return E('span', {}, _('读自 thermal zone，四舍五入取整'));
}

/* -------------------------------------------------------------------- 视图 */

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('fubotv'),
			callStatus().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var st = data[1] || {};
		var self = this;

		var m = new form.Map('fubotv', _('FuBoTv 监控上报'),
			_('将路由器的 CPU、内存占用率与 CPU 温度，以 HTTP POST 表单推送到 ESP8266 天气时钟显示。'));

		var s = m.section(form.TypedSection, 'fubotv', _('上报设置'),
			_('修改后点击「保存并应用」，procd 会自动重载上报服务。'));
		/* 单 section 固定为 fubotv 类型（与 /etc/config/fubotv 中的 config fubotv 'main' 对应），
		   不允许新增/删除，选项随 UCI 段渲染 */
		s.anonymous = false;
		s.addremove = false;

		var o;

		o = s.option(form.Flag, 'enabled', _('启用上报'),
			_('开启后由 procd 常驻守护进程，按间隔周期推送数据。'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'host', _('时钟地址'),
			_('天气时钟在局域网中的 IP 或主机名，例如 192.168.88.244。'));
		o.datatype = 'or(ip4addr,ip6addr,hostname)';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('HTTP 端口'),
			_('留空或填写 80 时，URL 中省略端口。'));
		o.datatype = 'port';
		o.placeholder = '80';
		o.rmempty = true;

		o = s.option(form.Value, 'interval', _('上报间隔（毫秒）'),
			_('范围 100-3600000。时钟屏幕刷新较慢或路由器负载敏感时，建议设为 1000-3000。'));
		o.datatype = 'and(uinteger,min(100),max(3600000))';
		o.default = '1000';
		o.rmempty = false;

		o = s.option(form.Value, 'path', _('上报路径'),
			_('时钟固件提供的接口路径，原版上位机固定为 /PCM。'));
		o.default = '/PCM';
		o.rmempty = false;

		o = s.option(form.Value, 'auth', _('认证串（表单首字段）'),
			_('作为表单主体首个字段发送。原版上位机使用 admin=root，留空则不附加。凭据错误时设备会直接断开连接。'));
	o.default = 'admin=root';
	o.rmempty = false;

		o = s.option(form.Value, 'param_cpu', _('CPU 参数名'),
			_('上报 CPU 占用率的表单参数名（POST 主体字段）。'));
		o.default = 'T1';
		o.rmempty = false;

		o = s.option(form.Value, 'param_ram', _('RAM 参数名'),
			_('上报内存占用率的表单参数名（POST 主体字段）。'));
		o.default = 'T2';
		o.rmempty = false;

		o = s.option(form.Value, 'param_temp', _('CPU 温度参数名'),
			_('上报 CPU 温度（°C，四舍五入取整）的表单参数名（POST 主体字段）。'));
		o.default = 'T3';
		o.rmempty = false;

		o = s.option(form.Button, '_test', _('连通性测试'),
			_('立即采样一次并向时钟 POST 单条上报，用于验证地址与协议是否正确。成功判定：HTTP 200 且响应含回执令牌 0637。'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callTest().then(function(r) {
				var detail = E('div', {}, [
					E('code', { 'style': 'word-break:break-all; display:block' },
						'POST ' + ((r && r.url) || '')),
					E('code', { 'style': 'word-break:break-all; display:block' },
						_('表单主体') + ': ' + ((r && r.body) || '')),
					E('code', { 'style': 'word-break:break-all; display:block' },
						_('响应') + ': HTTP ' + ((r && r.code) || 0) +
						(((r && r.resp) ? (' · ' + r.resp) : '')))
				]);

				if (r && r.ok)
					ui.addNotification(null, E('p', {}, [
						_('上报成功，时钟返回回执令牌'), E('br'), detail
					]), 'success');
				else
					ui.addNotification(null, E('p', {}, [
						_('上报失败：') + ((r && r.error) || _('未知错误')), E('br'), detail
					]), 'danger');
			});
		};

		var dash = E('div', { 'class': 'ftv-dash' }, [
			card('CPU', _('处理器'), st.cpu, [ E('span', {}, _('全部核心汇总')) ]),
			card('RAM', _('内存'), st.ram, [ E('span', {}, _('扣除可回收缓存')) ]),
			card('TEMP', _('CPU 温度'), st.temp, tempFoot(st), { temp: true, decimals: 0, unit: '°C' })
		]);

		var hint = E('p', { 'class': 'ftv-hint' }, [
			_('协议格式：'),
			E('code', {}, 'POST http://<时钟地址>/PCM  ·  表单主体: admin=root&T1=<CPU>&T2=<RAM>&T3=<温度>'),
			E('br'),
			_('设备仅接受 POST（GET 返回 404），凭据错误时直接断连；成功响应正文为令牌 0637。'),
			E('br'),
			_('CPU 为差值型指标，服务启动后第二拍开始才有有效数据；温度为瞬时采样，四舍五入取整后上报。')
		]);

		return m.render().then(function(node) {
			var wrap = E('div', {}, [
				E('link', {
					'rel': 'stylesheet',
					'href': L.resource('fubotv/dashboard.css')
				}),
				dash,
				statusBar(st),
				hint,
				node
			]);

			/* 节点尚未挂载，延后一拍再更新并启动轮询 */
			setTimeout(function() {
				applyStatus(st);

				if (refreshTimer)
					clearInterval(refreshTimer);

				refreshTimer = setInterval(function() {
					callStatus().then(function(s) {
						applyStatus(s || {});
					}).catch(function() {});
				}, 2000);
			}, 0);

			return wrap;
		});
	}
});
