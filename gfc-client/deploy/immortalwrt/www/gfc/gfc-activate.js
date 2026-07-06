(function () {
  var API = '/cgi-bin/gfc-activation';

  function $(id) {
    return document.getElementById(id);
  }

  function setMessage(el, text, tone) {
    if (!el) return;
    el.textContent = text || '';
    el.className = 'message' + (tone ? ' ' + tone : '');
  }

  function apiGet(action) {
    return fetch(API + '?action=' + encodeURIComponent(action), {
      method: 'GET',
      cache: 'no-store',
    }).then(function (res) {
      return res.json();
    });
  }

  function apiFlash(code, resetState) {
    return fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: code, reset_state: !!resetState }),
    }).then(function (res) {
      return res.json();
    });
  }

  function text(v, fallback) {
    if (v === null || v === undefined || v === '') return fallback || '-';
    return String(v);
  }

  function renderStatus(data) {
    var payload = (data && data.data && data.data.payload) || (data && data.payload) || {};
    var present = !!(data && data.data && data.data.code_present);
    if (data && data.ok === false && !present) present = false;

    var codeEl = $('stat-code');
    var cpEl = $('stat-control-plane');
    var agentEl = $('stat-agent');

    if (codeEl) {
      codeEl.textContent = present ? '已写入' : '未激活';
      codeEl.style.color = present ? 'var(--gfc-ok)' : 'var(--gfc-warn)';
    }
    if (cpEl) {
      cpEl.textContent = text(
        payload.controlPlaneUrl || payload.control_plane_url || payload.control,
        '等待刷码'
      );
    }
    if (agentEl) agentEl.textContent = present ? '同步中' : '待命';
  }

  function loadStatus() {
    return apiGet('status')
      .then(function (res) {
        renderStatus(res);
        return res;
      })
      .catch(function () {
        renderStatus({ code_present: false });
      });
  }

  function bindForm() {
    var form = $('gfc-activate-form');
    var codeInput = $('gfc-line-code');
    var resetInput = $('gfc-reset-state');
    var submitBtn = $('gfc-submit');
    var msg = $('gfc-message');

    if (!form || !codeInput || !submitBtn) return;

    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var code = (codeInput.value || '').trim();
      if (!code) {
        setMessage(msg, '请粘贴控制平台生成的线路码', 'err');
        return;
      }
      submitBtn.disabled = true;
      setMessage(msg, '正在刷码并应用配置…', '');
      apiFlash(code, resetInput && resetInput.checked)
        .then(function (res) {
          if (res && res.ok !== false) {
            setMessage(msg, '刷码成功，设备正在连接控制面', 'ok');
            codeInput.value = '';
            return loadStatus();
          }
          var err =
            (res && res.error && (res.error.message || res.error)) ||
            '刷码失败，请检查线路码是否有效';
          setMessage(msg, String(err), 'err');
        })
        .catch(function (err) {
          setMessage(msg, '请求失败: ' + String(err), 'err');
        })
        .finally(function () {
          submitBtn.disabled = false;
        });
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    bindForm();
    loadStatus();
    setInterval(loadStatus, 15000);
  });
})();
