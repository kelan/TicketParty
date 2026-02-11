# TicketParty tasks

set shell := ["/bin/zsh", "-cu"]

supervisor_label := "io.kelan.ticketparty.codex-supervisor"
supervisor_runtime_root := "$HOME/Library/Application Support/TicketParty"
supervisor_install_dir := "{{supervisor_runtime_root}}/bin"
supervisor_runtime_dir := "{{supervisor_runtime_root}}/runtime"
supervisor_logs_dir := "{{supervisor_runtime_root}}/logs"
supervisor_binary := "{{supervisor_install_dir}}/codex-supervisor"
supervisor_record := "{{supervisor_runtime_dir}}/supervisor.json"
supervisor_socket := "{{supervisor_runtime_dir}}/supervisor.sock"
supervisor_plist := "$HOME/Library/LaunchAgents/{{supervisor_label}}.plist"

swiftformat:
    swiftformat --config config/swiftformat .

swiftlint:
    swiftlint lint --config config/swiftlint.yml

lint: swiftformat swiftlint

supervisor-build:
    swift build --package-path TicketPartyPackage -c release --product codex-supervisor

supervisor-install: supervisor-build
    mkdir -p "{{supervisor_install_dir}}" "{{supervisor_runtime_dir}}" "{{supervisor_logs_dir}}"
    cp "TicketPartyPackage/.build/release/codex-supervisor" "{{supervisor_binary}}"
    chmod +x "{{supervisor_binary}}"

supervisor-install-agent:
    mkdir -p "$HOME/Library/LaunchAgents" "{{supervisor_logs_dir}}" "{{supervisor_runtime_dir}}"
    python3 -c 'from pathlib import Path; import textwrap; p = Path("{{supervisor_plist}}"); p.write_text(textwrap.dedent("""\
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    <key>Label</key>
    <string>{{supervisor_label}}</string>
    <key>ProgramArguments</key>
    <array>
    <string>{{supervisor_binary}}</string>
    <string>--runtime-dir</string>
    <string>{{supervisor_runtime_dir}}</string>
    <string>--record-path</string>
    <string>{{supervisor_record}}</string>
    <string>--socket-path</string>
    <string>{{supervisor_socket}}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>{{supervisor_logs_dir}}/codex-supervisor.out.log</string>
    <key>StandardErrorPath</key>
    <string>{{supervisor_logs_dir}}/codex-supervisor.err.log</string>
    </dict>
    </plist>
    """), encoding="utf-8")'
    plutil -lint "{{supervisor_plist}}"

supervisor-start: supervisor-install supervisor-install-agent
    uid="$(id -u)"
    launchctl bootout "gui/${uid}" "{{supervisor_plist}}" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/${uid}" "{{supervisor_plist}}"
    launchctl enable "gui/${uid}/{{supervisor_label}}"
    launchctl kickstart -k "gui/${uid}/{{supervisor_label}}"

supervisor-stop:
    uid="$(id -u)"
    launchctl bootout "gui/${uid}" "{{supervisor_plist}}" >/dev/null 2>&1 || true

supervisor-status:
    uid="$(id -u)"
    launchctl print "gui/${uid}/{{supervisor_label}}"

supervisor-logs:
    tail -n 100 "{{supervisor_logs_dir}}/codex-supervisor.out.log" "{{supervisor_logs_dir}}/codex-supervisor.err.log"
