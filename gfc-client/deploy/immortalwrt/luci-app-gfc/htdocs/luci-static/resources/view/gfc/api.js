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

function request(path, method, body) {
	var args = [ '-qO-', '-T', '5' ];
	if (method === 'POST' || method === 'PUT' || method === 'DELETE') {
		args.push('--header=Content-Type: application/json');
		if (method !== 'POST')
			args.push('--method=' + method);
		args.push('--post-data=' + JSON.stringify(body || {}));
	}
	args.push(base + path);
	return fs.exec('/usr/bin/wget', args).then(parseJSON);
}

function get(path) {
	return request(path, 'GET');
}

function post(path, body) {
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
	restartService: restartService,
	showError: showError,
	value: value,
	table: table
};
