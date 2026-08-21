'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function execWget(args) {
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		if (res.code !== 0) {
			throw new Error((res.stderr || res.stdout || ('wget exit ' + res.code)).trim());
		}
		var out = res.stdout || '';
		if (!out)
			return {};
		try {
			return JSON.parse(out);
		} catch (e) {
			throw new Error('Invalid GFC API response: ' + out);
		}
	});
}

// BusyBox wget only supports GET and POST (--post-data), not --method=PUT.
function request(path, body) {
	var args = [ '-qO-', '-T', '15', '--header=Content-Type: application/json' ];
	if (body !== undefined) {
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return execWget(args);
}

function get(path) {
	return execWget([ '-qO-', '-T', '10', API + path ]);
}

function option(value, label, selected, disabled) {
	return E('option', {
		'value': value,
		'selected': value === selected ? 'selected' : null,
		'disabled': disabled ? 'disabled' : null
	}, [ label ]);
}

function input(value, placeholder) {
	return E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': value || '',
		'placeholder': placeholder || ''
	});
}

function showResult(result, res, label) {
	var payload = res || {};
	var body = payload.data !== undefined ? payload.data : payload;
	result.textContent = JSON.stringify(body, null, 2);
	if (payload.ok === false) {
		var msg = (payload.error && payload.error.message) ? payload.error.message : '请求失败';
		ui.addNotification(null, E('p', {}, label + '：' + msg), 'danger');
		return;
	}
	ui.addNotification(null, E('p', {}, label + '已提交'));
}

function hostsText(hosts) {
	if (!hosts)
		return '';
	if (typeof hosts === 'string')
		return hosts;
	if (Array.isArray(hosts))
		return hosts.join('\n');
	return '';
}

