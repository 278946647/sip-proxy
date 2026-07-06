'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function loadLogs(service) {
	return fs.exec('/usr/bin/wget', [
		'-qO-', '-T', '8',
		API + '/logs?service=' + encodeURIComponent(service) + '&lines=200'
	]).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

return view.extend({
	load: function() {
		return loadLogs('agent');
	},

	render: function(resp) {
		var select = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'agent' }, [ 'agent' ]),
			E('option', { 'value': 'api' }, [ 'api' ]),
			E('option', { 'value': 'unbound' }, [ 'unbound' ]),
			E('option', { 'value': 'sing-box' }, [ 'sing-box' ])
		]);
		var content = E('pre', {
			'style': 'white-space: pre-wrap; max-height: 520px; overflow: auto'
		}, [ (((resp || {}).data || {}).lines || []).join('\n') ]);

		var btn = E('button', { 'class': 'btn cbi-button cbi-button-reload' }, [ '刷新' ]);
		btn.addEventListener('click', function() {
			btn.disabled = true;
			loadLogs(select.value).then(function(res) {
				var data = (res || {}).data || {};
				content.textContent = (data.lines || []).join('\n') || data.error || '';
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			}).finally(function() {
				btn.disabled = false;
			});
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '运行日志' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '服务' ]),
					E('div', { 'class': 'cbi-value-field' }, [ select, ' ', btn ])
				])
			]),
			content
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
