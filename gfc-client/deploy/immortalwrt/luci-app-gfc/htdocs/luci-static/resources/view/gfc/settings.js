'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function request(path, body, method) {
	var args = [ '-qO-', '-T', '10' ];
	if (body !== undefined) {
		args.push('--header=Content-Type: application/json');
		if (method)
			args.push('--method=' + method);
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function option(value, label, selected, disabled) {
	return E('option', {
		'value': value,
		'selected': value === selected ? 'selected' : null,
		'disabled': disabled ? 'disabled' : null
	}, [ label ]);
}

return view.extend({
	load: function() {
		return Promise.all([ request('/settings'), request('/routing') ]);
	},

	render: function(data) {
		var settings = ((data[0] || {}).data || {});
		var routing = ((data[1] || {}).data || {});
		var proxyMode = settings.proxy_mode || 'gateway';
		var routeMode = routing.mode || settings.routing_mode || 'split';
		var logLevel = settings.singbox_log_level || 'error';
		var result = E('pre', { 'style': 'white-space: pre-wrap; max-height: 260px; overflow: auto' }, []);

		var proxyModeSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('gateway', '网关模式', proxyMode),
			option('bypass', '旁路模式（待开发）', proxyMode, true),
			option('transparent', '透明模式（待开发）', proxyMode, true)
		]);
		var routeSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('split', '分流模式', routeMode),
			option('global', '全局模式', routeMode)
		]);
		var logSelect = E('select', { 'class': 'cbi-input-select' }, [
			option('error', 'error', logLevel),
			option('warn', 'warn', logLevel),
			option('info', 'info', logLevel),
			option('debug', 'debug', logLevel)
		]);

		var proxyModeBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用路由模式' ]);
		proxyModeBtn.addEventListener('click', function() {
			proxyModeBtn.disabled = true;
			result.textContent = 'applying proxy mode...';
			request('/settings', { proxy_mode: proxyModeSelect.value }, 'PUT').then(function(res) {
				result.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, '路由模式已提交'));
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
			request('/routing', { mode: routeSelect.value }, 'PUT').then(function(res) {
				result.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, '代理模式已提交'));
			}).catch(function(err) {
				result.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, result.textContent), 'danger');
			}).finally(function() {
				routeBtn.disabled = false;
			});
		});

		var logBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用日志级别' ]);
		logBtn.addEventListener('click', function() {
			logBtn.disabled = true;
			result.textContent = 'applying logging...';
			request('/settings/singbox/logging', { level: logSelect.value }, 'PUT').then(function(res) {
				result.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, '日志级别已提交'));
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
						E('div', { 'class': 'hint' }, [ '设置设备在网络中的工作方式：网关 / 旁路 / 透明' ])
					])
				]),
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
