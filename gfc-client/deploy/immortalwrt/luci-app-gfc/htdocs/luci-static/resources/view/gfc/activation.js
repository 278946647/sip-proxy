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

function flash(code, reset) {
	return wget([
		'-qO-', '-T', '10',
		'--header=Content-Type: application/json',
		'--post-data=' + JSON.stringify({ code: code, reset_state: reset }),
		API + '/activation/flash'
	]);
}

return view.extend({
	load: getActivation,

	render: function(resp) {
		var payload = (resp || {}).data || {};
		var input = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': '输入 line code'
		});
		var reset = E('input', { 'type': 'checkbox', 'checked': 'checked' });
		var result = E('pre', { 'style': 'white-space: pre-wrap' }, [
			JSON.stringify(payload, null, 2)
		]);

		var button = E('button', { 'class': 'btn cbi-button cbi-button-apply' }, [ '激活设备' ]);
		button.addEventListener('click', function() {
			var code = (input.value || '').trim();
			if (!code) {
				ui.addNotification(null, E('p', {}, '请输入 line code'), 'danger');
				return;
			}
			button.disabled = true;
			flash(code, reset.checked).then(function(res) {
				result.textContent = JSON.stringify(res, null, 2);
				ui.addNotification(null, E('p', {}, '激活请求已提交'));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			}).finally(function() {
				button.disabled = false;
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 设备激活' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Line Code' ]),
					E('div', { 'class': 'cbi-value-field' }, [ input ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '重置本地状态' ]),
					E('div', { 'class': 'cbi-value-field' }, [ reset ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '' ]),
					E('div', { 'class': 'cbi-value-field' }, [ button ])
				])
			]),
			E('h3', {}, [ '当前激活信息' ]),
			result
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
