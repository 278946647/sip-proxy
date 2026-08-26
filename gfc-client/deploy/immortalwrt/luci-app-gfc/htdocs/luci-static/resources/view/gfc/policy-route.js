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

function val(v) {
	return v === null || v === undefined ? '' : String(v);
}

function membersText(members) {
	if (!members)
		return '';
	if (typeof members === 'string')
		return members;
	return (members || []).join('\n');
}

function parseMembers(text) {
	return String(text || '').split(/\r?\n/).map(function(s) {
		return s.trim();
	}).filter(Boolean);
}

function kindLabel(k) {
	return ({ src_cidr: '源地址组', dst_cidr: '目的地址组', domain: '域名组' })[k] || k;
}

function actionLabel(a) {
	return a === 'direct' ? '直连' : (a === 'proxy' ? '进代理' : a);
}

function statusLabel(s) {
	return ({ active: '生效', shadowed: '被遮蔽', blocked_by_safety: '安全轨拦截' })[s] || (s || '-');
}

function groupName(groups, id) {
	if (!id)
		return '（任意）';
	for (var i = 0; i < groups.length; i++) {
		if (groups[i].id === id)
			return groups[i].name + ' [' + groups[i].id + ']';
	}
	return id;
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

return view.extend({
	load: function() {
		return Promise.all([
			get('/policy-routing/groups'),
			get('/policy-routing/policies'),
			get('/settings/proxy-mode')
		]);
	},

	render: function(data) {
		var groups = (((data[0] || {}).data || {}).groups) || [];
		var policies = (((data[1] || {}).data || {}).policies) || [];
		var proxyMode = (((data[2] || {}).data || {}).proxy_mode) || 'gateway';
		var prefill = prefillFromQuery();
		var result = E('pre', { 'style': 'white-space:pre-wrap;max-height:220px;overflow:auto' }, []);
		var probeOut = E('pre', { 'style': 'white-space:pre-wrap;max-height:260px;overflow:auto' }, []);
		var groupsState = groups.slice();
		var policiesState = policies.slice();

		var groupTbody = E('tbody', {});
		var policyTbody = E('tbody', {});

		function refreshGroupTable() {
			while (groupTbody.firstChild)
				groupTbody.removeChild(groupTbody.firstChild);
			groupsState.forEach(function(g, idx) {
				var tr = E('tr', {}, [
					E('td', {}, [ g.name || '' ]),
					E('td', {}, [ kindLabel(g.kind) ]),
					E('td', { 'style': 'font-family:monospace;font-size:12px;max-width:280px;word-break:break-all' }, [
						(g.members || []).join(', ')
					]),
					E('td', {}, [ String(g.ref_count || 0) ]),
					E('td', {}, [ g.id || '' ]),
					E('td', {}, [
						E('button', { 'class': 'btn cbi-button', 'type': 'button', 'data-i': String(idx) }, [ '编辑' ]),
						' ',
						E('button', { 'class': 'btn cbi-button cbi-button-remove', 'type': 'button', 'data-i': String(idx) }, [ '删除' ])
					])
				]);
				tr.querySelectorAll('button')[0].addEventListener('click', function() {
					editGroup(idx);
				});
				tr.querySelectorAll('button')[1].addEventListener('click', function() {
					if ((g.ref_count || 0) > 0) {
						notifyErr('组仍被策略引用，请先解绑');
						return;
					}
					groupsState.splice(idx, 1);
					refreshGroupTable();
					rebuildPolicySelects();
				});
				groupTbody.appendChild(tr);
			});
		}

		function refreshPolicyTable() {
			while (policyTbody.firstChild)
				policyTbody.removeChild(policyTbody.firstChild);
			policiesState.forEach(function(p, idx) {
				var dest = p.match_domain_group_id
					? ('域名:' + groupName(groupsState, p.match_domain_group_id))
					: groupName(groupsState, p.match_dst_group_id);
				var tr = E('tr', {}, [
					E('td', {}, [ p.enabled ? '是' : '否' ]),
					E('td', {}, [ String(idx + 1) ]),
					E('td', {}, [ p.name || '' ]),
					E('td', {}, [ groupName(groupsState, p.match_src_group_id) ]),
					E('td', {}, [ dest ]),
					E('td', {}, [ actionLabel(p.action) ]),
					E('td', {}, [ statusLabel(p.status) ]),
					E('td', { 'style': 'max-width:220px' }, [ p.reason || '' ]),
					E('td', {}, [
						E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '上移' ]),
						' ',
						E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '下移' ]),
						' ',
						E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '编辑' ]),
						' ',
						E('button', { 'class': 'btn cbi-button cbi-button-remove', 'type': 'button' }, [ '删除' ])
					])
				]);
				var btns = tr.querySelectorAll('button');
				btns[0].addEventListener('click', function() {
					if (idx <= 0) return;
					var tmp = policiesState[idx - 1];
					policiesState[idx - 1] = policiesState[idx];
					policiesState[idx] = tmp;
					refreshPolicyTable();
				});
				btns[1].addEventListener('click', function() {
					if (idx >= policiesState.length - 1) return;
					var tmp = policiesState[idx + 1];
					policiesState[idx + 1] = policiesState[idx];
					policiesState[idx] = tmp;
					refreshPolicyTable();
				});
				btns[2].addEventListener('click', function() { editPolicy(idx); });
				btns[3].addEventListener('click', function() {
					policiesState.splice(idx, 1);
					refreshPolicyTable();
				});
				policyTbody.appendChild(tr);
			});
		}

		var gName = E('input', { 'class': 'cbi-input-text', 'placeholder': '显示名' });
		var gKind = E('select', { 'class': 'cbi-input-select' }, [
			option('src_cidr', '源地址组 (src_cidr)', 'src_cidr'),
			option('dst_cidr', '目的地址组 (dst_cidr)', 'dst_cidr'),
			option('domain', '域名组 (domain)', 'domain')
		]);
		var gMembers = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:28em;min-height:5em',
			'placeholder': '每行一个 IP/CIDR 或 FQDN'
		});
		var gDesc = E('input', { 'class': 'cbi-input-text', 'placeholder': '备注（可选）' });
		var gEditId = null;

		function resetGroupForm() {
			gEditId = null;
			gName.value = '';
			gKind.value = 'src_cidr';
			gMembers.value = '';
			gDesc.value = '';
		}

		function editGroup(idx) {
			var g = groupsState[idx];
			gEditId = g.id || null;
			gName.value = g.name || '';
			gKind.value = g.kind || 'src_cidr';
			gMembers.value = membersText(g.members);
			gDesc.value = g.description || '';
		}

		var addGroupBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '加入列表' ]);
		addGroupBtn.addEventListener('click', function() {
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
			resetGroupForm();
			refreshGroupTable();
			rebuildPolicySelects();
		});

		var pEnabled = E('input', { 'type': 'checkbox', 'checked': 'checked' });
		var pName = E('input', { 'class': 'cbi-input-text', 'placeholder': '规则名称' });
		var pSrc = E('select', { 'class': 'cbi-input-select' });
		var pDst = E('select', { 'class': 'cbi-input-select' });
		var pDom = E('select', { 'class': 'cbi-input-select' });
		var pAction = E('select', { 'class': 'cbi-input-select' }, [
			option('direct', '直连 (direct)', 'direct'),
			option('proxy', '进代理 (proxy)', 'proxy')
		]);
		var pNotes = E('input', { 'class': 'cbi-input-text', 'placeholder': '备注（可选）' });
		var pDanger = E('input', { 'type': 'checkbox' });
		var pDangerHint = E('div', { 'class': 'hint' }, [
			'仅源匹配或覆盖系统默认时须勾选确认。仅源：该源访问任意目的将强制直连/进代理。'
		]);
		var pEditId = null;

		function rebuildPolicySelects() {
			function fill(sel, kind, emptyLabel) {
				while (sel.firstChild)
					sel.removeChild(sel.firstChild);
				sel.appendChild(option('', emptyLabel, ''));
				groupsState.forEach(function(g) {
					if (g.kind === kind && g.id)
						sel.appendChild(option(g.id, g.name + ' [' + g.id + ']', null));
				});
			}
			var srcVal = pSrc.value, dstVal = pDst.value, domVal = pDom.value;
			fill(pSrc, 'src_cidr', '（任意源）');
			fill(pDst, 'dst_cidr', '（无目的组）');
			fill(pDom, 'domain', '（无域名组）');
			pSrc.value = srcVal;
			pDst.value = dstVal;
			pDom.value = domVal;
		}

		function resetPolicyForm() {
			pEditId = null;
			pEnabled.checked = true;
			pName.value = prefill.name || '';
			pSrc.value = prefill.match_src_group_id || '';
			pDst.value = prefill.match_dst_group_id || '';
			pDom.value = prefill.match_domain_group_id || '';
			pAction.value = prefill.action || 'direct';
			pNotes.value = '';
			pDanger.checked = false;
		}

		function editPolicy(idx) {
			var p = policiesState[idx];
			pEditId = p.id || null;
			pEnabled.checked = !!p.enabled;
			pName.value = p.name || '';
			rebuildPolicySelects();
			pSrc.value = p.match_src_group_id || '';
			pDst.value = p.match_dst_group_id || '';
			pDom.value = p.match_domain_group_id || '';
			pAction.value = p.action || 'direct';
			pNotes.value = p.notes || '';
			pDanger.checked = !!p.danger_ack;
		}

		var addPolicyBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, [ '加入规则表' ]);
		addPolicyBtn.addEventListener('click', function() {
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
			resetPolicyForm();
			refreshPolicyTable();
		});

		var saveApplyBtn = E('button', { 'class': 'btn cbi-button cbi-button-apply', 'type': 'button' }, [ '保存并应用' ]);
		saveApplyBtn.addEventListener('click', function() {
			saveApplyBtn.disabled = true;
			post('/policy-routing/apply', {
				groups: groupsState,
				policies: policiesState
			}).then(function(res) {
				if (res.ok === false) {
					notifyErr((res.error && res.error.message) || '保存失败');
					result.textContent = JSON.stringify(res, null, 2);
					return;
				}
				var body = res.data || {};
				groupsState = body.groups || groupsState;
				policiesState = body.policies || policiesState;
				refreshGroupTable();
				rebuildPolicySelects();
				refreshPolicyTable();
				result.textContent = JSON.stringify(body, null, 2);
				notifyOk(body.dataplane_applied ? '已应用到数据面（usr_* overlay）' : ((body.dataplane_note) || '已存盘，数据面未应用'));
			}).catch(function(err) {
				notifyErr(err.message || String(err));
			}).finally(function() {
				saveApplyBtn.disabled = false;
			});
		});

		var probeSrc = E('input', { 'class': 'cbi-input-text', 'placeholder': '源 IP（可选）' });
		var probeDst = E('input', { 'class': 'cbi-input-text', 'placeholder': '目的 IP' });
		var probeDom = E('input', { 'class': 'cbi-input-text', 'placeholder': '或域名（与目的互斥）' });
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
					notifyErr((res.error && res.error.message) || '试算失败');
				else
					notifyOk('试算完成');
			}).catch(function(err) {
				notifyErr(err.message || String(err));
			}).finally(function() {
				probeBtn.disabled = false;
			});
		});

		rebuildPolicySelects();
		resetGroupForm();
		resetPolicyForm();
		refreshGroupTable();
		refreshPolicyTable();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ '策略路由' ]),
			E('p', { 'class': 'hint' }, [
				'L2 用户 Override：列表越靠上优先级越高。动作仅 direct / proxy（复用 0x2023→2022→gfctun）。当前 proxy_mode=',
				proxyMode,
				'。系统集合请看「系统分流规则」。'
			]),

			E('h3', {}, [ '冲突试算' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '源 / 目的 / 域名' ]),
					E('div', { 'class': 'cbi-value-field' }, [ probeSrc, ' ', probeDst, ' ', probeDom, ' ', probeBtn ])
				]),
				probeOut
			]),

			E('h3', {}, [ '地址组 / 域名组' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, [ '名称' ]), E('div', { 'class': 'cbi-value-field' }, [ gName ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, [ '类型' ]), E('div', { 'class': 'cbi-value-field' }, [ gKind ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, [ '成员' ]), E('div', { 'class': 'cbi-value-field' }, [ gMembers ]) ]),
				E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, [ '备注' ]), E('div', { 'class': 'cbi-value-field' }, [ gDesc ]) ]),
				E('div', {}, [ addGroupBtn ]),
				E('table', { 'class': 'table' }, [
					E('thead', {}, [ E('tr', {}, [
						E('th', {}, [ '名称' ]), E('th', {}, [ '类型' ]),
						E('th', {}, [ '成员' ]), E('th', {}, [ '引用' ]), E('th', {}, [ 'ID' ]), E('th', {}, [ '操作' ])
					]) ]),
					groupTbody
				])
			]),

			E('h3', {}, [ '策略规则（Override）' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '启用 / 名称' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pEnabled, ' ', pName ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '源组' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pSrc ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '目的组' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pDst ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '域名组' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pDom ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '动作' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pAction ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '高危确认' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pDanger, ' ', pDangerHint ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '备注' ]),
					E('div', { 'class': 'cbi-value-field' }, [ pNotes ])
				]),
				E('div', {}, [ addPolicyBtn, ' ', saveApplyBtn ]),
				E('table', { 'class': 'table' }, [
					E('thead', {}, [ E('tr', {}, [
						E('th', {}, [ '启用' ]), E('th', {}, [ '优先级序' ]), E('th', {}, [ '名称' ]),
						E('th', {}, [ '源组' ]), E('th', {}, [ '目的/域名组' ]), E('th', {}, [ '动作' ]),
						E('th', {}, [ '状态' ]), E('th', {}, [ '原因' ]), E('th', {}, [ '操作' ])
					]) ]),
					policyTbody
				])
			]),

			E('h3', {}, [ '应用结果' ]),
			result
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
