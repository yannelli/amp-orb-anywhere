import { cn } from '../../lib/utils'

const tones = {
	ok: 'border-ok/30 bg-ok/10 text-ok',
	warn: 'border-warn/30 bg-warn/10 text-warn',
	bad: 'border-bad/30 bg-bad/10 text-bad',
	neutral: 'border-edge bg-white/5 text-muted',
}

export function Badge({ tone = 'neutral', className, ...props }) {
	return (
		<span
			className={cn(
				'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium',
				tones[tone] ?? tones.neutral,
				className,
			)}
			{...props}
		/>
	)
}
