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

return view.extend({
	load: function() {
		return call('/policy/egress-routes');
	},

	render: function(resp) {
		var data = (resp || {}).data || {};
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '策略路由' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [ data.message || '功能预留中。' ]),
				E('ul', {}, [
					E('li', {}, [ '将指定域名或 IP 映射到指定出口（WAN / gfctun / 多线路）' ]),
					E('li', {}, [ '数据面实现：nftables set + ip rule（与 inet gfc 架构对齐）' ]),
					E('li', {}, [ '当前版本仅展示规划，配置入口后续开放' ])
				]),
				E('p', { 'class': 'hint' }, [ '状态：' + (data.status || 'planned') ])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
