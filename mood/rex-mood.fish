# rex-mood: after every command, record how it ended so mood.lua can tint
# the pane (Rex doesn't track exit codes of commands run inside a shell).
# Installed as a symlink in ~/.config/fish/conf.d/; delete the link to remove.
status is-interactive; or exit
set -q REX_BLOCK; or exit

function __rex_mood_postexec --on-event fish_postexec
    set -l code $status
    mkdir -p /tmp/rex-mood
    echo $code (date +%s) >/tmp/rex-mood/(string replace -a : _ $REX_BLOCK)
end
