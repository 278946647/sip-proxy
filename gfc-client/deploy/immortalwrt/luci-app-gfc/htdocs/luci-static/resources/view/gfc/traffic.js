'use strict';
'require view';
'require ui';

var api = L.require('view.gfc.api');

var ranges = [
	{ label: '1 小时', hours: 1 },
	{ label: '6 小时', hours: 6 },
	{ label: '12 小时', hours: 12 },
	{ label: '24 小时', hours: 24 },
	{ label: '48 小时', hours: 48 }
];

function formatBps(v) {
	v = Number(v) || 0;
	if (v < 1000)
		return Math.round(v) + ' bit/s';
	if (v < 1000 * 1000)
		return (v / 1000).toFixed(1) + ' Kibit/s';
	return (v / 1000 / 1000).toFixed(2) + ' Mbit/s';
}

function formatBytes(n) {
	n = Number(n) || 0;
	if (n < 1024)
		return n + ' B';
	if (n < 1024 * 1024)
		return (n / 1024).toFixed(1) + ' KB';
	if (n < 1024 * 1024 * 1024)
		return (n / 1024 / 1024).toFixed(1) + ' MB';
	return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}

function chartPoints(samples, w, h, pad) {
	var innerW = w - pad.left - pad.right;
	var innerH = h - pad.top - pad.bottom;
	if (!samples.length)
		return { max: 1, inbound: '', outbound: '', coords: [] };
	var max = 1;
	samples.forEach(function(s) {
		max = Math.max(max, s.rate_in_bps || 0, s.rate_out_bps || 0);
	});
	var coords = samples.map(function(s, i) {
		var x = pad.left + (samples.length === 1 ? innerW / 2 : (i / (samples.length - 1)) * innerW);
		var yIn = pad.top + innerH - ((s.rate_in_bps || 0) / max) * innerH;
		var yOut = pad.top + innerH - ((s.rate_out_bps || 0) / max) * innerH;
		return { x: x, yIn: yIn, yOut: yOut, s: s };
	});
	return {
		max: max,
		inbound: coords.map(function(c) { return c.x + ',' + c.yIn; }).join(' '),
		outbound: coords.map(function(c) { return c.x + ',' + c.yOut; }).join(' '),
		coords: coords
	};
}

return view.extend({
	hours: 24,
	iface: 'gfctun',
	root: null,

	load: function() {
		var self = this;
		return Promise.all([
			api.get('/network/traffic/interfaces'),
			api.get('/network/traffic/history?hours=' + self.hours + '&iface=' + encodeURIComponent(self.iface))
		]);
	},

	render: function(data) {
		var self = this;
		var ifaceResp = ((data[0] || {}).data || {});
		var history = ((data[1] || {}).data || {});
		var ifaces = ifaceResp.interfaces || [ 'gfctun' ];
		if (ifaces.indexOf(self.iface) < 0)
			self.iface = ifaceResp.default || ifaces[0] || 'gfctun';
		var samples = history.samples || [];
		var summary = history.summary || {};
		var w = 920;
		var h = 260;
		var pad = { top: 18, right: 16, bottom: 32, left: 58 };
		var chart = chartPoints(samples, w, h, pad);

		var rangeBtns = ranges.map(function(item) {
			var btn = E('button', {
				'class': 'btn cbi-button' + (self.hours === item.hours ? ' cbi-button-positive' : '')
			}, [ item.label ]);
			btn.addEventListener('click', function() {
				self.hours = item.hours;
				self.reload();
			});
			return btn;
		});

		var ifaceBtns = ifaces.map(function(name) {
			var btn = E('button', {
				'class': 'btn cbi-button' + (self.iface === name ? ' cbi-button-positive' : '')
			}, [ name ]);
			btn.addEventListener('click', function() {
				self.iface = name;
				self.reload();
			});
			return btn;
		});

		var refreshBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ '刷新' ]);
		refreshBtn.addEventListener('click', function() {
			self.reload();
		});

		var svg = E('svg', {
			'viewBox': '0 0 ' + w + ' ' + h,
			'width': '100%',
			'height': String(h),
			'style': 'max-width:100%;background:#fafafa;border-radius:8px'
		}, [
			E('line', {
				'x1': pad.left,
				'x2': w - pad.right,
				'y1': pad.top + (h - pad.top - pad.bottom),
				'y2': pad.top + (h - pad.top - pad.bottom),
				'stroke': '#cbd5e1'
			}),
			E('polyline', { 'fill': 'none', 'stroke': '#3b82f6', 'stroke-width': '2', 'points': chart.inbound }),
			E('polyline', { 'fill': 'none', 'stroke': '#22c55e', 'stroke-width': '2', 'points': chart.outbound })
		]);

		var tooltip = E('div', { 'class': 'hint', 'style': 'margin-top:8px;min-height:18px' }, [
			samples.length ? ('共 ' + samples.length + ' 个采样点，每 1 分钟一个，本地保留 48 小时') : '暂无历史数据，运行约 1 分钟后出现首个采样点'
		]);

		var root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '接口流量历史' ]),
			E('p', { 'class': 'hint' }, [ '与 ImmortalWrt 实时带宽图互补：本地 SQLite 保存分钟级历史，支持多接口切换。' ]),
			E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin:12px 0' }, rangeBtns),
			E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin:0 0 12px 0;align-items:center' }, [
				E('span', { 'style': 'font-weight:600;margin-right:4px' }, [ '接口' ])
			].concat(ifaceBtns).concat([ refreshBtn ])),
			E('div', { 'class': 'cbi-section', 'style': 'display:flex;gap:18px;flex-wrap:wrap;font-size:13px;color:#475569' }, [
				E('span', {}, [ '总入站 ' + formatBytes(summary.total_in) ]),
				E('span', {}, [ '总出站 ' + formatBytes(summary.total_out) ]),
				E('span', {}, [ '峰值入站 ' + formatBps(summary.peak_in_bps) ]),
				E('span', {}, [ '峰值出站 ' + formatBps(summary.peak_out_bps) ])
			]),
			E('div', { 'class': 'cbi-section' }, [ svg ]),
			E('div', { 'style': 'display:flex;gap:16px;font-size:13px;margin-top:8px' }, [
				E('span', { 'style': 'color:#2563eb' }, [ '入站' ]),
				E('span', { 'style': 'color:#16a34a' }, [ '出站' ])
			]),
			tooltip
		]);

		self.root = root;
		return root;
	},

	reload: function() {
		var self = this;
		return self.load().then(function(data) {
			if (!self.root || !self.root.parentNode)
				return;
			var next = self.render(data);
			self.root.parentNode.replaceChild(next, self.root);
		}).catch(function(err) {
			api.showError(err);
		});
	},

	poll: function() {
		return this.reload();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
