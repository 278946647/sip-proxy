'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function wget(args) {
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function getActivation() {
	return wget([ '-qO-', '-T', '5', API + '/activation' ]).catch(function() {
		return { ok: false };
	});
}

return view.extend({
	load: getActivation,

	render: function(resp) {
		var payload = ((resp || {}).data || {});
		var present = !!payload.code_present;
		var inner = (payload.payload || {});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 激活状态' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [
					'线路码刷入与设备激活已移至系统外部页面，无需 OpenWrt 登录即可完成。'
				]),
				E('p', {}, [
					E('a', {
						'href': '/gfc/activate.html',
						'class': 'btn cbi-button cbi-button-apply',
						'style': 'display:inline-block;margin-right:8px'
					}, [ '前往外部激活页' ]),
					E('a', {
						'href': '/cgi-bin/luci/admin/gfc/status/overview',
						'class': 'btn cbi-button'
					}, [ 'GFC 管理概览' ])
				])
			]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('td', { 'class': 'th' }, [ '线路码' ]),
					E('td', {}, [ present ? '已写入' : '未激活' ])
				]),
				E('tr', {}, [
					E('td', { 'class': 'th' }, [ '控制面' ]),
					E('td', {}, [
						inner.controlPlaneUrl || inner.control_plane_url || inner.control || '-'
					])
				])
			]),
			E('h3', {}, [ '原始激活信息' ]),
			E('pre', { 'style': 'white-space: pre-wrap' }, [
				JSON.stringify(payload, null, 2)
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
