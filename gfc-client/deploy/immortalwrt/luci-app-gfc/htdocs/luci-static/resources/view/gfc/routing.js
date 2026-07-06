'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function request(path, body, method) {
	var args = [ '-qO-', '-T', '15' ];
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

function val(v) {
	return v === null || v === undefined || v === '' ? '' : String(v);
}

return view.extend({
	load: function() {
		return Promise.all([
			request('/network/routes'),
			request('/network/route-devices')
		]);
	},

	render: function(data) {
		var routesCfg = ((data[0] || {}).data || {});
		var routes = routesCfg.routes || [];
		var devices = (((data[1] || {}).data || {}).devices || [ 'wan', 'lan', 'gfctun' ]);
		var tbody = E('tbody', {});
		var result = E('pre', { 'style': 'white-space:pre-wrap' }, []);

		function addRow(route) {
			route = route || {};
			var iface = E('select', { 'class': 'cbi-input-select' }, devices.map(function(d) {
				return E('option', {
					'value': d,
					'selected': d === (route.interface || 'wan') ? 'selected' : null
				}, [ d ]);
			}));
			var target = E('input', { 'class': 'cbi-input-text', 'value': val(route.target), 'placeholder': '目标网段' });
			var netmask = E('input', { 'class': 'cbi-input-text', 'value': val(route.netmask), 'placeholder': '255.255.255.0' });
			var gateway = E('input', { 'class': 'cbi-input-text', 'value': val(route.gateway), 'placeholder': '网关' });
			var metric = E('input', { 'class': 'cbi-input-text', 'value': val(route.metric), 'placeholder': 'metric' });
			var del = E('button', { 'class': 'btn cbi-button cbi-button-remove', 'type': 'button' }, [ '删除' ]);
			var tr = E('tr', {}, [
				E('td', {}, [ iface ]),
				E('td', {}, [ target ]),
				E('td', {}, [ netmask ]),
				E('td', {}, [ gateway ]),
				E('td', {}, [ metric ]),
				E('td', {}, [ del ])
			]);
			del.addEventListener('click', function() {
				tbody.removeChild(tr);
			});
			tbody.appendChild(tr);
		}

		routes.forEach(addRow);
		if (!routes.length)
			addRow({ interface: 'wan' });

		var addBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '添加路由' ]);
		addBtn.addEventListener('click', function() {
			addRow({ interface: 'wan' });
		});

		var saveBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '保存并应用' ]);
		saveBtn.addEventListener('click', function() {
			var out = [];
			Array.prototype.forEach.call(tbody.querySelectorAll('tr'), function(tr) {
				var inputs = tr.querySelectorAll('input');
				var sel = tr.querySelector('select');
				out.push({
					interface: sel ? sel.value : 'wan',
					target: inputs[0] ? inputs[0].value : '',
					netmask: inputs[1] ? inputs[1].value : '',
					gateway: inputs[2] ? inputs[2].value : '',
					metric: inputs[3] ? inputs[3].value : ''
				});
			});
			saveBtn.disabled = true;
			request('/network/routes', { routes: out }, 'PUT').then(function(res) {
				result.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, '静态路由已保存'));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			}).finally(function() {
				saveBtn.disabled = false;
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '静态路由' ]),
			E('p', { 'class': 'hint' }, [ '支持选择 gfctun / wan / lan 等出口，弥补 OpenWrt 原生静态路由缺少 TUN 接口选项的问题。' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '接口' ]),
					E('th', {}, [ '目标' ]),
					E('th', {}, [ '掩码' ]),
					E('th', {}, [ '网关' ]),
					E('th', {}, [ 'Metric' ]),
					E('th', {}, [ '' ])
				]) ]),
				tbody
			]),
			E('div', { 'class': 'cbi-section' }, [ addBtn, ' ', saveBtn ]),
			E('h3', {}, [ '应用结果' ]),
			result
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
