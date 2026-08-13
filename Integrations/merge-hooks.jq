def without_command($command):
  map(select(([.hooks[]?.command] | index($command)) == null));

def materialize($group; $command):
  $group | .hooks |= map(if .type == "command" then .command = $command else . end);

.hooks = (.hooks // {}) |
reduce ($fragment.hooks | to_entries[]) as $entry (.;
  .hooks[$entry.key] = (
    ((.hooks[$entry.key] // []) | without_command($command))
    + ($entry.value | map(materialize(.; $command)))
  )
)
