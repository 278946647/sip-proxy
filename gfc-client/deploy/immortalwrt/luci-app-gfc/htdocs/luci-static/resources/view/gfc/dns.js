'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function exec(cmd, args) {
	return fs.exec(cmd, args || []).then(function(res) {
		return res.stdout || '';
	}).catch(function(err) {
		return err.message || String(err);
	});
}

function json(path) {
	return fs.exec('/usr/bin/wget', [ '-qO-', '-T', '5', API + path ]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	}).catch(function() {
		return {};
	});
}

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'class': 'th' }, [ label ]),
		E('td', {}, [ value || '-' ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			json('/status'),
			exec('/sbin/uci', [ 'show', 'dhcp' ]),
			exec('/bin/netstat', [ '-lnup' ]),
			exec('/bin/netstat', [ '-lntup' ])
		]);
	},

	render: function(data) {
		var status = (data[0] || {}).data || {};
		var dns = status.dns || {};
		var uci = data[1] || '';
		var udp = data[2] || '';
		var tcp = data[3] || '';
		var dnsmasqForward = /127\.0\.0\.1#1053/.test(uci);
		var mosdnsUdp = /1053/.test(udp);
		var mosdnsTcp = /1053/.test(tcp);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC DNS 状态' ]),
			E('table', { 'class': 'table' }, [
				row('GFC DNS 探测', dns.ok ? 'ok ' + dns.addr : (dns.error || 'failed')),
				row('dnsmasq 转发到 mosdns', dnsmasqForward ? '已配置 127.0.0.1#1053' : '未配置'),
				row('mosdns UDP 1053', mosdnsUdp ? '监听中' : '未监听'),
				row('mosdns TCP 1053', mosdnsTcp ? '监听中' : '未监听')
			]),
			E('h3', {}, [ 'UCI DHCP/DNS 配置' ]),
			E('pre', { 'style': 'white-space: pre-wrap; max-height: 260px; overflow: auto' }, [
				uci.split('\n').filter(function(line) {
					return /noresolv|server|cachesize|dhcpv4|ra/.test(line);
				}).join('\n')
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
