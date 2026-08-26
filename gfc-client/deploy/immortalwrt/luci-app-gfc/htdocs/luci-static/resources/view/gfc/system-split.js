'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';

function parseJSON(res) {
	var out = res.stdout || '';
	if (!out)
		return {};
	try {
		return JSON.parse(out);
	} catch (e) {
		throw new Error('Invalid GFC API response: ' + out);
	}
}

function execWget(args) {
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		if (res.code !== 0) {
			throw new Error((res.stderr || res.stdout || ('wget exit ' + res.code)).trim());
		}
		return parseJSON(res);
	});
}

function get(path) {
	return execWget([ '-qO-', '-T', '15', API + path ]);
}

function post(path, body) {
	return execWget([
		'-qO-', '-T', '20',
		'--header=Content-Type: application/json',
		'--post-data=' + JSON.stringify(body || {}),
		API + path
	]);
}

function row(label, value) {
	return E('tr', {}, [
		E('td', { 'class': 'th', 'style': 'width:12em' }, [ label ]),
		E('td', {}, [ value === null || value === undefined || value === '' ? '-' : String(value) ])
	]);
}

function sampleText(arr) {
	if (!arr || !arr.length)
		return '（空）';
	var s = arr.slice(0, 12).join(', ');
	if (arr.length > 12)
		s += ' …';
	return s;
}

return view.extend({
	load: function() {
		return get('/policy-routing/system-rules');
	},

	render: function(resp) {
		var data = (resp || {}).data || {};
		var sets = data.sets || {};
		var defaults = data.default_rules || [];
		var overrides = data.user_overrides || [];
		var health = data.safety_rail_health || {};
		var probeOut = E('pre', { 'style': 'white-space:pre-wrap;max-height:240px;overflow:auto' }, []);

		var setRows = Object.keys(sets).map(function(k) {
			var s = sets[k] || {};
			return E('tr', {}, [
				E('td', {}, [ s.name || k ]),
				E('td', {}, [ String(s.count || 0) ]),
				E('td', {}, [ s.writable || 'readonly' ]),
				E('td', { 'style': 'font-family:monospace;font-size:12px;word-break:break-all' }, [ sampleText(s.sample) ])
			]);
		});

		var defBody = E('tbody', {});
		defaults.forEach(function(r) {
			defBody.appendChild(E('tr', {}, [
				E('td', {}, [ r.name || r.id ]),
				E('td', {}, [ r.layer || '' ]),
				E('td', {}, [ r.action || '' ]),
				E('td', {}, [ r.covered_by ? ('已被 Override#' + r.covered_by + (r.covered_by_name ? ' (' + r.covered_by_name + ')' : '')) : '—' ])
			]));
		});

		var ovrBody = E('tbody', {});
		overrides.forEach(function(p, idx) {
			ovrBody.appendChild(E('tr', {}, [
				E('td', {}, [ String(idx + 1) ]),
				E('td', {}, [ p.name || '' ]),
				E('td', {}, [ p.action || '' ]),
				E('td', {}, [ p.status || '' ]),
				E('td', {}, [ p.id || '' ])
			]));
		});

		var probeSrc = E('input', { 'class': 'cbi-input-text', 'placeholder': '源 IP（可选）' });
		var probeDst = E('input', { 'class': 'cbi-input-text', 'placeholder': '目的 IP' });
		var probeDom = E('input', { 'class': 'cbi-input-text', 'placeholder': '或域名' });
		var probeBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '试算' ]);
		probeBtn.addEventListener('click', function() {
			probeBtn.disabled = true;
			post('/policy-routing/probe', {
				probe_src: probeSrc.value.trim(),
				probe_dst: probeDst.value.trim(),
				probe_domain: probeDom.value.trim()
			}).then(function(res) {
				probeOut.textContent = JSON.stringify((res || {}).data || res, null, 2);
				if (res.ok === false)
					ui.addNotification(null, E('p', {}, (res.error && res.error.message) || '试算失败'), 'danger');
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			}).finally(function() {
				probeBtn.disabled = false;
			});
		});

		var addOverride = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '添加覆盖' ]);
		addOverride.addEventListener('click', function() {
			var q = 'action=proxy';
			if (probeDst.value.trim())
				q += '&hint_dst=' + encodeURIComponent(probeDst.value.trim());
			if (probeDom.value.trim())
				q += '&hint_domain=' + encodeURIComponent(probeDom.value.trim());
			window.location = L.url('admin/gfc/config/policy-route') + '?' + q;
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '系统分流规则' ]),
			E('p', { 'class': 'hint' }, [
				'只读查看 L0/L1 骨架与系统集合。改写请用「策略路由」Override，禁止把用户成员写入 TO_CN / bypass_ip / ext_const。'
			]),
			E('p', { 'class': 'alert-message' }, [ data.dataplane_note || '' ]),

			E('h3', {}, [ '生效摘要' ]),
			E('table', { 'class': 'table' }, [
				row('proxy_mode', data.proxy_mode),
				row('routing_mode', data.routing_mode),
				row('mark 路径', data.mark_path),
				row('bypass_ip 数量', health.bypass_ip_count),
				row('table 2022', health.table_2022 ? '有' : '无/未知'),
				row('快照来源', data.snapshot_source),
				row('旁路提示', data.customer_hosts_hint)
			]),

			E('h3', {}, [ '系统集合（只读）' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '集合' ]), E('th', {}, [ '数量' ]), E('th', {}, [ '写权限' ]), E('th', {}, [ '样例' ])
				]) ]),
				E('tbody', {}, setRows)
			]),

			E('h3', {}, [ '系统默认规则' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '规则' ]), E('th', {}, [ '层' ]), E('th', {}, [ '动作' ]), E('th', {}, [ '覆盖状态' ])
				]) ]),
				defBody
			]),

			E('h3', {}, [ '用户 Override（只读摘要）' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '序' ]), E('th', {}, [ '名称' ]), E('th', {}, [ '动作' ]), E('th', {}, [ '状态' ]), E('th', {}, [ 'ID' ])
				]) ]),
				ovrBody
			]),

			E('h3', {}, [ 'ip rule / table 2022' ]),
			E('pre', { 'style': 'white-space:pre-wrap' }, [ data.ip_rules || '（无）' ]),
			E('pre', { 'style': 'white-space:pre-wrap' }, [ data.table_2022 || '（无）' ]),

			E('h3', {}, [ '冲突试算（只读排障）' ]),
			E('div', { 'class': 'cbi-section' }, [
				probeSrc, ' ', probeDst, ' ', probeDom, ' ', probeBtn, ' ', addOverride,
				probeOut
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
