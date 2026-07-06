'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function request(path, body, method) {
	var args = [ '-qO-', '-T', '20' ];
	if (body !== undefined) {
		args.push('--header=Content-Type: application/json');
		if (method && method !== 'POST')
			args.push('--method=' + method);
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function exec(cmd, args) {
	return fs.exec(cmd, args || []).then(function(res) {
		return res.stdout || '';
	}).catch(function(err) {
		return err.message || String(err);
	});
}

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'class': 'th' }, [ label ]),
		E('td', {}, [ value || '-' ])
	]);
}

function snippetEditor(title, kind, content, onSave) {
	var ta = E('textarea', {
		'style': 'width:100%;min-height:140px;font-family:monospace;font-size:12px',
		'wrap': 'off'
	}, [ content || '' ]);
	var out = E('pre', { 'style': 'white-space:pre-wrap;font-size:12px' }, []);
	var btn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '保存并校验' ]);
	btn.addEventListener('click', function() {
		btn.disabled = true;
		onSave(kind, ta.value, out).finally(function() {
			btn.disabled = false;
		});
	});
	return E('div', { 'class': 'cbi-section' }, [
		E('h4', {}, [ title ]),
		ta,
		E('div', {}, [ btn ]),
		out
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			request('/dns/unbound/status'),
			request('/status'),
			exec('/sbin/uci', [ 'show', 'dhcp' ]),
			request('/dns/unbound/snippets/block'),
			request('/dns/unbound/snippets/static'),
			request('/dns/unbound/snippets/domestic-forward')
		]);
	},

	render: function(data) {
		var st = ((data[0] || {}).data || {});
		var status = ((data[1] || {}).data || {});
		var uci = data[2] || '';
		var block = ((data[3] || {}).data || {}).content || '';
		var staticSnip = ((data[4] || {}).data || {}).content || '';
		var domestic = ((data[5] || {}).data || {}).content || '';
		var dns = status.dns || {};
		var backups = st.backups || [];
		var check = st.check || {};

		var backupList = E('ul', {}, backups.slice(0, 8).map(function(b) {
			return E('li', {}, [ b.name + ' (' + b.updated + ')' ]);
		}));
		if (!backups.length)
			backupList = E('p', {}, [ '尚无备份' ]);

		var msg = E('pre', { 'style': 'white-space:pre-wrap' }, []);

		function saveSnippet(kind, content, out) {
			return request('/dns/unbound/snippets/' + kind, { content: content }, 'PUT').then(function(res) {
				out.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, kind + ' 已保存并通过 unbound-checkconf'));
			}).catch(function(err) {
				out.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, out.textContent), 'danger');
			});
		}

		var backupBtn = E('button', { 'class': 'btn cbi-button' }, [ '备份 CN 列表' ]);
		backupBtn.addEventListener('click', function() {
			request('/dns/unbound/cn/backup', {}).then(function(res) {
				msg.textContent = JSON.stringify(res, null, 2);
				ui.addNotification(null, E('p', {}, '备份完成'));
			});
		});

		var syncBtn = E('button', { 'class': 'btn cbi-button-action' }, [ '从内置包更新 CN 列表' ]);
		syncBtn.addEventListener('click', function() {
			if (!confirm('将从内置 share/unbound 同步 CN 列表，并自动备份当前文件。继续？'))
				return;
			request('/dns/unbound/cn/sync', {}).then(function(res) {
				msg.textContent = JSON.stringify(res, null, 2);
			});
		});

		var checkBtn = E('button', { 'class': 'btn cbi-button' }, [ 'unbound-checkconf' ]);
		checkBtn.addEventListener('click', function() {
			request('/dns/unbound/check', {}).then(function(res) {
				msg.textContent = JSON.stringify(res, null, 2);
			});
		});

		var restoreName = E('input', { 'class': 'cbi-input-text', 'placeholder': '备份文件名，如 cn.unbound.20260706-120000.conf' });
		var restoreBtn = E('button', { 'class': 'btn cbi-button' }, [ '从备份恢复 CN 列表' ]);
		restoreBtn.addEventListener('click', function() {
			if (!restoreName.value)
				return;
			if (!confirm('恢复将覆盖当前 cn.unbound.conf，继续？'))
				return;
			request('/dns/unbound/cn/restore', { backup: restoreName.value }).then(function(res) {
				msg.textContent = JSON.stringify(res, null, 2);
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'DNS 与分流' ]),
			E('p', { 'class': 'hint' }, [ 'Unbound 监听 :53；CN 域名列表、阻断、静态解析、国内转发为独立 conf 文件，保存时自动 unbound-checkconf。' ]),
			E('table', { 'class': 'table' }, [
				row('Unbound', dns.ok ? '正常' : (dns.error || '异常')),
				row('配置校验', check.ok ? '通过' : (check.error || '未通过')),
				row('dnsmasq port=0', /port='0'/.test(uci) ? '是' : '否')
			]),
			E('h3', {}, [ 'CN 域名列表 (cn.unbound.conf)' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ '备份列表：' ]),
				backupList,
				backupBtn, ' ', syncBtn, ' ', checkBtn,
				E('div', { 'style': 'margin-top:8px' }, [ restoreName, ' ', restoreBtn ])
			]),
			snippetEditor('域名阻断 (gfc-block.conf)', 'block', block, saveSnippet),
			snippetEditor('静态解析 (gfc-static.conf)', 'static', staticSnip, saveSnippet),
			snippetEditor('指定域名走国内 DNS (gfc-domestic-forward.conf)', 'domestic-forward', domestic, saveSnippet),
			E('h3', {}, [ '操作结果' ]),
			msg
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
