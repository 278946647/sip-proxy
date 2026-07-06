'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function call(path) {
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

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'class': 'th' }, [ label ]),
		E('td', {}, [ val(value) ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			call('/status'),
			call('/health'),
			call('/network'),
			call('/network/interfaces'),
			exec('/sbin/ip', [ '-4', 'addr', 'show', 'dev', 'gfctun' ]),
			exec('/sbin/ip', [ '-4', 'link', 'show', 'gfctun' ])
		]);
	},

	render: function(data) {
		var status = (data[0] || {}).data || {};
		var health = ((data[1] || {}).data || {});
		var network = ((data[2] || {}).data || {});
		var ifaces = (((data[3] || {}).data || {}).interfaces || []);
		var tunAddr = data[4] || '';
		var tunLink = data[5] || '';
		var agent = status.agent || {};
		var tun = status.tun || {};
		var dns = status.dns || {};

		var serviceRows = Object.keys(health).map(function(name) {
			var item = health[name] || {};
			return E('tr', {}, [
				E('td', {}, [ name ]),
				E('td', {}, [ val(item.active) ]),
				E('td', {}, [ val(item.sub) ])
			]);
		});

		var ifaceRows = ifaces.map(function(item) {
			return E('tr', {}, [
				E('td', {}, [ val(item.name) ]),
				E('td', {}, [ val(item.address || item.ipv4) ]),
				E('td', {}, [ val(item.state || item.up) ])
			]);
		});
		if (!ifaceRows.length) {
			ifaceRows.push(E('tr', {}, [ E('td', { 'colspan': 3 }, [ '暂无接口数据' ]) ]));
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '运行总览' ]),
			E('p', { 'class': 'hint' }, [ '设备与控制面、数据面核心状态。网络细节与 gfctun 见下方折叠面板。' ]),
			E('div', { 'class': 'cbi-section' }, [
				stat('激活状态', status.state),
				stat('Agent', agent.agent_state || agent.status),
				stat('控制面', agent.cp_reachable),
				stat('数据面', (status.dataplane || {}).mode),
				stat('Unbound DNS', dns.ok ? '正常' : val(dns.error)),
				stat('TUN gfctun', tun.up ? 'UP' : val(tun.error || 'DOWN')),
				stat('WAN', network.wan || ((network.wanConfig || {}).interface)),
				stat('LAN', network.lan || network.lanAddress)
			]),
			E('h3', {}, [ '服务健康' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '服务' ]),
					E('th', {}, [ '状态' ]),
					E('th', {}, [ '子状态' ])
				])
			].concat(serviceRows)),
			E('details', { 'style': 'margin-top:14px' }, [
				E('summary', { 'style': 'cursor:pointer;font-weight:600;padding:8px 0' }, [ '网络与 gfctun 接口（只读）' ]),
				E('div', { 'class': 'cbi-section' }, [
					E('p', { 'class': 'hint' }, [ 'WAN/LAN 修改请使用 OpenWrt「网络」菜单；此处展示 GFC 视角与 TUN 状态。' ]),
					E('table', { 'class': 'table' }, [
						row('gfctun 链路', tunLink.split('\n')[0] || '-'),
						row('gfctun 地址', tunAddr.trim() || val(tun.addrs)),
						row('策略路由表', '2022 → gfctun')
					]),
					E('h4', {}, [ '接口列表' ]),
					E('table', { 'class': 'table' }, [
						E('tr', {}, [
							E('th', {}, [ '接口' ]),
							E('th', {}, [ '地址' ]),
							E('th', {}, [ '状态' ])
						])
					].concat(ifaceRows))
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
