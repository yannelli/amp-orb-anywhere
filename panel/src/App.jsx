import { useCallback, useEffect, useState } from 'react'
import { Card, CardContent, CardHeader, CardTitle } from './components/ui/card'
import { Badge } from './components/ui/badge'
import { Button } from './components/ui/button'
import { cn } from './lib/utils'

const ACTIONS = ['start', 'stop', 'restart']

function toneFor(state) {
	if (state === 'active' || state === 'running') return 'ok'
	if (state === 'awaiting login' || state === 'activating') return 'warn'
	if (state === 'failed') return 'bad'
	return 'neutral'
}

function Stat({ label, value }) {
	return (
		<Card>
			<CardContent className="p-5">
				<div className="text-xs uppercase tracking-wide text-muted">{label}</div>
				<div className="mt-1 text-2xl font-semibold tabular-nums">{value}</div>
			</CardContent>
		</Card>
	)
}

function Row({ label, value }) {
	if (!value) return null
	return (
		<div className="flex justify-between gap-4 py-1 text-sm">
			<span className="text-muted">{label}</span>
			<span className="truncate font-medium" title={value}>
				{value}
			</span>
		</div>
	)
}

function Workspace({ workspace, onAction, busy }) {
	return (
		<Card>
			<CardHeader className="flex-row items-start justify-between gap-3">
				<div className="min-w-0">
					<CardTitle className="truncate text-base">{workspace.id}</CardTitle>
					<p className="mt-0.5 truncate text-sm text-muted">{workspace.project || 'no project'}</p>
				</div>
				<Badge tone={toneFor(workspace.service)}>{workspace.service || 'unknown'}</Badge>
			</CardHeader>
			<CardContent>
				<div className="divide-y divide-edge/60">
					<Row label="Agent" value={workspace.agent} />
					<Row label="Mode" value={workspace.mode} />
					<Row label="Auth" value={workspace.sharedAuth ? `${workspace.auth} (shared)` : workspace.auth} />
					{workspace.nativeRemote ? <Row label="Remote control" value="configured" /> : null}
					{workspace.desktop?.enabled ? (
						<Row label="Web workspace" value={`${workspace.desktop.access} · ${workspace.desktopService || 'unknown'}`} />
					) : null}
					{workspace.openchamber?.enabled ? <Row label="OpenChamber" value={`port ${workspace.openchamber.port}`} /> : null}
				</div>
				<div className="mt-4 flex flex-wrap gap-2">
					{ACTIONS.map((action) => (
						<Button
							key={action}
							variant={action === 'stop' ? 'outline' : 'default'}
							disabled={busy}
							onClick={() => onAction(workspace.id, action)}
						>
							{action}
						</Button>
					))}
				</div>
			</CardContent>
		</Card>
	)
}

export default function App() {
	const [data, setData] = useState(null)
	const [error, setError] = useState('')
	const [busy, setBusy] = useState(false)

	const load = useCallback(async () => {
		try {
			const response = await fetch('/api/workspaces', { headers: { accept: 'application/json' } })
			if (!response.ok) throw new Error(`request failed with status ${response.status}`)
			setData(await response.json())
			setError('')
		} catch (cause) {
			setError(String(cause.message || cause))
		}
	}, [])

	useEffect(() => {
		load()
		const timer = setInterval(load, 5000)
		return () => clearInterval(timer)
	}, [load])

	const act = useCallback(
		async (id, action) => {
			setBusy(true)
			try {
				const response = await fetch(`/api/workspaces/${encodeURIComponent(id)}/${action}`, { method: 'POST' })
				if (!response.ok) {
					const body = await response.json().catch(() => ({}))
					throw new Error(body.error || `request failed with status ${response.status}`)
				}
				await load()
			} catch (cause) {
				setError(String(cause.message || cause))
			} finally {
				setBusy(false)
			}
		},
		[load],
	)

	const workspaces = data?.workspaces ?? []
	const running = workspaces.filter((w) => w.service === 'active').length

	return (
		<div className="mx-auto max-w-6xl px-6 py-10">
			<header className="mb-8 flex flex-wrap items-end justify-between gap-4">
				<div>
					<h1 className="text-xl font-semibold tracking-tight">Amp Orb Anywhere</h1>
					<p className="mt-1 text-sm text-muted">
						{data?.host ? `${data.host} · manager ${data.version}` : 'Loading host details'}
					</p>
				</div>
				<Button variant="ghost" onClick={load} disabled={busy}>
					Refresh
				</Button>
			</header>

			{error ? (
				<div className="mb-6 rounded-lg border border-bad/30 bg-bad/10 px-4 py-3 text-sm text-bad">{error}</div>
			) : null}

			<div className="mb-8 grid gap-4 sm:grid-cols-3">
				<Stat label="Workspaces" value={workspaces.length} />
				<Stat label="Active" value={running} />
				<Stat label="Stopped" value={workspaces.length - running} />
			</div>

			{data && workspaces.length === 0 ? (
				<Card>
					<CardContent className="p-10 text-center text-sm text-muted">
						No workspaces yet. Create one with <code className="text-ink">sudo amp-runner-setup add</code>.
					</CardContent>
				</Card>
			) : (
				<div className={cn('grid gap-4', 'md:grid-cols-2')}>
					{workspaces.map((workspace) => (
						<Workspace key={workspace.id} workspace={workspace} onAction={act} busy={busy} />
					))}
				</div>
			)}
		</div>
	)
}
