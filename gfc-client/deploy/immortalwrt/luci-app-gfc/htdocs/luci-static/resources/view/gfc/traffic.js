'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

var timeRanges = [
	{ label: '1 小时', hours: 1 },
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
		return (v / 1000).toFixed(2) + ' Kibit/s';
	return (v / 1000 / 1000).toFixed(2) + ' Mbit/s';
}

function formatBpsWithBytes(v) {
	v = Number(v) || 0;
	var bps = formatBps(v);
	var Bps = v / 8;
	var bytes;
	if (Bps < 1024)
		bytes = Math.round(Bps) + ' B/s';
	else if (Bps < 1024 * 1024)
		bytes = (Bps / 1024).toFixed(2) + ' KiB/s';
	else
		bytes = (Bps / 1024 / 1024).toFixed(2) + ' MiB/s';
	return bps + ' (' + bytes + ')';
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

function niceMax(v) {
	if (v <= 0)
		return 1000;
	var exp = Math.pow(10, Math.floor(Math.log10(v)));
	var f = v / exp;
	var nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10;
	return nice * exp;
}

function drawBandwidthChart(canvas, samples, hours) {
	var parent = canvas.parentNode;
	var w = parent && parent.clientWidth ? Math.max(parent.clientWidth, 320) : 900;
	var h = 280;
	var dpr = window.devicePixelRatio || 1;
	canvas.width = Math.floor(w * dpr);
	canvas.height = Math.floor(h * dpr);
	canvas.style.width = w + 'px';
	canvas.style.height = h + 'px';

	var ctx = canvas.getContext('2d');
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	ctx.clearRect(0, 0, w, h);
	ctx.fillStyle = '#ffffff';
	ctx.fillRect(0, 0, w, h);

	var pad = { top: 22, right: 18, bottom: 40, left: 78 };
	var innerW = w - pad.left - pad.right;
	var innerH = h - pad.top - pad.bottom;
	var baseY = pad.top + innerH;

	if (!samples.length) {
		ctx.fillStyle = '#64748b';
		ctx.font = '13px sans-serif';
		ctx.fillText('暂无数据', pad.left, pad.top + 36);
		return;
	}

	var max = 1;
	samples.forEach(function(s) {
		max = Math.max(max, s.rate_in_bps || 0, s.rate_out_bps || 0);
	});
	max = niceMax(max);

	var gridLines = 4;
	ctx.strokeStyle = '#e8e8e8';
	ctx.fillStyle = '#666666';
	ctx.font = '11px sans-serif';
	for (var g = 0; g <= gridLines; g++) {
		var y = pad.top + (innerH / gridLines) * g;
		var val = max * (1 - g / gridLines);
		ctx.beginPath();
		ctx.moveTo(pad.left, y);
		ctx.lineTo(w - pad.right, y);
		ctx.stroke();
		ctx.fillText(formatBps(val), 6, y + 4);
	}

	function xAt(i) {
		if (samples.length === 1)
			return pad.left + innerW / 2;
		return pad.left + (i / (samples.length - 1)) * innerW;
	}

	function yAt(v) {
		return pad.top + innerH - ((v || 0) / max) * innerH;
	}

	function fillArea(color, key) {
		ctx.beginPath();
		ctx.moveTo(xAt(0), baseY);
		for (var i = 0; i < samples.length; i++)
			ctx.lineTo(xAt(i), yAt(samples[i][key]));
		ctx.lineTo(xAt(samples.length - 1), baseY);
		ctx.closePath();
		ctx.fillStyle = color;
		ctx.fill();
	}

	function strokeLine(color, key, width) {
		ctx.beginPath();
		for (var j = 0; j < samples.length; j++) {
			var x = xAt(j), y = yAt(samples[j][key]);
			if (j === 0)
				ctx.moveTo(x, y);
			else
				ctx.lineTo(x, y);
		}
		ctx.strokeStyle = color;
		ctx.lineWidth = width;
		ctx.stroke();
	}

	fillArea('rgba(0, 84, 166, 0.22)', 'rate_in_bps');
	strokeLine('#0054a6', 'rate_in_bps', 1.5);
	fillArea('rgba(0, 177, 33, 0.30)', 'rate_out_bps');
	strokeLine('#00b121', 'rate_out_bps', 1.5);

	ctx.fillStyle = '#666666';
	ctx.font = '11px sans-serif';
	var marks = [ 0, 0.25, 0.5, 0.75, 1 ];
	marks.forEach(function(p) {
		var idx = Math.round(p * (samples.length - 1));
		var label;
		if (p === 1)
			label = '现在';
		else if (hours >= 24)
			label = Math.round(hours * (1 - p)) + 'h前';
		else if (hours >= 6)
			label = Math.round(hours * 60 * (1 - p)) + 'm前';
		else
			label = Math.round(hours * 60 * (1 - p)) + 'm前';
		var tx = xAt(idx);
		ctx.fillText(label, Math.max(4, tx - 16), h - 12);
	});
}

function buildStatsTable(samples, summary) {
	var last = samples.length ? samples[samples.length - 1] : null;
	var avgIn = 0, avgOut = 0;
	if (samples.length) {
		samples.forEach(function(s) {
			avgIn += s.rate_in_bps || 0;
			avgOut += s.rate_out_bps || 0;
		});
		avgIn /= samples.length;
		avgOut /= samples.length;
	}
	var peakIn = summary.peak_in_bps || 0;
	var peakOut = summary.peak_out_bps || 0;
	return E('table', { 'class': 'table', 'style': 'margin-top:12px' }, [
		E('tr', {}, [
			E('th', {}, [ '' ]),
			E('th', {}, [ '当前' ]),
			E('th', {}, [ '平均' ]),
			E('th', {}, [ '峰值' ])
		]),
		E('tr', {}, [
			E('td', {}, [ E('span', { 'style': 'color:#0054a6;font-weight:600' }, [ '入站' ]) ]),
			E('td', {}, [ last ? formatBpsWithBytes(last.rate_in_bps) : '-' ]),
			E('td', {}, [ formatBpsWithBytes(avgIn) ]),
			E('td', {}, [ formatBpsWithBytes(peakIn) ])
		]),
		E('tr', {}, [
			E('td', {}, [ E('span', { 'style': 'color:#00b121;font-weight:600' }, [ '出站' ]) ]),
			E('td', {}, [ last ? formatBpsWithBytes(last.rate_out_bps) : '-' ]),
			E('td', {}, [ formatBpsWithBytes(avgOut) ]),
			E('td', {}, [ formatBpsWithBytes(peakOut) ])
		])
	]);
}

function makeTabMenu(items, activeValue, onPick) {
	var menu = E('ul', { 'class': 'cbi-tabmenu' });
	items.forEach(function(item) {
		var value = item.value;
		var a = E('a', { 'href': '#' }, [ item.label ]);
		a.addEventListener('click', function(ev) {
			ev.preventDefault();
			onPick(value, menu);
		});
		menu.appendChild(E('li', {
			'class': 'cbi-tab' + (activeValue === value ? ' cbi-tab-disabled' : '')
		}, [ a ]));
	});
	return menu;
}

function setActiveTab(menu, activeValue, items) {
	var links = menu.querySelectorAll('li');
	for (var i = 0; i < links.length; i++) {
		var value = items[i].value;
		links[i].className = activeValue === value ? 'cbi-tab cbi-tab-disabled' : 'cbi-tab';
	}
}

return view.extend({
	hours: 1,
	iface: 'gfctun',

	load: function() {
		var self = this;
		return Promise.all([
			apiGet('/network/traffic/interfaces'),
			apiGet('/network/traffic/history?hours=' + self.hours + '&iface=' + encodeURIComponent(self.iface))
		]);
	},

	render: function(data) {
		var self = this;
		var ifaceResp = ((data[0] || {}).data || {});
		var ifaces = ifaceResp.interfaces || [ 'gfctun' ];
		if (ifaces.indexOf(self.iface) < 0)
			self.iface = ifaceResp.default || ifaces[0] || 'gfctun';
		var history = ((data[1] || {}).data || {});
		var samples = history.samples || [];
		var summary = history.summary || {};

		var canvas = E('canvas', {
			'style': 'width:100%;height:280px;display:block;background:#fff;border:1px solid #e0e0e0;border-radius:2px'
		});
		var chartWrap = E('div', { 'class': 'gfc-traffic-chart-wrap' }, [ canvas ]);
		var statsHost = E('div', { 'class': 'gfc-traffic-stats' });
		var hintEl = E('div', { 'class': 'hint', 'style': 'margin-top:8px' });
		var totalsEl = E('div', {
			'style': 'display:flex;gap:18px;flex-wrap:wrap;font-size:13px;color:#475569;margin:8px 0'
		});

		function paint(historyData) {
			var s = historyData.samples || [];
			var sum = historyData.summary || {};
			setTimeout(function() {
				drawBandwidthChart(canvas, s, self.hours);
			}, 0);
			statsHost.innerHTML = '';
			statsHost.appendChild(buildStatsTable(s, sum));
			totalsEl.innerHTML = '';
			totalsEl.appendChild(E('span', {}, [ '总入站 ' + formatBytes(sum.total_in) ]));
			totalsEl.appendChild(E('span', {}, [ '总出站 ' + formatBytes(sum.total_out) ]));
			hintEl.textContent = s.length
				? ('最近 ' + self.hours + ' 小时 · 共 ' + s.length + ' 个采样点 · 每分钟刷新 · 本地保留 48 小时')
				: '暂无历史数据，运行约 1 分钟后出现首个采样点';
		}

		paint(history);

		function fetchHistory() {
			return apiGet('/network/traffic/history?hours=' + self.hours + '&iface=' + encodeURIComponent(self.iface))
				.then(function(res) {
					paint((res || {}).data || {});
				});
		}

		self.fetchHistory = fetchHistory;

		var ifaceItems = ifaces.map(function(name) {
			return { label: name, value: name };
		});
		var ifaceMenu = makeTabMenu(ifaceItems, self.iface, function(name, menu) {
			if (self.iface === name)
				return;
			self.iface = name;
			setActiveTab(menu, name, ifaceItems);
			fetchHistory().catch(showError);
		});

		var rangeItems = timeRanges.map(function(item) {
			return { label: item.label, value: item.hours };
		});
		var rangeMenu = makeTabMenu(rangeItems, self.hours, function(hours, menu) {
			if (self.hours === hours)
				return;
			self.hours = hours;
			setActiveTab(menu, hours, rangeItems);
			fetchHistory().catch(showError);
		});

		var refreshBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'style': 'margin-left:8px'
		}, [ '刷新' ]);
		refreshBtn.addEventListener('click', function() {
			fetchHistory().catch(showError);
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '接口流量历史' ]),
			E('p', { 'class': 'hint' }, [ '样式对齐系统带宽图：蓝色入站、绿色出站。点击接口或时段标签切换视图。' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:8px' }, [
					ifaceMenu,
					refreshBtn
				])
			]),
			E('div', { 'class': 'cbi-section', 'style': 'margin-top:8px' }, [
				rangeMenu
			]),
			totalsEl,
			chartWrap,
			statsHost,
			hintEl
		]);
	},

	poll: function() {
		if (typeof this.fetchHistory === 'function')
			return this.fetchHistory();
		return Promise.resolve();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