return view.extend({
	load: function() {
		return Promise.all([ get('/settings'), get('/routing'), get('/network/wan') ]);
	},

	render: function(data) {
		var settings = ((data[0] || {}).data || {});
		var routing = ((data[1] || {}).data || {});
		var wan = ((data[2] || {}).data || {});
		var proxyMode = settings.proxy_mode || 'gateway';
		var routeMode = routing.mode || settings.routing_mode || 'split';
		var liveMode = settings.live_mode || 'standard';
		var logLevel = settings.singbox_log_level || 'error';
		var pending = settings.proxy_mode_pending || null;
		var result = E('pre', { 'style': 'white-space: pre-wrap; max-height: 260px; overflow: auto' }, []);
		var pollTimer = null;

		var proxyModeSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('gateway', '网关模式', proxyMode),
			option('bypass', '旁路模式', proxyMode),
			option('transparent', '透明模式（待开发）', proxyMode, true)
		]);
		var routeSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('split', '分流模式', routeMode),
			option('global', '全局模式', routeMode)
		]);
		var liveSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('standard', '标准（国际走 VLESS）', liveMode),
			option('live_all_hy2', '直播模式 B · 全国际 Hysteria2', liveMode),
			option('live_catalog', '直播模式 A · 目录分流（ingest → Hy2）', liveMode)
		]);
		var logSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('error', 'error', logLevel),
			option('warn', 'warn', logLevel),
			option('info', 'info', logLevel),
			option('debug', 'debug', logLevel)
		]);

		var wanAddr = input(wan.address || '', '例如 10.20.30.2');
		var wanMask = input(wan.netmask || '', '例如 255.255.255.0');
		var wanGw = input(wan.gateway || '', '例如 10.20.30.1');
		var hostsBox = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width: 28em; min-height: 6em',
			'placeholder': '每行一个 IPv4 或 CIDR，例如：\n10.20.30.10\n10.20.30.0/24'
		}, [ hostsText(settings.customer_hosts) ]);
		var bypassFields = E('div', { 'class': 'cbi-section-node' }, [
			E('p', { 'class': 'alert-message warning' }, [
				settings.operate_from_lan || '请从管理 LAN 口操作。切换旁路会写入 WAN 静态地址；超时未确认将自动回滚。'
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ '旁路 WAN IP' ]),
				E('div', { 'class': 'cbi-value-field' }, [ wanAddr ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ '旁路 WAN 掩码' ]),
				E('div', { 'class': 'cbi-value-field' }, [ wanMask ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ '旁路 WAN 网关' ]),
				E('div', { 'class': 'cbi-value-field' }, [ wanGw ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ '客户源地址 @customer_hosts' ]),
				E('div', { 'class': 'cbi-value-field' }, [
					hostsBox,
					E('div', { 'class': 'hint' }, [ '把本机 WAN IP 当默认网关的客户主机/网段。不能与管理 LAN ' + (settings.lan_cidr || '') + ' 重叠。留空无法切旁路。' ])
				])
			])
		]);

		function toggleBypass() {
			bypassFields.style.display = proxyModeSelect.value === 'bypass' ? '' : 'none';
		}
		proxyModeSelect.addEventListener('change', toggleBypass);
		toggleBypass();

		var pendingBox = E('div', { 'class': 'alert-message notice', 'style': pending ? '' : 'display:none' }, []);
		var confirmBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '确认网络正常' ]);
		var rollbackBtn = E('button', { 'class': 'btn cbi-button' }, [ '立即回滚' ]);

		function renderPending(p) {
			pending = p || null;
			if (!pending) {
				pendingBox.style.display = 'none';
				if (pollTimer) {
					clearInterval(pollTimer);
					pollTimer = null;
				}
				return;
			}
			pendingBox.style.display = '';
			pendingBox.textContent = '';
			pendingBox.appendChild(E('p', {}, [
				'已申请切换到 ' + (pending.to_mode || '') + '，剩余 ' + (pending.seconds_left || 0) + ' 秒未确认将回滚 WAN 与模式。请确认仍能从管理 LAN 打开本页。'
			]));
			pendingBox.appendChild(E('p', {}, [ confirmBtn, ' ', rollbackBtn ]));
			if (!pollTimer) {
				pollTimer = setInterval(function() {
					get('/settings/proxy-mode').then(function(res) {
						var st = (res || {}).data || {};
						renderPending(st.pending || null);
						if (!st.pending)
							result.textContent = JSON.stringify(st, null, 2);
					}).catch(function() {});
				}, 2000);
			}
		}
		renderPending(pending);

		confirmBtn.addEventListener('click', function() {
			confirmBtn.disabled = true;
			request('/settings/proxy-mode/confirm', { token: pending && pending.token }).then(function(res) {
				showResult(result, res, '确认旁路切换');
				renderPending((((res || {}).data || {}).status || {}).pending || null);
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				confirmBtn.disabled = false;
			});
		});
		rollbackBtn.addEventListener('click', function() {
			rollbackBtn.disabled = true;
			request('/settings/proxy-mode/rollback', {}).then(function(res) {
				showResult(result, res, '回滚');
				renderPending(((res || {}).data || {}).pending || null);
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				rollbackBtn.disabled = false;
			});
		});

		var proxyModeBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用路由模式' ]);
		proxyModeBtn.addEventListener('click', function() {
			proxyModeBtn.disabled = true;
			result.textContent = 'applying proxy mode...';
			var body = { proxy_mode: proxyModeSelect.value, confirm_timeout_sec: 120 };
			if (proxyModeSelect.value === 'bypass') {
				body.wan = {
					mode: 'static',
					address: wanAddr.value,
					netmask: wanMask.value,
					gateway: wanGw.value
				};
				body.customer_hosts_text = hostsBox.value;
			}
			request('/settings/proxy-mode', body).then(function(res) {
				showResult(result, res, '路由模式');
				var st = (res || {}).data || {};
				renderPending(st.pending || null);
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				proxyModeBtn.disabled = false;
			});
		});

		var routeBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用代理模式' ]);
		routeBtn.addEventListener('click', function() {
			routeBtn.disabled = true;
			result.textContent = 'applying routing...';
			request('/routing', { mode: routeSelect.value }).then(function(res) {
				showResult(result, res, '代理模式');
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				routeBtn.disabled = false;
			});
		});

		var liveBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用直播模式' ]);
		liveBtn.addEventListener('click', function() {
			liveBtn.disabled = true;
			result.textContent = 'applying live mode...';
			request('/settings', { live_mode: liveSelect.value }).then(function(res) {
				showResult(result, res, '直播模式');
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				liveBtn.disabled = false;
			});
		});

		var logBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用日志级别' ]);
		logBtn.addEventListener('click', function() {
			logBtn.disabled = true;
			result.textContent = 'applying logging...';
			request('/settings/singbox/logging', { level: logSelect.value }).then(function(res) {
				showResult(result, res, '日志级别');
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				logBtn.disabled = false;
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '设备运行模式' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '设备名称' ]),
					E('div', { 'class': 'cbi-value-field' }, [ settings.device_name || '-' ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '路由模式' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						proxyModeSelect,
						' ',
						proxyModeBtn,
						E('div', { 'class': 'hint' }, [ '仅本机 Web 可写。旁路必须填 WAN 静态地址和 customer_hosts；控制面只读上报。' ])
					])
				]),
				pendingBox,
				bypassFields,
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '代理模式' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						routeSelect,
						' ',
						routeBtn,
						E('div', { 'class': 'hint' }, [ '设置流量代理策略：国内直连+国际代理，或全局走代理' ])
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '直播模式' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						liveSelect,
						' ',
						liveBtn,
						E('div', { 'class': 'hint' }, [ '与控制平台线路 live_mode 同步；全国际 Hy2 不经 urltest' ])
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Sing-box 日志级别' ]),
					E('div', { 'class': 'cbi-value-field' }, [ logSelect, ' ', logBtn ])
				])
			]),
			E('h3', {}, [ '应用结果' ]),
			result
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
