'use strict';
'require view';
'require fs';
'require ui';

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
		return Promise.all([
			call('/activation'),
			call('/nodes'),
			call('/status'),
			call('/agent'),
			call('/singbox/stats')
		]);
	},

	render: function(data) {
		var activation = ((data[0] || {}).data || {});
		var nodes = (((data[1] || {}).data || {}).nodes || []);
		var status = ((data[2] || {}).data || {});
		var agent = ((data[3] || {}).data || {});
		var singbox = ((data[4] || {}).data || {});
		var inner = activation.payload || {};

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
				E('td', { 'colspan': 6 }, [ '暂无节点。请在外部激活页刷入线路码。' ])
			]));
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '线路与节点' ]),
			E('p', { 'class': 'hint' }, [
				'刷码请访问 ',
				E('a', { 'href': '/gfc/activate.html' }, [ '/gfc/activate.html' ]),
				'（无需登录）。'
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [
					E('tr', {}, [ E('td', { 'class': 'th' }, [ '线路码' ]), E('td', {}, [ activation.code_present ? '已写入' : '未激活' ]) ]),
					E('tr', {}, [ E('td', { 'class': 'th' }, [ '控制面' ]), E('td', {}, [ val(inner.controlPlaneUrl || inner.control_plane_url || inner.control) ]) ]),
					E('tr', {}, [ E('td', { 'class': 'th' }, [ '设备状态' ]), E('td', {}, [ val(status.state) ]) ]),
					E('tr', {}, [ E('td', { 'class': 'th' }, [ 'Agent' ]), E('td', {}, [ val(agent.status || agent.state) ]) ]),
					E('tr', {}, [ E('td', { 'class': 'th' }, [ 'Sing-box' ]), E('td', {}, [ singbox.ok ? '正常' : val(singbox.error) ]) ])
				])
			]),
			E('h3', {}, [ '节点列表' ]),
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
