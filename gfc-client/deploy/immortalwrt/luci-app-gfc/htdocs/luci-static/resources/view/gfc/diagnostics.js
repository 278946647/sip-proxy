'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function post(path, body) {
	return fs.exec('/usr/bin/wget', [
		'-qO-', '-T', '10',
		'--header=Content-Type: application/json',
		'--post-data=' + JSON.stringify(body || {}),
		API + path
	]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function run(kind, host, out) {
	out.textContent = 'running...';
	return post('/diagnostics/' + kind, { host: host }).then(function(res) {
		out.textContent = JSON.stringify((res || {}).data || res, null, 2);
	}).catch(function(err) {
		out.textContent = err.message || String(err);
		ui.addNotification(null, E('p', {}, out.textContent), 'danger');
	});
}

return view.extend({
	render: function() {
		var dnsHost = E('input', {
			'class': 'cbi-input-text',
			'value': 'www.google.com'
		});
		var pingHost = E('input', {
			'class': 'cbi-input-text',
			'value': '1.1.1.1'
		});
		var output = E('pre', {
			'style': 'white-space: pre-wrap; max-height: 520px; overflow: auto'
		}, [ '请选择诊断操作' ]);

		var dnsBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ 'DNS 查询' ]);
		dnsBtn.addEventListener('click', function() {
			run('dns', dnsHost.value, output);
		});

		var pingBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ 'Ping' ]);
		pingBtn.addEventListener('click', function() {
			run('ping', pingHost.value, output);
		});

		var tunBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ 'TUN 状态' ]);
		tunBtn.addEventListener('click', function() {
			run('tun', '', output);
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 诊断' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'DNS Host' ]),
					E('div', { 'class': 'cbi-value-field' }, [ dnsHost, ' ', dnsBtn ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Ping Host' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pingHost, ' ', pingBtn, ' ', tunBtn ])
				])
			]),
			output
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
