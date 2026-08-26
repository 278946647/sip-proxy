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

function tag(text, color) {
	return E('span', {
		'style': 'display:inline-block;margin:0 4px 2px 0;padding:1px 8px;border-radius:3px;' +
			'font-size:12px;line-height:1.6;background:' + (color || '#e8eef5') + ';color:#1a1a1a'
	}, [ text ]);
}

function actionBadge(action) {
	if (action === 'direct' || action === '直连')
		return tag('直连 WAN', '#d4edda');
	if (action === 'proxy' || action === '进代理')
		return tag('进代理 (0x2023)', '#cce5ff');
	return tag(String(action || '-'), '#eee');
}

function layerBadge(layer) {
	var map = {
		safety_rail: [ '安全轨', '#f8d7da' ],
		system_default: [ '系统默认', '#fff3cd' ],
		user_override: [ '用户覆盖', '#d1ecf1' ]
	};
	var m = map[layer] || [ layer || '-', '#eee' ];
	return tag(m[0], m[1]);
}

function statusBadge(ok, okText, badText) {
	return ok ? tag(okText || '正常', '#d4edda') : tag(badText || '异常', '#f8d7da');
}

function matchBlock(lines) {
	return E('div', { 'style': 'line-height:1.55;font-size:13px' }, lines.map(function(line, i) {
		return E('div', { 'style': i ? 'margin-top:2px;color:#444' : 'color:#222' }, [ line ]);
	}));
}

function sampleShort(arr, n) {
	n = n || 4;
	if (!arr || !arr.length)
		return '（空）';
	var s = arr.slice(0, n).join(', ');
	if (arr.length > n)
		s += ' …共' + arr.length;
	return s;
}

function humanDefaultMatch(r) {
	var id = r.id || '';
	if (id.indexOf('bypass') >= 0)
		return matchBlock([ '入站 / 本机出站', '目的 ∈ ', tag('bypass_ip', '#fde2e1'), '（节点/控制器等）' ]);
	if (id.indexOf('rfc') >= 0)
		return matchBlock([ '入站 / 本机出站', '目的 ∈ RFC1918 / 本机' ]);
	if (id.indexOf('ext_const') >= 0)
		return matchBlock([ '入站分类', '目的 ∈ ', tag('ext_const', '#e8eef5'), '（国际 DNS 等）' ]);
	if (id.indexOf('to_cn') >= 0 || id.indexOf('TO_CN') >= 0 || (r.name || '').indexOf('TO_CN') >= 0)
		return matchBlock([ '入站分类（分流模式）', '目的 ∈ ', tag('TO_CN', '#e8eef5'), ' 中国 IP 库' ]);
	return matchBlock([ '入站分类 catch-all', '未命中以上集合' ]);
}

function renderProbeHuman(body, el) {
	body = body || {};
	while (el.firstChild)
		el.removeChild(el.firstChild);
	if (!body.winner_layer && !body.action) {
		el.appendChild(E('pre', { 'style': 'white-space:pre-wrap;font-size:12px' }, [ JSON.stringify(body, null, 2) ]));
		return;
	}
	el.appendChild(E('div', { 'style': 'margin-bottom:8px' }, [
		tag('获胜: ' + (body.winner_layer || '-'), '#e8eef5'),
		actionBadge(body.action),
		body.ingress_eligible === false ? tag('不可入向', '#f8d7da') : tag('可入向', '#d4edda')
	]));
	el.appendChild(E('p', { 'style': 'margin:0 0 8px;color:#333' }, [ body.reason || body.ingress_reason || '' ]));
	if (body.ingress_reason && body.reason !== body.ingress_reason)
		el.appendChild(E('p', { 'class': 'hint', 'style': 'margin:0 0 8px' }, [ body.ingress_reason ]));
	if (body.resolved_ips && body.resolved_ips.length)
		el.appendChild(E('p', { 'class': 'hint' }, [ 'unbound 解析: ' + body.resolved_ips.join(', ') ]));
	var chain = body.chain || [];
	if (chain.length) {
		var ol = E('ol', { 'style': 'margin:6px 0 0;padding-left:1.4em;font-size:13px' });
		chain.forEach(function(h) {
			ol.appendChild(E('li', {}, [
				layerBadge(h.layer),
				' ',
				h.matched ? tag('命中', '#d4edda') : tag('未命中', '#eee'),
				' ',
				h.name || h.id || '',
				h.action ? (' → ' + h.action) : '',
				h.reason ? E('span', { 'style': 'color:#666' }, [ ' — ' + h.reason ]) : ''
			]));
		});
		el.appendChild(ol);
	}
}

