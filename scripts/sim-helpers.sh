# shellcheck shell=bash
# Sourced helpers shared by the simulator scripts (uitest.sh, run-sim.sh,
# e2e-engines-sim.sh). Keep this file ASCII-only: a "$VAR…" (U+2026 right after
# a variable) is absorbed into the variable name by bash 3.2 under UTF-8
# locales and explodes under `set -u` — that exact bug broke CI once.

# resolve_sim_udid <device-name> <ios-version>
# Prints the UDID of an available simulator with that exact device name inside
# the requested iOS runtime section. If the requested runtime has no such
# device, falls back to the same device name under ANY available runtime (with
# a warning on stderr) so CI keeps working when the runner image ships a
# different iOS version. Prints nothing if the device name matches nowhere.
resolve_sim_udid() {
  local device="$1" os="$2" udid
  udid="$(xcrun simctl list devices available | awk -v dev="$device" -v os="$os" '
    /^-- /  { insec = ($0 == "-- iOS " os " --") }
    insec && index($0, "    " dev " (") == 1 {
      if (match($0, /[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}/)) {
        print substr($0, RSTART, RLENGTH); exit
      }
    }')"
  if [[ -z "$udid" ]]; then
    udid="$(xcrun simctl list devices available | awk -v dev="$device" '
      index($0, "    " dev " (") == 1 {
        if (match($0, /[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}/)) {
          print substr($0, RSTART, RLENGTH); exit
        }
      }')"
    if [[ -n "$udid" ]]; then
      echo "warning: no '$device' under iOS $os; using the one from another installed runtime ($udid)" >&2
    fi
  fi
  printf '%s' "$udid"
}

# die_no_sim <device-name> <ios-version> — uniform error with the availability dump.
die_no_sim() {
  echo "error: no available simulator named '$1' (requested iOS $2, none in any runtime). Available:" >&2
  xcrun simctl list devices available | grep -iE -- '-- iOS|iphone' >&2
  exit 1
}

# boot_sim <udid> — boot if not already booted, wait for springboard.
boot_sim() {
  local udid="$1" state
  state="$(xcrun simctl list devices | grep "$udid" | grep -oE '\((Booted|Shutdown)\)' | tr -d '()' || true)"
  if [[ "$state" != "Booted" ]]; then
    echo "==> Booting simulator $udid..."
    xcrun simctl boot "$udid"
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
}
