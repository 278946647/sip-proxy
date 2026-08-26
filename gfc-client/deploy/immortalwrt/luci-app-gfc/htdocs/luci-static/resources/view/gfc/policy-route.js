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

function notifyOk(msg) {
	ui.addNotification(null, E('p', {}, msg));
}

function notifyErr(msg) {
	ui.addNotification(null, E('p', {}, msg), 'danger');
}

function tag(text, color) {
	return E('span', {
		'style': 'display:inline-block;margin:0 4px 2px 0;padding:1px 8px;border-radius:3px;' +
			'font-size:12px;line-height:1.6;background:' + (color || '#e8eef5') + ';color:#1a1a1a'
	}, [ text ]);
}

function actionBadge(a) {
	if (a === 'direct')
		return tag('直连 WAN', '#d4edda');
	if (a === 'proxy')
		return tag('进代理', '#cce5ff');
	return tag(String(a || '-'), '#eee');
}

function statusBadge(s) {
	if (s === 'active')
		return tag('生效', '#d4edda');
	if (s === 'shadowed')
		return tag('被遮蔽', '#fff3cd');
	if (s === 'blocked_by_safety')
		return tag('安全轨拦截', '#f8d7da');
	return tag(s || '-', '#eee');
}

function kindLabel(k) {
	return ({ src_cidr: '源地址', dst_cidr: '目的地址', domain: '域名' })[k] || k;
}

function kindTag(k) {
	var colors = { src_cidr: '#e8f5e9', dst_cidr: '#e3f2fd', domain: '#f3e5f5' };
	return tag(kindLabel(k), colors[k] || '#eee');
}

function groupById(groups, id) {
	if (!id)
		return null;
	for (var i = 0; i < groups.length; i++) {
		if (groups[i].id === id)
			return groups[i];
	}
	return null;
}

function groupLabel(groups, id) {
	var g = groupById(groups, id);
	if (!g)
		return id ? String(id) : '任意';
	return g.name || id;
}

function membersPreview(members, n) {
	n = n || 3;
	members = members || [];
	if (!members.length)
		return '（空）';
	var s = members.slice(0, n).join(', ');
	if (members.length > n)
		s += ' …+' + (members.length - n);
	return s;
}

function policyMatchBlock(p, groups) {
	var lines = [];
	var src = groupById(groups, p.match_src_group_id);
	var dst = groupById(groups, p.match_dst_group_id);
	var dom = groupById(groups, p.match_domain_group_id);

	if (src) {
		lines.push(E('div', {}, [
			tag('源', '#e8f5e9'), ' ', src.name, ' ',
			E('span', { 'style': 'color:#666;font-size:12px' }, [ membersPreview(src.members) ])
		]));
	} else {
		lines.push(E('div', {}, [ tag('源', '#eee'), ' 任意' ]));
	}

	if (dom) {
		lines.push(E('div', { 'style': 'margin-top:3px' }, [
			tag('域名', '#f3e5f5'), ' ', dom.name, ' ',
			E('span', { 'style': 'color:#666;font-size:12px' }, [ membersPreview(dom.members) ])
		]));
	} else if (dst) {
		lines.push(E('div', { 'style': 'margin-top:3px' }, [
			tag('目的', '#e3f2fd'), ' ', dst.name, ' ',
			E('span', { 'style': 'color:#666;font-size:12px' }, [ membersPreview(dst.members) ])
		]));
	} else if (src) {
		lines.push(E('div', { 'style': 'margin-top:3px' }, [
			tag('目的', '#fff3cd'), ' 任意（仅源强制，高危）'
		]));
	} else {
		lines.push(E('div', { 'style': 'margin-top:3px;color:#a00' }, [ '匹配无效' ]));
	}
	return E('div', { 'style': 'line-height:1.5;font-size:13px' }, lines);
}

function option(value, label, selected) {
	return E('option', {
		'value': value,
		'selected': value === selected ? 'selected' : null
	}, [ label ]);
}

