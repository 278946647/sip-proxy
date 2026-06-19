'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function call(path) {
	return fs.exec('/usr/bin/wget', [ '-qO-', '-T', '5', API + path ]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function val(v) {
	if (v === null || v === undefined || v === '')
		return '-';
	if (typeof v === 'object')
		return JSON.stringify(v);
	return String(v);
}

function stat(label, value) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, [ label ]),
		E('div', { 'class': 'cbi-value-field' }, [ val(value) ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ call('/status'), call('/health') ]);
	},

	render: function(data) {
		var status = (data[0] || {}).data || {};
		var health = ((data[1] || {}).data || {});
		var agent = status.agent || {};
		var tun = status.tun || {};
		var dns = status.dns || {};
		var network = status.network || {};

		var serviceRows = Object.keys(health).map(function(name) {
			var item = health[name] || {};
			return E('tr', {}, [
				E('td', {}, [ name ]),
				E('td', {}, [ val(item.active) ]),
				E('td', {}, [ val(item.sub) ]),
				E('td', {}, [ val(item.unit) ])
			]);
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 客户端概览' ]),
			E('div', { 'class': 'cbi-section' }, [
				stat('设备状态', status.state),
				stat('Agent 状态', agent.agent_state),
				stat('控制面可达', agent.cp_reachable),
				stat('数据面模式', (status.dataplane || {}).mode),
				stat('DNS', dns.ok ? 'ok ' + dns.addr : val(dns.error)),
				stat('TUN', tun.up ? 'up' : val(tun.error || tun.up)),
				stat('WAN', network.wan || ((network.wanConfig || {}).interface)),
				stat('LAN', network.lan || network.lanAddress)
			]),
			E('h3', {}, [ '服务健康' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '服务' ]),
					E('th', {}, [ '状态' ]),
					E('th', {}, [ '子状态' ]),
					E('th', {}, [ 'Unit' ])
				])
			].concat(serviceRows))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
