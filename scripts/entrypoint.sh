#!/usr/bin/env bash
set -euo pipefail

if [[ -r /run/secrets/amp_api_key ]]; then
	export AMP_API_KEY
	AMP_API_KEY="$(cat /run/secrets/amp_api_key)"
fi

if [[ -x /usr/local/bin/agent-browser-chrome ]]; then
	export AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/agent-browser-chrome
fi

exec "$@"