return view.extend({
	load: function() {
		return Promise.all([
			get('/policy-routing/system-rules'),
			get('/policy-routing/domain-map').catch(function() { return {}; })
		]);
	},

	render: function(pack) {
		var data = ((pack[0] || {}).data) || {};
		var domainMap = ((pack[1] || {}).data) || data.domain_map || {};
		var sets = data.sets || {};
		var defaults = data.default_rules || [];
		var overrides = data.user_overrides || [];
		var health = data.safety_rail_health || {};
		var applied = !!data.dataplane_applied;

		var probeOut = E('div', { 'class': 'cbi-section', 'style': 'min-height:2em' }, []);

		/* —— 状态条 —— */
		var statusBar = E('div', {
			'class': 'alert-message ' + (applied ? '' : 'warning'),
			'style': 'display:flex;flex-wrap:wrap;gap:8px;align-items:center'
		}, [
			applied ? statusBadge(true, '用户 Overlay 已应用') : statusBadge(false, null, '用户 Overlay 未应用'),
			tag('模式 ' + (data.proxy_mode || '-'), '#e8eef5'),
			tag(data.routing_mode === 'global' ? '全局' : '分流', '#e8eef5'),
			tag(data.mark_path || '0x2023 → 2022 → gfctun', '#e8eef5'),
			statusBadge(!!health.table_2022, 'table 2022 正常', 'table 2022 缺失'),
			tag('bypass_ip ×' + (health.bypass_ip_count || 0), '#fde2e1')
		]);
		if (data.dataplane_note)
			statusBar.appendChild(E('div', { 'style': 'flex-basis:100%;font-size:12px;color:#555;margin-top:4px' }, [ data.dataplane_note ]));

		/* —— 裁决顺序（核心，像防火墙规则表） —— */
		var ruleBody = E('tbody', {});
		defaults.forEach(function(r, idx) {
			var cover = r.covered_by
				? E('span', {}, [ tag('可被用户覆盖', '#fff3cd'), ' → 策略路由 #' + (r.covered_by_name || r.covered_by) ])
				: tag('固定', '#eee');
			ruleBody.appendChild(E('tr', {}, [
				E('td', {}, [ String(idx + 1) ]),
				E('td', {}, [ r.name || r.id ]),
				E('td', {}, [ humanDefaultMatch(r) ]),
				E('td', {}, [ actionBadge(r.action) ]),
				E('td', {}, [ layerBadge(r.layer) ]),
				E('td', {}, [ cover ])
			]));
		});

		/* —— 用户覆盖摘要 —— */
		var ovrBody = E('tbody', {});
		if (!overrides.length) {
			ovrBody.appendChild(E('tr', {}, [
				E('td', { 'colspan': '5', 'style': 'color:#888' }, [ '暂无用户 Override。请到「策略路由」添加。' ])
			]));
		} else {
			overrides.forEach(function(p, idx) {
				ovrBody.appendChild(E('tr', {}, [
					E('td', {}, [ String(idx + 1) ]),
					E('td', {}, [ p.name || '' ]),
					E('td', {}, [ actionBadge(p.action) ]),
					E('td', {}, [ tag(p.status === 'active' ? '生效' : (p.status || '-'), p.status === 'active' ? '#d4edda' : '#eee') ]),
					E('td', { 'style': 'font-family:monospace;font-size:12px' }, [ p.id || '' ])
				]));
			});
		}

		/* —— 系统集合 —— */
		var setOrder = [ 'bypass_ip', 'TO_CN', 'ext_const', 'ext' ];
		var setBody = E('tbody', {});
		setOrder.forEach(function(k) {
			var s = sets[k];
			if (!s) return;
			var role = ({
				bypass_ip: '安全轨：节点/控制器，禁止用户改成进代理',
				TO_CN: '国内直连库（合并更新，用户勿写入）',
				ext_const: '国际 DNS 等常量 → 进代理',
				ext: '动态国际目的（timeout）'
			})[k] || '';
			setBody.appendChild(E('tr', {}, [
				E('td', {}, [ tag(s.name || k, '#e8eef5') ]),
				E('td', {}, [ String(s.count || 0) ]),
				E('td', {}, [ s.writable === 'system_merge_only' ? tag('系统合并', '#fff3cd') : tag('只读', '#eee') ]),
				E('td', { 'style': 'font-size:12px;color:#555' }, [ role ]),
				E('td', { 'style': 'font-family:monospace;font-size:12px;word-break:break-all' }, [ sampleShort(s.sample, 3) ])
			]));
		});

		/* —— 域名映射 —— */
		var domGroups = (domainMap && domainMap.groups) ? domainMap.groups : {};
		var domKeys = Object.keys(domGroups);
		var domBody = E('tbody', {});
		if (!domKeys.length) {
			domBody.appendChild(E('tr', {}, [
				E('td', { 'colspan': '4', 'style': 'color:#888' }, [ '尚无域名组映射。在策略路由创建域名组并「保存并应用」后，经 unbound:53 解析写入。' ])
			]));
		} else {
			domKeys.forEach(function(id) {
				var g = domGroups[id] || {};
				var pairs = [];
				var domains = g.domains || {};
				Object.keys(domains).forEach(function(d) {
					var e = domains[d] || {};
					pairs.push(d + ' → ' + ((e.ips && e.ips.length) ? e.ips.join(',') : (e.error || '未解析')));
				});
				domBody.appendChild(E('tr', {}, [
					E('td', {}, [ g.group_name || id ]),
					E('td', { 'style': 'font-family:monospace;font-size:12px' }, [ g.usr_dom_set || '' ]),
					E('td', {}, [ String((g.ips || []).length) ]),
					E('td', { 'style': 'font-size:12px;word-break:break-all' }, [ pairs.join('；') || sampleShort(g.ips, 6) ])
				]));
			});
		}

		var probeSrc = E('input', { 'class': 'cbi-input-text', 'placeholder': '源 IP（可选）', 'style': 'width:9em' });
		var probeDst = E('input', { 'class': 'cbi-input-text', 'placeholder': '目的 IP', 'style': 'width:9em' });
		var probeDom = E('input', { 'class': 'cbi-input-text', 'placeholder': '或域名', 'style': 'width:12em' });
		var probeBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '试算' ]);
		probeBtn.addEventListener('click', function() {
			probeBtn.disabled = true;
			post('/policy-routing/probe', {
				probe_src: probeSrc.value.trim(),
				probe_dst: probeDst.value.trim(),
				probe_domain: probeDom.value.trim()
			}).then(function(res) {
				if (res.ok === false) {
					ui.addNotification(null, E('p', {}, (res.error && res.error.message) || '试算失败'), 'danger');
					probeOut.textContent = '';
					return;
				}
				renderProbeHuman(res.data || {}, probeOut);
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
			}).finally(function() {
				probeBtn.disabled = false;
			});
		});

		var goPolicy = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '去策略路由添加覆盖' ]);
		goPolicy.addEventListener('click', function() {
			window.location = L.url('admin/gfc/config/policy-route');
		});

		var adv = E('details', {}, [
			E('summary', { 'style': 'cursor:pointer;margin:8px 0' }, [ '高级：ip rule / table 2022 原文' ]),
			E('pre', { 'style': 'white-space:pre-wrap;font-size:12px;background:#f7f7f7;padding:8px' }, [ data.ip_rules || '（无）' ]),
			E('pre', { 'style': 'white-space:pre-wrap;font-size:12px;background:#f7f7f7;padding:8px' }, [ data.table_2022 || '（无）' ])
		]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '系统 nft 规则' ]),
			E('p', { 'class': 'hint' }, [
				'只读查看内核分类链（inet gfc）的生效顺序。改写请用「策略路由」；禁止把用户成员写入 TO_CN / bypass_ip / ext_const。'
			]),
			statusBar,

			E('h3', {}, [ '分类裁决顺序（先匹配先生效）' ]),
			E('p', { 'class': 'hint' }, [ '与 OpenWrt 通信规则类似：自上而下阅读即可理解流量如何分流。' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', { 'style': 'width:3em' }, [ '#' ]),
					E('th', {}, [ '名称' ]),
					E('th', {}, [ '匹配条件' ]),
					E('th', {}, [ '动作' ]),
					E('th', {}, [ '层级' ]),
					E('th', {}, [ '说明' ])
				]) ]),
				ruleBody
			]),

			E('div', { 'style': 'margin:12px 0' }, [ goPolicy ]),

			E('h3', {}, [ '用户 Override（摘要）' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '优先级' ]), E('th', {}, [ '名称' ]), E('th', {}, [ '动作' ]),
					E('th', {}, [ '状态' ]), E('th', {}, [ 'ID' ])
				]) ]),
				ovrBody
			]),

			E('h3', {}, [ '系统集合' ]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '集合' ]), E('th', {}, [ '数量' ]), E('th', {}, [ '写权限' ]),
					E('th', {}, [ '作用' ]), E('th', {}, [ '样例' ])
				]) ]),
				setBody
			]),

			E('h3', {}, [ '域名组 → IP（unbound:53）' ]),
			E('p', { 'class': 'hint' }, [
				'解析出口遵循 unbound 中外分流；映射供 usr_dom_* 匹配。resolver=',
				(domainMap.resolver || 'unbound:53'),
				domainMap.updated_at ? (' · 更新 ' + domainMap.updated_at) : ''
			]),
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '组' ]), E('th', {}, [ 'nft set' ]), E('th', {}, [ 'IP 数' ]), E('th', {}, [ '域名 → IP' ])
				]) ]),
				domBody
			]),

			E('h3', {}, [ '冲突试算' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'margin-bottom:8px' }, [
					probeSrc, ' ', probeDst, ' ', probeDom, ' ', probeBtn
				]),
				probeOut
			]),

			adv
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
