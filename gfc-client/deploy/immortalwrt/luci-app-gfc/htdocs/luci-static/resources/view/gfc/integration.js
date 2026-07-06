'use strict';
'require view';
'require fs';

var API = 'http://127.0.0.1:8080/api/v1';

function api(path) {
	return fs.exec('/usr/bin/wget', [ '-qO-', '-T', '8', API + path ]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	}).catch(function(err) {
		return { ok: false, error: err.message || String(err) };
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

function verdict(ok, text) {
	return E('span', {
		'style': 'color:' + (ok ? '#2e7d32' : '#c62828')
	}, [ ok ? '通过' : (text || '待处理') ]);
}

function row(name, ok, detail) {
	return E('tr', {}, [
		E('td', {}, [ name ]),
		E('td', {}, [ verdict(ok) ]),
		E('td', {}, [ val(detail) ])
	]);
}

function section(title, body) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ title ]),
		body
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			api('/status'),
			api('/activation'),
			api('/nodes'),
			api('/services'),
			api('/singbox/stats'),
			api('/dns/stats'),
			exec('/sbin/ip', [ 'rule' ]),
			exec('/sbin/ip', [ 'route', 'show', 'table', '2022' ]),
			exec('/usr/sbin/nft', [ 'list', 'tables' ]),
			exec('/bin/netstat', [ '-lntup' ])
		]);
	},

	render: function(data) {
		var status = ((data[0] || {}).data || {});
		var activation = ((data[1] || {}).data || {});
		var nodes = (((data[2] || {}).data || {}).nodes || []);
		var services = (((data[3] || {}).data || {}).services || {});
		var singbox = ((data[4] || {}).data || {});
		var dnsStats = ((data[5] || {}).data || {});
		var ipRule = data[6] || '';
		var route2022 = data[7] || '';
		var nftTables = data[8] || '';
		var netstat = data[9] || '';
		var tun = status.tun || {};
		var dataplane = status.dataplane || {};
		var agent = status.agent || {};
		var serviceOk = services['agent'] && services['web'] &&
			services['agent'].active === 'active' &&
			services['web'].active === 'active';
		var routingReady = /2022/.test(ipRule) || /gfctun/.test(route2022);
		var nftReady = /gfc/.test(nftTables);
		var unboundReady = /:53/.test(netstat) && !/1053/.test(netstat);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '激活验收清单' ]),
			E('p', { 'class': 'hint' }, [ '激活后只读检查：服务、Unbound、nft、策略路由、TUN、节点下发。' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '检查项' ]),
					E('th', {}, [ '结果' ]),
					E('th', {}, [ '详情' ])
				]),
				row('API/Agent 服务', serviceOk, 'agent=' + val((services.agent || {}).active) + ', web=' + val((services.web || {}).active)),
				row('设备激活', status.state === 'active' || activation.code_present, status.state + ', token=' + val(agent.applied_version || activation.code_present)),
				row('节点下发', nodes.length > 0, nodes.length + ' nodes'),
				row('数据面模式', dataplane.mode === 'active', dataplane),
				row('TUN gfctun', tun.up === true, tun.error || tun.addrs),
				row('Sing-box 控制器', singbox.ok === true, singbox.error || singbox.controller),
				row('Unbound :53', unboundReady, 'dns queries=' + val(dnsStats.query_lines)),
				row('策略路由', routingReady, route2022 || ipRule),
				row('nft 规则', nftReady, nftTables)
			]),
			section('ip rule', E('pre', { 'style': 'white-space: pre-wrap; max-height: 180px; overflow: auto' }, [ ipRule ])),
			section('route table 2022', E('pre', { 'style': 'white-space: pre-wrap; max-height: 180px; overflow: auto' }, [ route2022 ])),
			section('nft tables', E('pre', { 'style': 'white-space: pre-wrap; max-height: 180px; overflow: auto' }, [ nftTables ]))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
