'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function api(path, postData) {
	var args = [ '-qO-', '-T', '8' ];
	if (postData !== undefined) {
		args.push('--header=Content-Type: application/json');
		args.push('--post-data=' + JSON.stringify(postData || {}));
	}
	args.push(API + path);
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

function val(v) {
	return v === null || v === undefined || v === '' ? '-' : String(v);
}

return view.extend({
	load: function() {
		return api('/services');
	},

	render: function(resp) {
		var services = ((resp || {}).data || {}).services || {};
		var rows = Object.keys(services).map(function(name) {
			var item = services[name] || {};
			var btn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ '重启' ]);
			btn.addEventListener('click', function() {
				btn.disabled = true;
				api('/services/' + encodeURIComponent(name) + '/restart', {}).then(function(res) {
					ui.addNotification(null, E('p', {}, val(((res || {}).data || {}).message || 'done')));
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				}).finally(function() {
					btn.disabled = false;
				});
			});
			return E('tr', {}, [
				E('td', {}, [ name ]),
				E('td', {}, [ val(item.active) ]),
				E('td', {}, [ val(item.sub) ]),
				E('td', {}, [ val(item.unit) ]),
				E('td', {}, [ btn ])
			]);
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ 'GFC 服务' ]),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('th', {}, [ '服务' ]),
					E('th', {}, [ '状态' ]),
					E('th', {}, [ '子状态' ]),
					E('th', {}, [ 'Unit' ]),
					E('th', {}, [ '操作' ])
				])
			].concat(rows))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
