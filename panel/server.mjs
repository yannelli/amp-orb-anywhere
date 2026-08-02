#!/usr/bin/env node
// Control panel for amp-orb-anywhere.
//
// Binds host loopback only. Reads workspace state from the manager's own JSON
// files and derives live status the same way setup.sh does, then drives systemd
// through a narrow sudoers rule. It deliberately cannot call setup.sh, because
// that script also owns uninstall and removal.

import { createServer } from 'node:http'
import { execFile } from 'node:child_process'
import { readdir, readFile } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { timingSafeEqual } from 'node:crypto'
import { extname, join, normalize, resolve } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

const PORT = Number.parseInt(process.env.AMP_PANEL_PORT ?? '7900', 10)
const HOST = '127.0.0.1'
const STATE_DIR = process.env.AMP_RUNNER_STATE_DIR ?? '/etc/amp-runner/instances'
const PASSWORD_FILE = process.env.AMP_PANEL_PASSWORD_FILE ?? '/etc/amp-runner/secrets/panel-password'
const DIST = resolve(process.env.AMP_PANEL_DIST ?? join(import.meta.dirname, 'dist'))
const VERSION = process.env.AMP_PANEL_VERSION ?? 'unknown'
const ACTIONS = new Set(['start', 'stop', 'restart'])

const MIME = {
	'.css': 'text/css; charset=utf-8',
	'.html': 'text/html; charset=utf-8',
	'.ico': 'image/x-icon',
	'.js': 'text/javascript; charset=utf-8',
	'.json': 'application/json; charset=utf-8',
	'.svg': 'image/svg+xml',
	'.woff2': 'font/woff2',
}

// Workspace IDs are one lowercase DNS label, matching validate_runner_id.
const RUNNER_ID = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

let cachedPassword = null

async function password() {
	if (cachedPassword === null) {
		cachedPassword = (await readFile(PASSWORD_FILE, 'utf8')).trim()
	}
	return cachedPassword
}

function constantTimeEquals(a, b) {
	const left = Buffer.from(a)
	const right = Buffer.from(b)
	if (left.length !== right.length) return false
	return timingSafeEqual(left, right)
}

async function authorized(request) {
	const header = request.headers.authorization ?? ''
	if (!header.startsWith('Basic ')) return false
	let decoded
	try {
		decoded = Buffer.from(header.slice(6), 'base64').toString('utf8')
	} catch {
		return false
	}
	const separator = decoded.indexOf(':')
	if (separator < 0) return false
	return constantTimeEquals(decoded.slice(separator + 1), await password())
}

async function quiet(file, args) {
	try {
		const { stdout } = await run(file, args, { timeout: 5000 })
		return stdout.trim()
	} catch {
		return ''
	}
}

async function describe(id, record) {
	const service = record.service || `amp-runner-${id}`
	// systemd state only. Reading container state would mean docker group
	// membership for this account, which is effectively host root and would
	// undo the point of running the panel unprivileged.
	const [serviceState, desktopState] = await Promise.all([
		quiet('systemctl', ['is-active', `${service}.service`]),
		record.desktop?.enabled ? quiet('systemctl', ['is-active', `${service}-desktop.service`]) : Promise.resolve(''),
	])
	return {
		id,
		agent: record.agent ?? 'amp',
		mode: record.mode ?? '',
		project: record.project ?? '',
		auth: record.auth ?? '',
		sharedAuth: record.sharedAuth === true,
		nativeRemote: record.nativeRemote === true,
		desktop: record.desktop ?? null,
		desktopService: desktopState || '',
		openchamber: record.openchamber ?? null,
		service: serviceState || 'inactive',
	}
}

async function listWorkspaces() {
	let entries
	try {
		entries = await readdir(STATE_DIR)
	} catch {
		return []
	}
	const records = []
	for (const entry of entries) {
		if (!entry.endsWith('.json')) continue
		try {
			const record = JSON.parse(await readFile(join(STATE_DIR, entry), 'utf8'))
			const id = record.id ?? entry.slice(0, -5)
			if (!RUNNER_ID.test(id)) continue
			records.push(await describe(id, record))
		} catch {
			// A half-written or hand-edited state file should not take down the list.
		}
	}
	return records.sort((a, b) => a.id.localeCompare(b.id))
}

function sendJson(response, status, body) {
	const payload = JSON.stringify(body)
	response.writeHead(status, {
		'content-type': 'application/json; charset=utf-8',
		'content-length': Buffer.byteLength(payload),
		'cache-control': 'no-store',
	})
	response.end(payload)
}

async function sendAsset(response, pathname) {
	// normalize before join so ../ cannot escape the build output directory.
	const relative = normalize(pathname).replace(/^(\.\.[/\\])+/, '')
	let file = resolve(join(DIST, relative))
	if (!file.startsWith(DIST)) {
		sendJson(response, 403, { error: 'forbidden' })
		return
	}
	try {
		const info = await stat(file)
		if (info.isDirectory()) file = join(file, 'index.html')
	} catch {
		file = join(DIST, 'index.html')
	}
	try {
		await stat(file)
	} catch {
		sendJson(response, 404, { error: 'not found' })
		return
	}
	response.writeHead(200, { 'content-type': MIME[extname(file)] ?? 'application/octet-stream' })
	createReadStream(file).pipe(response)
}

const server = createServer(async (request, response) => {
	try {
		if (!(await authorized(request))) {
			response.writeHead(401, {
				'www-authenticate': 'Basic realm="Amp Orb Anywhere", charset="UTF-8"',
				'content-type': 'application/json; charset=utf-8',
			})
			response.end(JSON.stringify({ error: 'authentication required' }))
			return
		}

		const url = new URL(request.url ?? '/', `http://${HOST}:${PORT}`)

		if (url.pathname === '/api/workspaces' && request.method === 'GET') {
			sendJson(response, 200, {
				host: process.env.AMP_PANEL_HOSTNAME ?? 'this host',
				version: VERSION,
				workspaces: await listWorkspaces(),
			})
			return
		}

		const action = url.pathname.match(/^\/api\/workspaces\/([^/]+)\/([a-z]+)$/)
		if (action && request.method === 'POST') {
			const id = decodeURIComponent(action[1])
			const verb = action[2]
			if (!RUNNER_ID.test(id)) {
				sendJson(response, 400, { error: 'invalid workspace id' })
				return
			}
			if (!ACTIONS.has(verb)) {
				sendJson(response, 400, { error: 'unsupported action' })
				return
			}
			try {
				await run('sudo', ['-n', 'systemctl', verb, `amp-runner-${id}.service`], { timeout: 60000 })
			} catch (cause) {
				sendJson(response, 500, { error: `systemctl ${verb} failed: ${String(cause.stderr || cause.message).trim()}` })
				return
			}
			sendJson(response, 200, { ok: true })
			return
		}

		if (request.method !== 'GET') {
			sendJson(response, 405, { error: 'method not allowed' })
			return
		}
		if (url.pathname.startsWith('/api/')) {
			sendJson(response, 404, { error: 'not found' })
			return
		}
		await sendAsset(response, url.pathname)
	} catch (cause) {
		sendJson(response, 500, { error: String(cause?.message ?? cause) })
	}
})

server.listen(PORT, HOST, () => {
	process.stdout.write(`Amp Orb Anywhere panel listening on http://${HOST}:${PORT}\n`)
})

for (const signal of ['SIGTERM', 'SIGINT']) {
	process.on(signal, () => server.close(() => process.exit(0)))
}
