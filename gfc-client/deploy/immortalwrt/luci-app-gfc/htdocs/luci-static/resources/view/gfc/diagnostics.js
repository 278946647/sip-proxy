'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function post(path, body) {
	return fs.exec('/usr/bin/wget', [
		'-qO-', '-T', '25',
		'--header=Content-Type: application/json',
		'--post-data=' + JSON.stringify(body || {}),
		API + path
	]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function run(kind, host, out) {
	out.textContent = '检测中...';
	return post('/diagnostics/' + kind, { host: host }).then(function(res) {
		var data = (res || {}).data || res || {};
		if (kind === 'vless' && data.conclusion) {
			var head = (data.ok ? '【通过】' : '【未通过】') + ' ' + data.conclusion;
			out.textContent = head + '\n\n' + JSON.stringify(data, null, 2);
			return;
		}
		out.textContent = JSON.stringify(data, null, 2);
	}).catch(function(err) {
		out.textContent = err.message || String(err);
		ui.addNotification(null, E('p', {}, out.textContent), 'danger');
	});
}

return view.extend({
	render: function() {
		var dnsHost = E('input', { 'class': 'cbi-input-text', 'value': 'www.google.com' });
		var pingHost = E('input', { 'class': 'cbi-input-text', 'value': '1.1.1.1' });
		var output = E('pre', {
			'style': 'white-space: pre-wrap; max-height: 520px; overflow: auto'
		}, [ '选择检测项查看结果。' ]);

		var dnsBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ 'DNS 解析' ]);
		dnsBtn.addEventListener('click', function() {
			run('dns', dnsHost.value, output);
		});

		var pingBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ 'Ping' ]);
		pingBtn.addEventListener('click', function() {
			run('ping', pingHost.value, output);
		});

		var tunBtn = E('button', { 'class': 'btn cbi-button' }, [ 'TUN 接口状态' ]);
		tunBtn.addEventListener('click', function() {
			run('tun', '', output);
		});

		var vlessBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ 'VLESS 隧道出口检测' ]);
		vlessBtn.addEventListener('click', function() {
			run('vless', '', output);
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '连通性检测' ]),
			E('p', { 'class': 'hint' }, [
				'TUN 检测仅确认 gfctun 是否存在；',
				'VLESS 检测通过 curl 出口 IP 与当前节点服务器 IP 比对，验证代理隧道是否生效。'
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'DNS 域名' ]),
					E('div', { 'class': 'cbi-value-field' }, [ dnsHost, ' ', dnsBtn ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Ping 目标' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pingHost, ' ', pingBtn, ' ', tunBtn ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '代理隧道' ]),
					E('div', { 'class': 'cbi-value-field' }, [ vlessBtn ])
				])
			]),
			output
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
