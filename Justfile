# TicketParty tasks

set shell := ["/bin/zsh", "-cu"]

supervisor_label := "io.kelan.ticketparty.codex-supervisor"
supervisor_runtime_root := "$HOME/Library/Application Support/TicketParty"
supervisor_install_dir := "$HOME/Library/Application Support/TicketParty/bin"
supervisor_runtime_dir := "$HOME/Library/Application Support/TicketParty/runtime"
supervisor_logs_dir := "$HOME/Library/Application Support/TicketParty/logs"
supervisor_binary := "$HOME/Library/Application Support/TicketParty/bin/codex-supervisor"
supervisor_record := "$HOME/Library/Application Support/TicketParty/runtime/supervisor.json"
supervisor_socket := "$HOME/Library/Application Support/TicketParty/runtime/supervisor.sock"
supervisor_plist := "$HOME/Library/LaunchAgents/io.kelan.ticketparty.codex-supervisor.plist"

swiftformat:
    swiftformat --config config/swiftformat .

swiftlint:
    swiftlint lint --config config/swiftlint.yml

lint: swiftformat swiftlint

supervisor-build:
    swift build --package-path TicketPartyPackage -c release --product codex-supervisor

supervisor-install: supervisor-build
    mkdir -p "{{supervisor_install_dir}}" "{{supervisor_runtime_dir}}" "{{supervisor_logs_dir}}"
    bin_path="$(swift build --package-path TicketPartyPackage -c release --product codex-supervisor --show-bin-path)"; built_bin="${bin_path}/codex-supervisor"; test -x "${built_bin}" || (echo "Expected built binary at ${built_bin}, but it was not found." && exit 1); cp "${built_bin}" "{{supervisor_binary}}"
    chmod +x "{{supervisor_binary}}"

supervisor-install-agent:
    mkdir -p "$HOME/Library/LaunchAgents" "{{supervisor_logs_dir}}" "{{supervisor_runtime_dir}}"
    python3 -c 'import os, plistlib; from pathlib import Path; expand = lambda p: os.path.expandvars(os.path.expanduser(p)); plist_path = Path(expand("{{supervisor_plist}}")); plist_path.parent.mkdir(parents=True, exist_ok=True); data = {"Label": "{{supervisor_label}}", "ProgramArguments": [expand("{{supervisor_binary}}"), "--runtime-dir", expand("{{supervisor_runtime_dir}}"), "--record-path", expand("{{supervisor_record}}"), "--socket-path", expand("{{supervisor_socket}}")], "RunAtLoad": True, "KeepAlive": True, "ProcessType": "Background", "StandardOutPath": expand("{{supervisor_logs_dir}}/codex-supervisor.out.log"), "StandardErrorPath": expand("{{supervisor_logs_dir}}/codex-supervisor.err.log")}; plistlib.dump(data, plist_path.open("wb"), sort_keys=False)'
    plutil -lint "{{supervisor_plist}}"

supervisor-start: supervisor-install supervisor-install-agent
    launchctl bootout "gui/$(id -u)" "{{supervisor_plist}}" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "{{supervisor_plist}}"
    launchctl enable "gui/$(id -u)/{{supervisor_label}}"
    launchctl kickstart -k "gui/$(id -u)/{{supervisor_label}}"

supervisor-stop:
    launchctl bootout "gui/$(id -u)" "{{supervisor_plist}}" >/dev/null 2>&1 || true

supervisor-status:
    launchctl print "gui/$(id -u)/{{supervisor_label}}"

supervisor-logs:
    tail -n 100 "{{supervisor_logs_dir}}/codex-supervisor.out.log" "{{supervisor_logs_dir}}/codex-supervisor.err.log"
