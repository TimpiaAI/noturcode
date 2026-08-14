#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/noturcode-python-cache"

python3 -m py_compile "$repo_dir/Integrations/noturcode-agent.py"
python3 -m unittest discover -s "$repo_dir/Tests/RemoteAgentTests" -p 'test_*.py' -v
zsh -n "$repo_dir/Integrations/noturcode-cli.zsh"
zsh -n "$repo_dir/Integrations/noturcode-shell.zsh"
ssh -G \
  -o StreamLocalBindUnlink=yes \
  -R /tmp/noturcode-test-remote.sock:/tmp/noturcode-test-local.sock \
  localhost 2>/dev/null \
  | grep -q '^remoteforward /tmp/noturcode-test-remote.sock /tmp/noturcode-test-local.sock$'

print "REMOTE_TESTS:PASS"
