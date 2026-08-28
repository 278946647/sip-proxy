'use strict';
'require fs';
'require ui';

var base = 'http://127.0.0.1:8080/api/v1';

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
		var parsed = null;
		var out = (res.stdout || '').trim();
		if (out) {
			try {
				parsed = JSON.parse(out);
			} catch (e) {
				parsed = null;
			}
		}
		if (parsed && parsed.ok === false) {
			throw new Error((parsed.error && parsed.error.message) || '请求失败');
		}
		if (res.code !== 0) {
			throw new Error((res.stderr || res.stdout || ('wget exit ' + res.code)).trim());
		}
		return parsed || parseJSON(res);
	});
}

// BusyBox wget only supports GET and POST (--post-data). Write operations use POST.
function request(path, method, body) {
	var args = [ '-qO-', '-T', '10' ];
	var httpMethod = method || 'GET';
	if (httpMethod === 'GET') {
		args.push(base + path);
		return execWget(args);
	}
	args.push('--header=Content-Type: application/json');
	args.push('--post-data=' + JSON.stringify(body || {}));
	args.push(base + path);
	return execWget(args);
}

function get(path) {
	return request(path, 'GET');
}

function post(path, body) {
	return request(path, 'POST', body);
}

function put(path, body) {
	return request(path, 'POST', body);
}

function restartService(name) {
	return post('/services/' + encodeURIComponent(name) + '/restart', {});
}

function showError(err) {
	ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
}

function value(v) {
	if (v === null || v === undefined || v === '')
		return '-';
	if (typeof v === 'object')
		return JSON.stringify(v);
	return String(v);
}

function table(rows) {
	var body = rows.map(function(row) {
		return E('tr', {}, [
			E('td', { 'class': 'th' }, [ row[0] ]),
			E('td', {}, [ value(row[1]) ])
		]);
	});
	return E('table', { 'class': 'table' }, body);
}

return {
	get: get,
	post: post,
	put: put,
	request: request,
	restartService: restartService,
	showError: showError,
	value: value,
	table: table
};
