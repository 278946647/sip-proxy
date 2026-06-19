'use strict';
'require view';
'require fs';

var API = 'http://127.0.0.1:8080/api/v1';

function call(path) {
	return fs.exec('/usr/bin/wget', [ '-qO-', '-T', '8', API + path ]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	}).catch(function() {
		return {};
	});
}

function val(v) {
	if (v === null || v === undefined || v === '')
		return '-';
	if (typeof v === 'object')
		return JSON.stringify(v);
	return String(v);
}

return view.extend({
	load: function() {
		return Promise.all([ call('/nodes'), call('/status'), call('/singbox/stats') ]);
	},

	render: function(data) {
		var nodes = (((data[0] || {}).data || {}).nodes || []);
		var status = ((data[1] || {}).data || {});
		var singbox = ((data[2] || {}).data || {});

		var rows = nodes.map(function(node) {
			return E('tr', {}, [
				E('td', {}, [ val(node.name || node.id) ]),
				E('td', {}, [ val(node.type || 'vless') ]),
				E('td', {}, [ val(node.server || node.address) ]),
				E('td', {}, [ val(node.port) ]),
				E('td', {}, [ val(node.latency_ms) ]),
				E('td', {}, [ node.enabled === false ? '禁用' : '启用' ])
			]);
		});

		if (!rows.length) {
			rows.push(E('tr', {}, [
				E('td', { 'colspan': 6 }, [ '暂无节点。激活设备或等待控制面下发配置后会显示。' ])
			]));
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 节点/线路' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '设备状态' ]),
					E('div', { 'class': 'cbi-value-field' }, [ val(status.state) ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Sing-box' ]),
					E('div', { 'class': 'cbi-value-field' }, [ singbox.ok ? 'ok' : val(singbox.error || singbox.controller) ])
				])
			]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '名称' ]),
					E('th', {}, [ '类型' ]),
					E('th', {}, [ '服务器' ]),
					E('th', {}, [ '端口' ]),
					E('th', {}, [ '延迟(ms)' ]),
					E('th', {}, [ '状态' ])
				])
			].concat(rows))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
