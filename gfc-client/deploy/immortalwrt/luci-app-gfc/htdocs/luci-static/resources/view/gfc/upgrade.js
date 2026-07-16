'use strict';
'require view';
'require fs';
'require ui';

var API = 'http://127.0.0.1:8080/api/v1';
var pollTimer = null;

function request(path, body, timeoutSec) {
	var args = [ '-qO-', '-T', String(timeoutSec || 30) ];
	if (body !== undefined) {
		args.push('--header=Content-Type: application/json');
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(API + path);
	return fs.exec('/usr/bin/wget', args).then(function(res) {
		var raw = res.stdout || '{}';
		try {
			return JSON.parse(raw);
		} catch (e) {
			throw new Error(raw || e.message);
		}
	});
}

function unwrap(res) {
	return (res && res.data) ? res.data : (res || {});
}

function phaseLabel(phase) {
	var map = {
		idle: '空闲',
		checking: '检查中',
		downloading: '下载中',
		extracting: '解压中',
		installing: '安装中',
		done: '完成',
		failed: '失败'
	};
	return map[phase] || phase || '-';
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			request('/upgrade/status'),
			request('/upgrade/artifacts').catch(function() { return { data: { artifacts: [] } }; })
		]);
	},

	render: function(data) {
		var self = this;
		var st = unwrap(data[0]);
		var artsWrap = unwrap(data[1]);
		var artifacts = artsWrap.artifacts || [];

		var wrap = E('div', { 'class': 'cbi-map' });
		wrap.appendChild(E('h2', {}, [ _('系统版本升级') ]));
		wrap.appendChild(E('p', { 'class': 'cbi-map-descr' }, [
			_('从控制平台拉取 runtime；也可上传本地包（线下拷贝场景）。')
		]));

		var curEl = E('td', {}, [ String(st.current || '-') ]);
		var latestEl = E('td', {}, [ String(st.platform_latest || st.latest || '-') ]);
		var statusEl = E('td', {}, [ phaseLabel(st.phase || st.status_text) ]);

		wrap.appendChild(E('table', { 'class': 'table' }, [
			E('tr', {}, [ E('td', { 'class': 'th' }, [ _('当前版本') ]), curEl ]),
			E('tr', {}, [ E('td', { 'class': 'th' }, [ _('平台最新') ]), latestEl ]),
			E('tr', {}, [ E('td', { 'class': 'th' }, [ _('升级状态') ]), statusEl ])
		]));

		/* ---- Platform section ---- */
		var select = E('select', { 'style': 'min-width:280px;max-width:100%' });
		function fillSelect(list, preferredId) {
			while (select.firstChild)
				select.removeChild(select.firstChild);
			if (!list || !list.length) {
				select.appendChild(E('option', { 'value': '' }, [ _('（无可用制品，请先检查更新）') ]));
				return;
			}
			list.forEach(function(a) {
				var label = a.version + ' / ' + a.arch + ' (#' + a.id + ')';
				if (a.notes)
					label += ' — ' + a.notes;
				var opt = E('option', { 'value': String(a.id) }, [ label ]);
				if (preferredId && String(a.id) === String(preferredId))
					opt.selected = true;
				select.appendChild(opt);
			});
		}
		fillSelect(artifacts);

		var bar = E('div', {
			'style': 'height:14px;background:#e8e8e8;border-radius:7px;overflow:hidden;margin-top:10px'
		}, [
			E('div', {
				'id': 'gfc-upgrade-bar',
				'style': 'height:100%;width:0%;background:#337ab7;transition:width .2s'
			})
		]);
		var resultPre = E('pre', {
			'style': 'white-space:pre-wrap;margin-top:10px;max-height:240px;overflow:auto;background:#f5f5f5;padding:10px;border-radius:6px'
		}, [ st.last_result || '' ]);

		function setProgress(p) {
			p = p || {};
			var pct = Number(p.percent || 0);
			var barInner = bar.firstChild;
			if (barInner)
				barInner.style.width = pct + '%';
			statusEl.textContent = phaseLabel(p.phase) + (p.message ? (' — ' + p.message) : '');
			if (p.last_result)
				resultPre.textContent = p.last_result;
			else if (p.message && (p.phase === 'done' || p.phase === 'failed'))
				resultPre.textContent = p.message;
		}
		setProgress(st.progress || st);

		function stopPoll() {
			if (pollTimer) {
				window.clearInterval(pollTimer);
				pollTimer = null;
			}
		}

		function refreshStatus() {
			return request('/upgrade/status').then(function(res) {
				var d = unwrap(res);
				curEl.textContent = String(d.current || '-');
				latestEl.textContent = String(d.platform_latest || d.latest || '-');
				setProgress(d.progress || d);
				return d;
			});
		}

		function startPoll() {
			stopPoll();
			pollTimer = window.setInterval(function() {
				refreshStatus().then(function(d) {
					if (!d.busy && d.phase !== 'downloading' && d.phase !== 'extracting' &&
						d.phase !== 'installing' && d.phase !== 'checking') {
						stopPoll();
						checkBtn.disabled = false;
						upgradeBtn.disabled = false;
						localBtn.disabled = false;
						uploadBtn.disabled = false;
						if (d.phase === 'done')
							ui.addNotification(null, E('p', {}, _('升级完成，建议重启 gfc-agent / 相关服务')));
						else if (d.phase === 'failed')
							ui.addNotification(null, E('p', {}, d.last_result || _('升级失败')), 'danger');
					}
				}).catch(function() {});
			}, 1500);
		}

		var checkBtn = E('button', { 'class': 'btn cbi-button' }, [ _('检查更新') ]);
		checkBtn.addEventListener('click', function() {
			checkBtn.disabled = true;
			resultPre.textContent = 'checking...';
			request('/upgrade/check', {}, 45).then(function(res) {
				var d = unwrap(res);
				fillSelect(d.artifacts || []);
				curEl.textContent = String(d.current || '-');
				latestEl.textContent = String(d.latest || '-');
				statusEl.textContent = d.update_available ? _('有可用更新') : _('已是最新或无制品');
				resultPre.textContent = JSON.stringify({
					current: d.current,
					latest: d.latest,
					update_available: d.update_available,
					artifacts: (d.artifacts || []).length
				}, null, 2);
				ui.addNotification(null, E('p', {}, _('已检查控制平台制品库')));
			}).catch(function(err) {
				resultPre.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, resultPre.textContent), 'danger');
			}).finally(function() {
				checkBtn.disabled = false;
			});
		});

		var upgradeBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ _('立即升级') ]);
		upgradeBtn.addEventListener('click', function() {
			var id = parseInt(select.value, 10);
			if (!id) {
				ui.addNotification(null, E('p', {}, _('请先检查更新并选择版本')), 'warning');
				return;
			}
			upgradeBtn.disabled = true;
			checkBtn.disabled = true;
			resultPre.textContent = 'starting platform upgrade...';
			request('/upgrade/apply-remote', { artifact_id: id }, 20).then(function(res) {
				setProgress(unwrap(res).progress || { phase: 'checking', percent: 5, message: 'started' });
				startPoll();
			}).catch(function(err) {
				resultPre.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, resultPre.textContent), 'danger');
				upgradeBtn.disabled = false;
				checkBtn.disabled = false;
			});
		});

		wrap.appendChild(E('div', {
			'class': 'cbi-section',
			'style': 'margin-top:18px;padding:14px;border:1px solid #ddd;border-radius:8px'
		}, [
			E('h3', {}, [ _('从控制平台升级') ]),
			E('p', {}, [ _('可用版本来自控制台「系统设置 → 升级制品」。') ]),
			E('div', { 'style': 'margin:8px 0' }, [ select ]),
			E('div', { 'style': 'margin-top:8px' }, [ checkBtn, ' ', upgradeBtn ]),
			bar,
			resultPre
		]));

		/* ---- Local upload section ---- */
		var fileInput = E('input', {
			'type': 'file',
			'accept': '.tar.gz,.tgz,.gz,application/gzip'
		});
		var pathInput = E('input', {
			'type': 'text',
			'style': 'width:100%;max-width:480px;margin-top:8px',
			'placeholder': '/tmp/gfc-immortalwrt-runtime-....tar.gz'
		});
		var localResult = E('pre', {
			'style': 'white-space:pre-wrap;margin-top:10px;max-height:200px;overflow:auto;background:#f5f5f5;padding:10px;border-radius:6px'
		}, []);

		var localBar = E('div', {
			'style': 'height:14px;background:#e8e8e8;border-radius:7px;overflow:hidden;margin-top:10px'
		}, [
			E('div', { 'style': 'height:100%;width:0%;background:#5cb85c;transition:width .2s' })
		]);

		function setLocalBar(pct) {
			localBar.firstChild.style.width = Number(pct || 0) + '%';
		}

		var localBtn = E('button', { 'class': 'btn cbi-button' }, [ _('安装本地路径包') ]);
		localBtn.addEventListener('click', function() {
			var p = (pathInput.value || '').trim();
			if (!p) {
				ui.addNotification(null, E('p', {}, _('请填写包路径或先上传文件')), 'warning');
				return;
			}
			localBtn.disabled = true;
			uploadBtn.disabled = true;
			localResult.textContent = 'starting...';
			request('/upgrade/apply-local', { path: p }, 20).then(function() {
				startPoll();
				pollTimer && refreshStatus().then(function(d) {
					setLocalBar(d.percent);
					localResult.textContent = d.last_result || d.status_text || JSON.stringify(d.progress || d, null, 2);
				});
			}).catch(function(err) {
				localResult.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, localResult.textContent), 'danger');
				localBtn.disabled = false;
				uploadBtn.disabled = false;
			});
		});

		var uploadBtn = E('button', { 'class': 'btn cbi-button cbi-button-action' }, [ _('上传并安装') ]);
		uploadBtn.addEventListener('click', function() {
			var file = fileInput.files && fileInput.files[0];
			if (!file) {
				ui.addNotification(null, E('p', {}, _('请选择 .tar.gz 文件')), 'warning');
				return;
			}
			uploadBtn.disabled = true;
			localBtn.disabled = true;
			localResult.textContent = 'uploading ' + file.name + '...';
			setLocalBar(5);

			/* LuCI cgi-upload → /tmp，再交给 gfc-api 异步安装 */
			ui.uploadFile('/cgi-bin/cgi-upload', file, function(loaded, total) {
				if (total > 0)
					setLocalBar(Math.min(40, Math.round(loaded * 40 / total)));
			}).then(function(meta) {
				var tmpPath = (meta && (meta.name || meta.tmppath || meta.path)) || '';
				if (!tmpPath) {
					throw new Error('upload failed: no temp path');
				}
				pathInput.value = tmpPath;
				localResult.textContent = 'uploaded to ' + tmpPath + ', installing...';
				setLocalBar(45);
				return request('/upgrade/apply-local', { path: tmpPath }, 20);
			}).then(function() {
				startPoll();
				var localPoll = window.setInterval(function() {
					refreshStatus().then(function(d) {
						setLocalBar(d.percent || 0);
						localResult.textContent = d.last_result || d.status_text || '';
						resultPre.textContent = localResult.textContent;
						if (!d.busy) {
							window.clearInterval(localPoll);
							uploadBtn.disabled = false;
							localBtn.disabled = false;
						}
					}).catch(function() {});
				}, 1500);
			}).catch(function(err) {
				localResult.textContent = err.message || String(err);
				ui.addNotification(null, E('p', {}, localResult.textContent), 'danger');
				uploadBtn.disabled = false;
				localBtn.disabled = false;
			});
		});

		wrap.appendChild(E('div', {
			'class': 'cbi-section',
			'style': 'margin-top:18px;padding:14px;border:1px solid #ddd;border-radius:8px'
		}, [
			E('h3', {}, [ _('本地包升级（高级）') ]),
			E('p', {}, [ _('选择 .tar.gz 上传到本机后安装；等同于 scp + install.sh。') ]),
			fileInput,
			E('div', { 'style': 'margin-top:8px' }, [ uploadBtn ]),
			E('p', { 'style': 'margin-top:12px;color:#666' }, [ _('或填写设备上已有路径：') ]),
			pathInput,
			E('div', { 'style': 'margin-top:8px' }, [ localBtn ]),
			localBar,
			localResult
		]));

		/* auto-poll if already busy */
		if (st.busy)
			startPoll();

		self._unload = stopPoll;
		return wrap;
	},

	unmount: function() {
		if (pollTimer) {
			window.clearInterval(pollTimer);
			pollTimer = null;
		}
	}
});