function tempId(prefix) {
	return prefix + Math.random().toString(16).slice(2, 10) + Date.now().toString(16).slice(-4);
}

function parseMembers(text) {
	return String(text || '').split(/\r?\n/).map(function(s) {
		return s.trim();
	}).filter(Boolean);
}

function membersText(members) {
	if (!members)
		return '';
	if (typeof members === 'string')
		return members;
	return (members || []).join('\n');
}

function prefillFromQuery() {
	try {
		var q = (window.location.search || '').replace(/^\?/, '');
		var params = {};
		q.split('&').forEach(function(pair) {
			var kv = pair.split('=');
			if (kv[0])
				params[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1] || '');
		});
		return params;
	} catch (e) {
		return {};
	}
}

function renderProbeHuman(body, el) {
	body = body || {};
	while (el.firstChild)
		el.removeChild(el.firstChild);
	el.appendChild(E('div', { 'style': 'margin-bottom:6px' }, [
		tag('获胜层 ' + (body.winner_layer || '-'), '#e8eef5'),
		actionBadge(body.action),
		body.ingress_eligible === false ? tag('不可入向', '#f8d7da') : tag('可入向', '#d4edda')
	]));
	el.appendChild(E('p', { 'style': 'margin:0 0 6px' }, [ body.reason || '' ]));
	if (body.resolve_source || (body.resolved_ips && body.resolved_ips.length)) {
		el.appendChild(E('p', { 'class': 'hint', 'style': 'margin:0' }, [
			(body.resolve_source || 'unbound') + ': ' + (body.resolved_ips || []).join(', ')
		]));
	}
}

