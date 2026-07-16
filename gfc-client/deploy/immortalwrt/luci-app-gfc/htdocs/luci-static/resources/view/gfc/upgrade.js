'use strict';
'require view';
'require fs';
'require ui';
'require form';

var API = 'http://127.0.0.1:8080/api/v1';

function request(path, body) {
	var args = [ '-qO-', '-T', '120' ];
	if (body !== undefined) {
		args.push('--header=Content-Type: application/json');
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		return JSON.parse(res.stdout || '{}');
	});
}

return view.extend({
	load: function() {
		return request('/upgrade/status');
	},

	render: function(data) {
		var wrap = E('div', { 'class': 'cbi-map' });
		var st = (data && data.data) || data || {};

		wrap.appendChild(E('h2', {}, [ _('系统版本升级') ]));
		wrap.appendChild(E('p', {}, [
			_('从控制平台下发的升级会在 Agent 心跳时自动执行；也可在此上传本地 runtime 包（等同 scp + install.sh）。')
		]));

		var table = E('table', { 'class': 'table' }, [
			E('tr', {}, [ E('td', { 'class': 'th' }, [ _('当前版本') ]), E('td', {}, [ String(st.current || '-') ]) ]),
			E('tr', {}, [ E('td', { 'class': 'th' }, [ _('远端版本') ]), E('td', {}, [ String(st.latest || '-') ]) ]),
			E('tr', {}, [ E('td', { 'class': 'th' }, [ _('可升级') ]), E('td', {}, [ String(st.update_available || false) ]) ])
		]);
		wrap.appendChild(table);

		var out = E('pre', { 'style': 'white-space:pre-wrap;margin-top:12px' }, []);

		var refreshBtn = E('button', { 'class': 'btn cbi-button' }, [ _('刷新状态') ]);
		refreshBtn.addEventListener('click', function() {
			request('/upgrade/status').then(function(res) {
				out.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, _('已刷新')));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			});
		});

		var pathInput = E('input', {
			'type': 'text',
			'style': 'width:100%;max-width:480px',
			'placeholder': '/tmp/gfc-immortalwrt-runtime-....tar.gz'
		});
		var localBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ _('安装本地路径包') ]);
		localBtn.addEventListener('click', function() {
			var p = (pathInput.value || '').trim();
			if (!p) {
				ui.addNotification(null, E('p', {}, _('请填写包路径')), 'warning');
				return;
			}
			localBtn.disabled = true;
			out.textContent = 'installing...';
			request('/upgrade/apply-local', { path: p }).then(function(res) {
				out.textContent = JSON.stringify((res || {}).data || res, null, 2);
				ui.addNotification(null, E('p', {}, _('升级完成，建议重启 gfc-agent')));
			}).catch(function(err) {
				out.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, out.textContent), 'danger');
			}).finally(function() {
				localBtn.disabled = false;
			});
		});

		wrap.appendChild(E('div', { 'style': 'margin-top:16px' }, [
			E('h3', {}, [ _('本地包升级') ]),
			E('p', {}, [ _('将 Ubuntu 编译的 runtime tar.gz 拷到设备后填写路径：') ]),
			pathInput,
			E('div', { 'style': 'margin-top:8px' }, [ refreshBtn, ' ', localBtn ])
		]));
		wrap.appendChild(out);
		return wrap;
	}
});
