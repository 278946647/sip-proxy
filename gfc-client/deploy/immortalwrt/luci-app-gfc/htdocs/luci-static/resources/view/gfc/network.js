'use strict';
'require view';
'require fs';

var API = 'http://127.0.0.1:8080/api/v1';

function json(path) {
	return fs.exec('/usr/bin/wget', [ '-qO-', '-T', '8', API + path ]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	}).catch(function() {
		return {};
	});
}

function exec(cmd, args) {
	return fs.exec(cmd, args || []).then(function(res) {
		return res.stdout || '';
	}).catch(function(err) {
		return err.message || String(err);
	});
}

function val(v) {
	if (v === null || v === undefined || v === '')
		return '-';
	if (Array.isArray(v))
		return v.join(', ');
	if (typeof v === 'object')
		return JSON.stringify(v);
	return String(v);
}

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'class': 'th' }, [ label ]),
		E('td', {}, [ val(value) ])
	]);
}

function objectRows(obj) {
	return Object.keys(obj || {}).map(function(key) {
		return row(key, obj[key]);
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			json('/network'),
			json('/network/interfaces'),
			exec('/sbin/uci', [ 'show', 'network' ]),
			exec('/sbin/uci', [ 'show', 'dhcp' ])
		]);
	},

	render: function(data) {
		var network = ((data[0] || {}).data || {});
		var interfaces = (((data[1] || {}).data || {}).interfaces || network.interfaces || []);
		var bridge = network.bridge || {};
		var wan = network.wanConfig || {};
		var dhcp = network.dhcpConfig || {};
		var routes = (network.routes || {}).routes || [];
		var vlans = (network.vlan || {}).vlans || [];
		var uciNetwork = data[2] || '';
		var uciDhcp = data[3] || '';

		var routeRows = routes.map(function(route) {
			return E('tr', {}, [
				E('td', {}, [ val(route.interface || 'wan') ]),
				E('td', {}, [ val(route.target) ]),
				E('td', {}, [ val(route.netmask) ]),
				E('td', {}, [ val(route.gateway) ]),
				E('td', {}, [ val(route.metric) ])
			]);
		});
		if (!routeRows.length)
			routeRows.push(E('tr', {}, [ E('td', { 'colspan': 5 }, [ '暂无静态路由' ]) ]));

		var vlanRows = vlans.map(function(vlan) {
			return E('tr', {}, [
				E('td', {}, [ val(vlan.id || vlan.vlan) ]),
				E('td', {}, [ val(vlan.ports) ]),
				E('td', {}, [ val(vlan.description || vlan.name) ])
			]);
		});
		if (!vlanRows.length)
			vlanRows.push(E('tr', {}, [ E('td', { 'colspan': 3 }, [ '暂无 VLAN 配置' ]) ]));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 网络状态（只读）' ]),
			E('p', {}, [ '此页面仅展示 GFC 看到的网络配置。修改 WAN/LAN/DHCP/VLAN 请优先使用 LuCI 原生网络页面。' ]),

			E('h3', {}, [ '接口与角色' ]),
			E('table', { 'class': 'table' }, [
				row('接口列表', interfaces),
				row('WAN', network.wan || wan.interface),
				row('LAN', network.lan || bridge.bridgeName || network.lanAddress),
				row('LAN 地址', network.lanAddress),
				row('LAN 网段', network.lanNetwork)
			]),

			E('h3', {}, [ 'WAN' ]),
			E('table', { 'class': 'table' }, objectRows(wan)),

			E('h3', {}, [ 'Bridge/LAN' ]),
			E('table', { 'class': 'table' }, objectRows(bridge)),

			E('h3', {}, [ 'DHCP' ]),
			E('table', { 'class': 'table' }, objectRows(dhcp)),

			E('h3', {}, [ '静态路由' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '接口' ]),
					E('th', {}, [ '目标' ]),
					E('th', {}, [ '掩码' ]),
					E('th', {}, [ '网关' ]),
					E('th', {}, [ 'Metric' ])
				])
			].concat(routeRows)),

			E('h3', {}, [ 'VLAN' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ 'VLAN ID' ]),
					E('th', {}, [ '端口' ]),
					E('th', {}, [ '说明' ])
				])
			].concat(vlanRows)),

			E('h3', {}, [ 'UCI 摘要' ]),
			E('pre', { 'style': 'white-space: pre-wrap; max-height: 360px; overflow: auto' }, [
				uciNetwork.split('\n').filter(function(line) {
					return /network\.(lan|wan|gfc|@device|@interface)/.test(line);
				}).join('\n') + '\n\n' +
				uciDhcp.split('\n').filter(function(line) {
					return /dhcp\.(@dnsmasq|lan)/.test(line);
				}).join('\n')
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
