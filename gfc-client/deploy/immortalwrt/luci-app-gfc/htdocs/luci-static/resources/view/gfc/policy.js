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

function val(v) {
	if (v === null || v === undefined || v === '')
		return '-';
	if (Array.isArray(v))
		return v.join(', ');
	if (typeof v === 'object')
		return JSON.stringify(v);
	return String(v);
}

return view.extend({
	load: function() {
		return request('/policy/groups');
	},

	render: function(resp) {
		var groups = (((resp || {}).data || {}).groups || []);
		var output = E('pre', { 'style': 'white-space: pre-wrap; max-height: 220px; overflow: auto' }, []);

		var rows = groups.map(function(group) {
			var outbounds = group.outbounds || [];
			var selected = group.selected || outbounds[0] || 'proxy';
			var select = E('select', { 'class': 'cbi-input-select' },
				outbounds.length ? outbounds.map(function(outbound) {
					return E('option', {
						'value': outbound,
						'selected': outbound === selected ? 'selected' : null
					}, [ outbound ]);
				}) : [ E('option', { 'value': selected }, [ selected ]) ]);

			var btn = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '应用' ]);
			btn.addEventListener('click', function() {
				btn.disabled = true;
				output.textContent = 'applying...';
				request('/policy/groups/' + encodeURIComponent(group.id) + '/select', {
					outbound: select.value
				}, 'PUT').then(function(res) {
					output.textContent = JSON.stringify((res || {}).data || res, null, 2);
					ui.addNotification(null, E('p', {}, '策略已提交'));
				}).catch(function(err) {
					output.textContent = err.message || String(err);
					ui.addNotification(null, E('p', {}, output.textContent), 'danger');
				}).finally(function() {
					btn.disabled = false;
				});
			});

			return E('tr', {}, [
				E('td', {}, [ val(group.name || group.id) ]),
				E('td', {}, [ val(group.type) ]),
				E('td', {}, [ select ]),
				E('td', {}, [ val(outbounds) ]),
				E('td', {}, [ btn ])
			]);
		});

		if (!rows.length) {
			rows.push(E('tr', {}, [
				E('td', { 'colspan': 5 }, [ '暂无策略组。等待控制面下发配置后会显示。' ])
			]));
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '代理出站选择' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '策略组' ]),
					E('th', {}, [ '类型' ]),
					E('th', {}, [ '当前选择' ]),
					E('th', {}, [ '可选出站' ]),
					E('th', {}, [ '操作' ])
				])
			].concat(rows)),
			E('h3', {}, [ '应用结果' ]),
			output
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