return view.extend({
	load: function() {
		return Promise.all([
			get('/policy-routing/groups'),
			get('/policy-routing/policies'),
			get('/settings/proxy-mode'),
			get('/policy-routing/domain-map').catch(function() { return {}; }),
			get('/policy-routing/effective').catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var groupsState = ((((data[0] || {}).data || {}).groups) || []).slice();
		var policiesState = ((((data[1] || {}).data || {}).policies) || []).slice();
		var proxyMode = (((data[2] || {}).data || {}).proxy_mode) || 'gateway';
		var domainMap = ((data[3] || {}).data) || {};
		var effective = ((data[4] || {}).data) || {};
		var prefill = prefillFromQuery();
		var applied = !!effective.dataplane_applied;

		var policyTbody = E('tbody', {});
		var groupTbody = E('tbody', {});
		var result = E('div', { 'class': 'hint' }, []);
		var probeOut = E('div', {}, []);
		var editorPanel = E('div', { 'class': 'cbi-section', 'style': 'display:none;border:1px solid #ddd;padding:12px;margin:10px 0;background:#fafafa' }, []);
		var groupEditor = E('div', { 'class': 'cbi-section', 'style': 'display:none;border:1px solid #ddd;padding:12px;margin:10px 0;background:#fafafa' }, []);

		function refreshPolicyTable() {
			while (policyTbody.firstChild)
				policyTbody.removeChild(policyTbody.firstChild);
			if (!policiesState.length) {
				policyTbody.appendChild(E('tr', {}, [
					E('td', { 'colspan': '7', 'style': 'color:#888' }, [ '暂无规则。点击「添加规则」创建 Override。' ])
				]));
				return;
			}
			policiesState.forEach(function(p, idx) {
				var en = E('input', { 'type': 'checkbox' });
				en.checked = !!p.enabled;
				en.addEventListener('change', function() {
					policiesState[idx].enabled = !!en.checked;
					refreshPolicyTable();
				});
				var ops = E('td', { 'style': 'white-space:nowrap' }, []);
				var up = E('button', { 'class': 'btn cbi-button', 'type': 'button', 'title': '提高优先级' }, [ '↑' ]);
				var down = E('button', { 'class': 'btn cbi-button', 'type': 'button', 'title': '降低优先级' }, [ '↓' ]);
				var edit = E('button', { 'class': 'btn cbi-button cbi-button-edit', 'type': 'button' }, [ '编辑' ]);
				var del = E('button', { 'class': 'btn cbi-button cbi-button-remove', 'type': 'button' }, [ '删除' ]);
				up.addEventListener('click', function() {
					if (idx <= 0) return;
					var t = policiesState[idx - 1];
					policiesState[idx - 1] = policiesState[idx];
					policiesState[idx] = t;
					refreshPolicyTable();
				});
				down.addEventListener('click', function() {
					if (idx >= policiesState.length - 1) return;
					var t = policiesState[idx + 1];
					policiesState[idx + 1] = policiesState[idx];
					policiesState[idx] = t;
					refreshPolicyTable();
				});
				edit.addEventListener('click', function() { openPolicyEditor(idx); });
				del.addEventListener('click', function() {
					policiesState.splice(idx, 1);
					refreshPolicyTable();
				});
				ops.appendChild(up);
				ops.appendChild(document.createTextNode(' '));
				ops.appendChild(down);
				ops.appendChild(document.createTextNode(' '));
				ops.appendChild(edit);
				ops.appendChild(document.createTextNode(' '));
				ops.appendChild(del);

				policyTbody.appendChild(E('tr', {}, [
					E('td', {}, [ en ]),
					E('td', {}, [ tag(String(idx + 1), '#e8eef5') ]),
					E('td', {}, [ p.name || '' ]),
					E('td', {}, [ policyMatchBlock(p, groupsState) ]),
					E('td', {}, [ actionBadge(p.action) ]),
					E('td', {}, [
						statusBadge(p.status),
						p.reason ? E('div', { 'style': 'font-size:11px;color:#666;margin-top:2px;max-width:14em' }, [ p.reason ]) : ''
					]),
					ops
				]));
			});
		}

		function refreshGroupTable() {
			while (groupTbody.firstChild)
				groupTbody.removeChild(groupTbody.firstChild);
			if (!groupsState.length) {
				groupTbody.appendChild(E('tr', {}, [
					E('td', { 'colspan': '5', 'style': 'color:#888' }, [ '暂无地址/域名组。' ])
				]));
				return;
			}
			groupsState.forEach(function(g, idx) {
				var mapHint = '';
				if (g.kind === 'domain' && domainMap.groups && domainMap.groups[g.id]) {
					var dm = domainMap.groups[g.id];
					mapHint = E('div', { 'style': 'font-size:11px;color:#666;margin-top:2px' }, [
						'→ ' + (dm.usr_dom_set || '') + ' · ' + ((dm.ips || []).length) + ' IP'
					]);
				}
				var edit = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '编辑' ]);
				var del = E('button', { 'class': 'btn cbi-button cbi-button-remove', 'type': 'button' }, [ '删除' ]);
				edit.addEventListener('click', function() { openGroupEditor(idx); });
				del.addEventListener('click', function() {
					if ((g.ref_count || 0) > 0) {
						notifyErr('组仍被策略引用，请先解绑');
						return;
					}
					groupsState.splice(idx, 1);
					refreshGroupTable();
					rebuildPolicySelects();
				});
				groupTbody.appendChild(E('tr', {}, [
					E('td', {}, [ g.name || '', mapHint ]),
					E('td', {}, [ kindTag(g.kind) ]),
					E('td', { 'style': 'font-family:monospace;font-size:12px;word-break:break-all' }, [ membersPreview(g.members, 6) ]),
					E('td', {}, [ String(g.ref_count || 0) ]),
					E('td', {}, [ edit, ' ', del ])
				]));
			});
		}

		/* —— policy editor —— */
		var pEnabled = E('input', { 'type': 'checkbox', 'checked': 'checked' });
		var pName = E('input', { 'class': 'cbi-input-text', 'placeholder': '例如：办公网强制代理' });
		var pSrc = E('select', { 'class': 'cbi-input-select' });
		var pDst = E('select', { 'class': 'cbi-input-select' });
		var pDom = E('select', { 'class': 'cbi-input-select' });
		var pAction = E('select', { 'class': 'cbi-input-select' }, [
			option('direct', '直连 WAN', 'direct'),
			option('proxy', '进代理 (gfctun)', 'proxy')
		]);
		var pNotes = E('input', { 'class': 'cbi-input-text', 'placeholder': '备注（可选）' });
		var pDanger = E('input', { 'type': 'checkbox' });
		var pEditId = null;

		function rebuildPolicySelects() {
			function fill(sel, kind, emptyLabel) {
				var cur = sel.value;
				while (sel.firstChild)
					sel.removeChild(sel.firstChild);
				sel.appendChild(option('', emptyLabel, ''));
				groupsState.forEach(function(g) {
					if (g.kind === kind && g.id)
						sel.appendChild(option(g.id, g.name, null));
				});
				sel.value = cur;
			}
			fill(pSrc, 'src_cidr', '（任意源）');
			fill(pDst, 'dst_cidr', '（无目的组）');
			fill(pDom, 'domain', '（无域名组）');
		}

		function hidePolicyEditor() {
			editorPanel.style.display = 'none';
			pEditId = null;
		}

		function openPolicyEditor(idx) {
			rebuildPolicySelects();
			groupEditor.style.display = 'none';
			editorPanel.style.display = '';
			if (idx === null || idx === undefined) {
				pEditId = null;
				pEnabled.checked = true;
				pName.value = prefill.name || '';
				pSrc.value = prefill.match_src_group_id || '';
				pDst.value = prefill.match_dst_group_id || '';
				pDom.value = prefill.match_domain_group_id || '';
				pAction.value = prefill.action || 'direct';
				pNotes.value = '';
				pDanger.checked = false;
			} else {
				var p = policiesState[idx];
				pEditId = p.id || null;
				pEnabled.checked = !!p.enabled;
				pName.value = p.name || '';
				pSrc.value = p.match_src_group_id || '';
				pDst.value = p.match_dst_group_id || '';
				pDom.value = p.match_domain_group_id || '';
				pAction.value = p.action || 'direct';
				pNotes.value = p.notes || '';
				pDanger.checked = !!p.danger_ack;
			}
			editorPanel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
		}

		var savePolicyBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '写入列表' ]);
		savePolicyBtn.addEventListener('click', function() {
			if (pDst.value && pDom.value) {
				notifyErr('目的组与域名组互斥');
				return;
			}
			if (!pSrc.value && !pDst.value && !pDom.value) {
				notifyErr('源与目的/域名不能同时为空');
				return;
			}
			var item = {
				id: pEditId || tempId('ovr_'),
				enabled: !!pEnabled.checked,
				name: pName.value.trim(),
				match_src_group_id: pSrc.value || '',
				match_dst_group_id: pDst.value || '',
				match_domain_group_id: pDom.value || '',
				action: pAction.value,
				danger_ack: !!pDanger.checked,
				notes: pNotes.value.trim()
			};
			if (!item.name) {
				notifyErr('规则名称不能为空');
				return;
			}
			if (pEditId) {
				for (var i = 0; i < policiesState.length; i++) {
					if (policiesState[i].id === pEditId) {
						policiesState[i] = Object.assign({}, policiesState[i], item);
						break;
					}
				}
			} else {
				policiesState.push(item);
			}
			hidePolicyEditor();
			refreshPolicyTable();
		});
		var cancelPolicyBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '取消' ]);
		cancelPolicyBtn.addEventListener('click', hidePolicyEditor);

		editorPanel.appendChild(E('h4', { 'style': 'margin-top:0' }, [ '编辑 Override 规则' ]));
		editorPanel.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '启用 / 名称' ]),
			E('div', { 'class': 'cbi-value-field' }, [ pEnabled, ' ', pName ])
		]));
		editorPanel.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '匹配' ]),
			E('div', { 'class': 'cbi-value-field' }, [
				E('div', {}, [ '源组 ', pSrc ]),
				E('div', { 'style': 'margin-top:6px' }, [ '目的组 ', pDst, ' 或 域名组 ', pDom ])
			])
		]));
		editorPanel.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '动作' ]),
			E('div', { 'class': 'cbi-value-field' }, [ pAction ])
		]));
		editorPanel.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '高危确认' ]),
			E('div', { 'class': 'cbi-value-field' }, [
				pDanger, ' ',
				E('span', { 'class': 'hint' }, [ '仅源匹配，或覆盖系统默认分流时须勾选' ])
			])
		]));
		editorPanel.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '备注' ]),
			E('div', { 'class': 'cbi-value-field' }, [ pNotes ])
		]));
		editorPanel.appendChild(E('div', {}, [ savePolicyBtn, ' ', cancelPolicyBtn ]));

		/* —— group editor —— */
		var gName = E('input', { 'class': 'cbi-input-text', 'placeholder': '显示名' });
		var gKind = E('select', { 'class': 'cbi-input-select' }, [
			option('src_cidr', '源地址组', 'src_cidr'),
			option('dst_cidr', '目的地址组', 'dst_cidr'),
			option('domain', '域名组', 'domain')
		]);
		var gMembers = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:28em;min-height:5em',
			'placeholder': '每行一个 IP/CIDR 或 FQDN'
		});
		var gDesc = E('input', { 'class': 'cbi-input-text', 'placeholder': '备注（可选）' });
		var gEditId = null;

		function hideGroupEditor() {
			groupEditor.style.display = 'none';
			gEditId = null;
		}

		function openGroupEditor(idx) {
			editorPanel.style.display = 'none';
			groupEditor.style.display = '';
			if (idx === null || idx === undefined) {
				gEditId = null;
				gName.value = '';
				gKind.value = 'src_cidr';
				gMembers.value = '';
				gDesc.value = '';
			} else {
				var g = groupsState[idx];
				gEditId = g.id || null;
				gName.value = g.name || '';
				gKind.value = g.kind || 'src_cidr';
				gMembers.value = membersText(g.members);
				gDesc.value = g.description || '';
			}
			groupEditor.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
		}

		var saveGroupBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '写入列表' ]);
		saveGroupBtn.addEventListener('click', function() {
			var item = {
				id: gEditId || tempId('g_'),
				name: gName.value.trim(),
				kind: gKind.value,
				members: parseMembers(gMembers.value),
				description: gDesc.value.trim()
			};
			if (!item.name) {
				notifyErr('组名称不能为空');
				return;
			}
			if (!item.members.length) {
				notifyErr('组成员不能为空');
				return;
			}
			if (gEditId) {
				for (var i = 0; i < groupsState.length; i++) {
					if (groupsState[i].id === gEditId) {
						item.ref_count = groupsState[i].ref_count;
						groupsState[i] = item;
						break;
					}
				}
			} else {
				groupsState.push(item);
			}
			hideGroupEditor();
			refreshGroupTable();
			rebuildPolicySelects();
		});
		var cancelGroupBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '取消' ]);
		cancelGroupBtn.addEventListener('click', hideGroupEditor);

		groupEditor.appendChild(E('h4', { 'style': 'margin-top:0' }, [ '编辑地址 / 域名组' ]));
		groupEditor.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '名称' ]),
			E('div', { 'class': 'cbi-value-field' }, [ gName ])
		]));
		groupEditor.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '类型' ]),
			E('div', { 'class': 'cbi-value-field' }, [ gKind ])
		]));
		groupEditor.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '成员' ]),
			E('div', { 'class': 'cbi-value-field' }, [ gMembers ])
		]));
		groupEditor.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, [ '备注' ]),
			E('div', { 'class': 'cbi-value-field' }, [ gDesc ])
		]));
		groupEditor.appendChild(E('div', {}, [ saveGroupBtn, ' ', cancelGroupBtn ]));

		var addPolicyBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '添加规则' ]);
		addPolicyBtn.addEventListener('click', function() { openPolicyEditor(null); });
		var addGroupBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '添加组' ]);
		addGroupBtn.addEventListener('click', function() { openGroupEditor(null); });

		var saveApplyBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '保存并应用' ]);
		saveApplyBtn.addEventListener('click', function() {
			saveApplyBtn.disabled = true;
			post('/policy-routing/apply', {
				groups: groupsState,
				policies: policiesState
			}).then(function(res) {
				if (res.ok === false) {
					notifyErr((res.error && res.error.message) || '保存失败');
					result.textContent = (res.error && res.error.message) || '失败';
					return;
				}
				var body = res.data || {};
				groupsState = body.groups || groupsState;
				policiesState = body.policies || policiesState;
				if (body.domain_map)
					domainMap = body.domain_map;
				refreshGroupTable();
				rebuildPolicySelects();
				refreshPolicyTable();
				result.textContent = body.dataplane_note || (body.dataplane_applied ? '已应用到数据面' : '已存盘');
				notifyOk(body.dataplane_applied ? '已应用到数据面（usr_* overlay）' : (body.dataplane_note || '已存盘'));
			}).catch(function(err) {
				notifyErr(err.message || String(err));
			}).finally(function() {
				saveApplyBtn.disabled = false;
			});
		});

		var probeSrc = E('input', { 'class': 'cbi-input-text', 'placeholder': '源 IP', 'style': 'width:9em' });
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
					notifyErr((res.error && res.error.message) || '试算失败');
					return;
				}
				renderProbeHuman(res.data || {}, probeOut);
			}).catch(function(err) {
				notifyErr(err.message || String(err));
			}).finally(function() {
				probeBtn.disabled = false;
			});
		});

		rebuildPolicySelects();
		refreshGroupTable();
		refreshPolicyTable();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '策略路由' ]),
			E('p', { 'class': 'hint' }, [
				'用户 Override：列表越靠上优先级越高。动作仅「直连」或「进代理」。当前模式 ',
				tag(proxyMode, '#e8eef5'),
				applied ? tag('Overlay 已应用', '#d4edda') : tag('Overlay 未应用', '#fff3cd')
			]),

			E('h3', {}, [ '冲突试算' ]),
			E('div', { 'class': 'cbi-section' }, [
				probeSrc, ' ', probeDst, ' ', probeDom, ' ', probeBtn,
				probeOut
			]),

			E('h3', {}, [ 'Override 规则' ]),
			E('p', { 'class': 'hint' }, [ '阅读方式同防火墙通信规则：名称 → 匹配条件 → 动作。↑↓ 调整优先级。' ]),
			E('div', { 'style': 'margin-bottom:8px' }, [ addPolicyBtn, ' ', saveApplyBtn ]),
			editorPanel,
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '启用' ]),
					E('th', {}, [ '优先级' ]),
					E('th', {}, [ '名称' ]),
					E('th', {}, [ '匹配条件' ]),
					E('th', {}, [ '动作' ]),
					E('th', {}, [ '状态' ]),
					E('th', {}, [ '操作' ])
				]) ]),
				policyTbody
			]),
			result,

			E('h3', {}, [ '地址组 / 域名组' ]),
			E('div', { 'style': 'margin-bottom:8px' }, [ addGroupBtn ]),
			groupEditor,
			E('table', { 'class': 'table' }, [
				E('thead', {}, [ E('tr', {}, [
					E('th', {}, [ '名称' ]),
					E('th', {}, [ '类型' ]),
					E('th', {}, [ '成员预览' ]),
					E('th', {}, [ '引用' ]),
					E('th', {}, [ '操作' ])
				]) ]),
				groupTbody
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
