# Login shells (ssh, the session supervisor) do not read environment.d: one source of truth.
set -a
. /usr/lib/environment.d/60-pocknix-sdl-xb360.conf
set +a
