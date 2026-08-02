import { cn } from '../../lib/utils'

const variants = {
	default: 'bg-accent/90 text-surface hover:bg-accent',
	outline: 'border border-edge bg-transparent hover:bg-white/5',
	ghost: 'bg-transparent hover:bg-white/5',
}

export function Button({ variant = 'outline', className, ...props }) {
	return (
		<button
			className={cn(
				'inline-flex h-8 items-center justify-center rounded-md px-3 text-xs font-medium transition-colors',
				'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent',
				'disabled:pointer-events-none disabled:opacity-50',
				variants[variant] ?? variants.outline,
				className,
			)}
			{...props}
		/>
	)
}
