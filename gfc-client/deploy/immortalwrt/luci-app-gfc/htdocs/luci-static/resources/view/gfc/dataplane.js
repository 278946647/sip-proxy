'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function request(path, body) {
	var args = [ '-qO-', '-T', '12' ];
	if (body !== undefined) {
		args.push('--header=Content-Type: application/json');
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return fs.exec('/usr/bin/wget', args).then(function(res) {
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
	return E('tr', {}, [
		E('td', { 'class': 'th' }, [ label ]),
		E('td', {}, [ val(value) ])
	]);
}

function actionButton(label, path, out) {
	var btn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ label ]);
	btn.addEventListener('click', function() {
		btn.disabled = true;
		out.textContent = 'running ' + label + '...';
		request(path, {}).then(function(res) {
			out.textContent = JSON.stringify((res || {}).data || res, null, 2);
			ui.addNotification(null, E('p', {}, label + ' 已执行'));
		}).catch(function(err) {
			out.textContent = err.message || String(err);
			ui.addNotification(null, E('p', {}, out.textContent), 'danger');
		}).finally(function() {
			btn.disabled = false;
		});
	});
	return btn;
}

return view.extend({
	load: function() {
		return Promise.all([
			request('/status'),
			request('/singbox/stats'),
			request('/dns/stats')
		]);
	},

	render: function(data) {
		var status = ((data[0] || {}).data || {});
		var singbox = ((data[1] || {}).data || {});
		var dns = ((data[2] || {}).data || {});
		var dataplane = status.dataplane || {};
		var tun = status.tun || {};
		var out = E('pre', { 'style': 'white-space: pre-wrap; max-height: 320px; overflow: auto' }, []);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 数据面' ]),
			E('table', { 'class': 'table' }, [
				stat('模式', dataplane.mode),
				stat('已激活', dataplane.activated),
				stat('TUN', tun.up ? 'up ' + val(tun.addrs) : val(tun.error || tun.up)),
				stat('Sing-box', singbox.ok ? 'ok' : val(singbox.error || singbox.controller)),
				stat('MosDNS', dns.ok ? 'ok' : val(dns.error)),
				stat('DNS 查询样本', dns.query_lines)
			]),
			E('div', { 'class': 'cbi-section' }, [
				actionButton('重载本地配置', '/dataplane/reload', out), ' ',
				actionButton('应用配置包', '/dataplane/apply', out), ' ',
				actionButton('回滚配置', '/dataplane/rollback', out)
			]),
			E('h3', {}, [ '操作结果' ]),
			out
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
