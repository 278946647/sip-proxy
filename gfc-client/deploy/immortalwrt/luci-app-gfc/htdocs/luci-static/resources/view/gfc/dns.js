'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function parseJSON(res) {
	var out = res.stdout || '';
	if (!out)
		return {};
	try {
		return JSON.parse(out);
	} catch (e) {
		throw new Error('Invalid GFC API response: ' + out);
	}
}

function execWget(args) {
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		if (res.code !== 0) {
			throw new Error((res.stderr || res.stdout || ('wget exit ' + res.code)).trim());
		}
		return parseJSON(res);
	});
}

// BusyBox wget only supports GET and POST (--post-data), not --method=PUT.
function request(path, body) {
	var args = [ '-qO-', '-T', '20' ];
	if (body !== undefined) {
		args.push('--header=Content-Type: application/json');
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return execWget(args);
}

function get(path) {
	return execWget([ '-qO-', '-T', '20', API + path ]);
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

function snippetEditor(title, kind, hint, content, onSave, onAudit) {
	var ta = E('textarea', {
		'style': 'width:100%;min-height:140px;font-family:monospace;font-size:12px',
		'wrap': 'off'
	}, [ content || '' ]);
	var out = E('pre', { 'style': 'white-space:pre-wrap;font-size:12px' }, []);
	var saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '保存并校验' ]);
	var auditBtn = E('button', { 'class': 'btn cbi-button', 'style': 'margin-left:8px' }, [ '冲突预检' ]);
	saveBtn.addEventListener('click', function() {
		saveBtn.disabled = true;
		auditBtn.disabled = true;
		onSave(kind, ta.value, out).finally(function() {
			saveBtn.disabled = false;
			auditBtn.disabled = false;
		});
	});
	auditBtn.addEventListener('click', function() {
		saveBtn.disabled = true;
		auditBtn.disabled = true;
		onAudit(kind, ta.value, out).finally(function() {
			saveBtn.disabled = false;
			auditBtn.disabled = false;
		});
	});
	return E('div', { 'class': 'cbi-section' }, [
		E('h4', {}, [ title ]),
		E('p', { 'class': 'hint' }, [ hint ]),
		ta,
		E('div', {}, [ saveBtn, auditBtn ]),
		out
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			get('/dns/unbound/status'),
			get('/status'),
			exec('/sbin/uci', [ 'show', 'dhcp' ]),
			get('/dns/unbound/snippets/block'),
			get('/dns/unbound/snippets/static'),
			get('/dns/unbound/snippets/domestic-forward')
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
		var lookupOut = E('pre', { 'style': 'white-space:pre-wrap;font-size:12px' }, []);

		function saveSnippet(kind, content, out) {
			return request('/dns/unbound/snippets/' + kind, { content: content }).then(function(res) {
				if (res.ok === false) {
					out.textContent = JSON.stringify(res, null, 2);
					ui.addNotification(null, E('p', {}, ((res.error || {}).message) || '保存失败'), 'danger');
					return;
				}
				out.textContent = JSON.stringify((res || {}).data || res, null, 2);
				var audit = ((res || {}).data || {}).audit || {};
				var note = kind + ' 已保存并通过 unbound-checkconf';
				if (audit.summary && audit.summary !== '无冲突')
					note += '（' + audit.summary + '）';
				ui.addNotification(null, E('p', {}, note));
			}).catch(function(err) {
				out.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, out.textContent), 'danger');
			});
		}

		function auditSnippet(kind, content, out) {
			return request('/dns/unbound/snippets/' + kind + '/audit', { content: content }).then(function(res) {
				out.textContent = JSON.stringify((res || {}).data || res, null, 2);
				var audit = (res || {}).data || {};
				if (audit.denied)
					ui.addNotification(null, E('p', {}, '存在互斥冲突，保存将被拒绝'), 'danger');
				else if (audit.summary && audit.summary !== '无冲突')
					ui.addNotification(null, E('p', {}, '预检：' + audit.summary), 'warning');
				else
					ui.addNotification(null, E('p', {}, '预检：无冲突'));
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
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			});
		});

		var syncBtn = E('button', { 'class': 'btn cbi-button-action' }, [ '从内置包更新 CN 列表' ]);
		syncBtn.addEventListener('click', function() {
			if (!confirm('将从内置 share/unbound 同步 CN 列表，并自动备份当前文件。继续？'))
				return;
			request('/dns/unbound/cn/sync', {}).then(function(res) {
				msg.textContent = JSON.stringify(res, null, 2);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			});
		});

		var checkBtn = E('button', { 'class': 'btn cbi-button' }, [ 'unbound-checkconf' ]);
		checkBtn.addEventListener('click', function() {
			request('/dns/unbound/check', {}).then(function(res) {
				msg.textContent = JSON.stringify(res, null, 2);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
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
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			});
		});

		var lookupInput = E('input', {
			'class': 'cbi-input-text',
			'style': 'min-width:240px',
			'placeholder': '域名，如 ip.sb'
		});
		var lookupBtn = E('button', { 'class': 'btn cbi-button-action' }, [ '跨文件检索' ]);
		lookupBtn.addEventListener('click', function() {
			var q = (lookupInput.value || '').trim();
			if (!q)
				return;
			lookupBtn.disabled = true;
			get('/dns/unbound/lookup?q=' + encodeURIComponent(q)).then(function(res) {
				lookupOut.textContent = JSON.stringify((res || {}).data || res, null, 2);
			}).catch(function(err) {
				lookupOut.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, lookupOut.textContent), 'danger');
			}).finally(function() {
				lookupBtn.disabled = false;
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'DNS 与分流' ]),
			E('p', { 'class': 'hint' }, [
				'Unbound 监听 :53。阻断 / 静态 / 国内转发请按行填写简表，系统自动生成 unbound 配置；保存前可冲突预检，并可用检索查看是否与其它列表或 cn.unbound.conf 冲突。'
			]),
			E('table', { 'class': 'table' }, [
				row('Unbound', dns.ok ? '正常' : (dns.error || '异常')),
				row('配置校验', check.ok ? '通过' : (check.error || '未通过')),
				row('dnsmasq port=0', /port='0'/.test(uci) ? '是' : '否')
			]),
			E('h3', {}, [ '域名冲突检索' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'hint' }, [ '查询某域名是否出现在 block / static / domestic-forward / cn.unbound.conf。' ]),
				E('div', {}, [ lookupInput, ' ', lookupBtn ]),
				lookupOut
			]),
			E('h3', {}, [ 'CN 域名列表 (cn.unbound.conf)' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ '备份列表：' ]),
				backupList,
				backupBtn, ' ', syncBtn, ' ', checkBtn,
				E('div', { 'style': 'margin-top:8px' }, [ restoreName, ' ', restoreBtn ])
			]),
			snippetEditor(
				'域名阻断 (gfc-block.conf)',
				'block',
				'格式：每行一个域名。例：ads.example.com',
				block, saveSnippet, auditSnippet
			),
			snippetEditor(
				'静态解析 (gfc-static.conf)',
				'static',
				'格式：域名 IPv4。例：mmo.example.com 203.0.113.10',
				staticSnip, saveSnippet, auditSnippet
			),
			snippetEditor(
				'指定域名走国内 DNS (gfc-domestic-forward.conf)',
				'domestic-forward',
				'格式：域名 上游DNS [上游DNS...]。例：special.example.com 223.5.5.5 119.29.29.29',
				domestic, saveSnippet, auditSnippet
			),
			E('h3', {}, [ '操作结果' ]),
			msg
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
