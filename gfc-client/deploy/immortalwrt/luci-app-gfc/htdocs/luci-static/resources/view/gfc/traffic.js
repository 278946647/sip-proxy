'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

var optionalRanges = [
	{ label: '6 小时', hours: 6 },
	{ label: '12 小时', hours: 12 },
	{ label: '24 小时', hours: 24 },
	{ label: '48 小时', hours: 48 }
];

function apiGet(path) {
	return fs.exec('/usr/bin/wget', [ '-qO-', '-T', '12', API + path ]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function showError(err) {
	ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
}

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
		return { max: 1, inbound: '', outbound: '' };
	var max = 1;
	samples.forEach(function(s) {
		max = Math.max(max, s.rate_in_bps || 0, s.rate_out_bps || 0);
	});
	var coords = samples.map(function(s, i) {
		var x = pad.left + (samples.length === 1 ? innerW / 2 : (i / (samples.length - 1)) * innerW);
		var yIn = pad.top + innerH - ((s.rate_in_bps || 0) / max) * innerH;
		var yOut = pad.top + innerH - ((s.rate_out_bps || 0) / max) * innerH;
		return { x: x, yIn: yIn, yOut: yOut };
	});
	return {
		max: max,
		inbound: coords.map(function(c) { return c.x + ',' + c.yIn; }).join(' '),
		outbound: coords.map(function(c) { return c.x + ',' + c.yOut; }).join(' ')
	};
}

function buildChartBlock(title, history) {
	var samples = history.samples || [];
	var summary = history.summary || {};
	var w = 920;
	var h = 220;
	var pad = { top: 16, right: 16, bottom: 28, left: 56 };
	var chart = chartPoints(samples, w, h, pad);
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
	return E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:16px' }, [
		E('h3', { 'style': 'margin:0 0 8px 0;font-size:15px' }, [ title ]),
		E('div', { 'style': 'display:flex;gap:16px;flex-wrap:wrap;font-size:13px;color:#475569;margin-bottom:8px' }, [
			E('span', {}, [ '总入站 ' + formatBytes(summary.total_in) ]),
			E('span', {}, [ '总出站 ' + formatBytes(summary.total_out) ]),
			E('span', {}, [ '峰值入站 ' + formatBps(summary.peak_in_bps) ]),
			E('span', {}, [ '峰值出站 ' + formatBps(summary.peak_out_bps) ])
		]),
		svg,
		E('div', { 'class': 'hint', 'style': 'margin-top:6px' }, [
			samples.length
				? ('共 ' + samples.length + ' 个采样点')
				: '暂无该时段数据，运行约 1 分钟后出现首个采样点'
		])
	]);
}

return view.extend({
	iface: 'gfctun',
	enabled: { 6: false, 12: false, 24: false, 48: false },
	history: { 1: null },
	root: null,
	chartsHost: null,

	loadHistory: function(hours) {
		return apiGet('/network/traffic/history?hours=' + hours + '&iface=' + encodeURIComponent(this.iface));
	},

	loadAll: function() {
		var self = this;
		var tasks = [
			apiGet('/network/traffic/interfaces'),
			self.loadHistory(1)
		];
		optionalRanges.forEach(function(item) {
			if (self.enabled[item.hours])
				tasks.push(self.loadHistory(item.hours));
		});
		return Promise.all(tasks).then(function(results) {
			var ifaceResp = ((results[0] || {}).data || {});
			var ifaces = ifaceResp.interfaces || [ 'gfctun' ];
			if (ifaces.indexOf(self.iface) < 0)
				self.iface = ifaceResp.default || ifaces[0] || 'gfctun';
			self.history[1] = (results[1] || {}).data || {};
			var idx = 2;
			optionalRanges.forEach(function(item) {
				if (self.enabled[item.hours]) {
					self.history[item.hours] = (results[idx] || {}).data || {};
					idx++;
				} else {
					self.history[item.hours] = null;
				}
			});
			return { ifaces: ifaces };
		});
	},

	load: function() {
		return this.loadAll();
	},

	renderCharts: function() {
		var self = this;
		var blocks = [ buildChartBlock('最近 1 小时（默认）', self.history[1] || {}) ];
		optionalRanges.forEach(function(item) {
			if (self.enabled[item.hours] && self.history[item.hours])
				blocks.push(buildChartBlock('最近 ' + item.label, self.history[item.hours]));
		});
		return blocks;
	},

	render: function(data) {
		var self = this;
		var ifaces = (data || {}).ifaces || [ 'gfctun' ];

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

		var checkboxes = optionalRanges.map(function(item) {
			var input = E('input', { 'type': 'checkbox' });
			input.checked = !!self.enabled[item.hours];
			input.addEventListener('change', function() {
				self.enabled[item.hours] = input.checked;
				if (input.checked) {
					self.loadHistory(item.hours).then(function(res) {
						self.history[item.hours] = (res || {}).data || {};
						self.refreshCharts();
					}).catch(showError);
				} else {
					self.history[item.hours] = null;
					self.refreshCharts();
				}
			});
			return E('label', { 'style': 'display:inline-flex;align-items:center;gap:6px;margin-right:14px' }, [
				input,
				item.label
			]);
		});

		var refreshBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ '刷新' ]);
		refreshBtn.addEventListener('click', function() {
			self.reload();
		});

		var chartsHost = E('div', { 'class': 'gfc-traffic-charts' }, self.renderCharts());

		var root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '接口流量历史' ]),
			E('p', { 'class': 'hint' }, [ '默认显示最近 1 小时；勾选其他时段后按需加载对应图表。数据每分钟采样，本地保留 48 小时。' ]),
			E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin:12px 0;align-items:center' }, [
				E('span', { 'style': 'font-weight:600;margin-right:4px' }, [ '接口' ])
			].concat(ifaceBtns).concat([ refreshBtn ])),
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:12px' }, [
				E('div', { 'style': 'font-weight:600;margin-bottom:8px' }, [ '附加时段' ]),
				E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;align-items:center' }, checkboxes)
			]),
			chartsHost,
			E('div', { 'style': 'display:flex;gap:16px;font-size:13px;margin-top:4px' }, [
				E('span', { 'style': 'color:#2563eb' }, [ '入站' ]),
				E('span', { 'style': 'color:#16a34a' }, [ '出站' ])
			])
		]);

		self.root = root;
		self.chartsHost = chartsHost;
		return root;
	},

	refreshCharts: function() {
		if (!this.chartsHost)
			return;
		var next = E('div', { 'class': 'gfc-traffic-charts' }, this.renderCharts());
		this.chartsHost.parentNode.replaceChild(next, this.chartsHost);
		this.chartsHost = next;
	},

	reload: function() {
		var self = this;
		return self.loadAll().then(function(data) {
			if (!self.root || !self.root.parentNode)
				return;
			var next = self.render(data);
			self.root.parentNode.replaceChild(next, self.root);
		}).catch(showError);
	},

	poll: function() {
		return this.reload();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
