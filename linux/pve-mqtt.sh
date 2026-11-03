#!/usr/bin/env bash
#
# @file pve-mqtt.sh
# @brief Unattended deploy and update of an MQTT broker with a recorder in
#   a Proxmox LXC container.
# @description
#   Runs on a Proxmox VE host as root and needs no answers. In an
#   unprivileged container ($CT_HOSTNAME, created when missing):
#
#   * Mosquitto with one login per user and topic rights by role:
#     - owners (MQTT_OWNERS) read and write users/<owner>/#, read comms/#;
#     - gateways (MQTT_GATEWAYS) write their network under comms/:
#       meshtastic -> comms/mesh/meshtastic/#, meshcore ->
#       comms/mesh/meshcore/#, reticulum -> comms/reticulum/#, any other
#       name -> comms/<name>/#;
#     - readers (MQTT_READERS, e.g. Home Assistant) read everything;
#     - "admin" reads and writes everything, "recorder" reads everything.
#   * The recorder: every message is appended as one JSON line to
#     /var/lib/mqtt-recorder/<topic level 1>/<2>/<3>/<date>.jsonl; files
#     older than a day are gzipped, and deleted after RECORDER_KEEP_DAYS
#     days when that is not 0.
#   * The Colota receiver: Colota (and other OwnTracks-style HTTP clients)
#     POSTs JSON to http://<ct>:$COLOTA_PORT/<device> with Basic auth of an
#     owner; the body is published, retained, to
#     users/<owner>/<device>/location with that owner's own MQTT login, so
#     the broker rights apply.
#
#   Device passports are retained messages in users/<owner>/<device>/meta,
#   e.g. {"kind":"fixed","site":"home","node":"!a1b2c3d4"}.
#
#   Running it again snapshots the container, upgrades Debian, rewrites the
#   generated configs and adds new users. Passwords are generated on the
#   host and kept in /root/pve-mqtt/users/<name> (mode 600).
#
#   How to run:
#     bash <(curl -fsSL https://raw.githubusercontent.com/Gesugao-san/scripts/master/linux/pve-mqtt.sh)

# Settings are read by the shared library.
# shellcheck disable=SC2034
set -euo pipefail

SERVICE="mqtt"
PERSISTED_SETTINGS=(
  MQTT_OWNERS MQTT_GATEWAYS MQTT_READERS COLOTA_PORT RECORDER_KEEP_DAYS
)

# ---- Shared library ----

SCRIPTS_REF="${SCRIPTS_REF:-master}"

# @description Source a shared library from lib/ next to this script, or
#   from GitHub at $SCRIPTS_REF when the script itself came from a pipe.
# @arg $1 string Library file name.
pve_source() {
  local dir url code
  dir="$(dirname "${BASH_SOURCE[0]}")"
  if [[ -f "$dir/lib/$1" ]]; then
    # shellcheck source=/dev/null
    source "$dir/lib/$1"
    return 0
  fi
  url="https://raw.githubusercontent.com/Gesugao-san/scripts/$SCRIPTS_REF/linux/lib/$1"
  code="$(curl -fsSL --retry 3 "$url")" \
    || { printf '[x] ERROR: cannot download %s\n' "$url" >&2; exit 1; }
  # shellcheck source=/dev/null
  source <(printf '%s\n' "$code")
}

pve_source pve-ct.sh

# ---- Settings (environment > saved > default) ----

guest_load_settings
MQTT_OWNERS="${MQTT_OWNERS:-gesu infra}"
MQTT_GATEWAYS="${MQTT_GATEWAYS:-meshtastic meshcore reticulum}"
MQTT_READERS="${MQTT_READERS:-homeassistant}"
COLOTA_PORT="${COLOTA_PORT:-8880}"
RECORDER_KEEP_DAYS="${RECORDER_KEEP_DAYS:-0}"
CT_DISK_GB="${CT_DISK_GB:-16}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_DESCRIPTION="MQTT broker, recorder and Colota receiver"
ct_defaults

# Logins every installation has besides the configured ones.
FIXED_USERS="admin recorder"

# ---- Hooks ----

service_usage() {
  cat << EOF

MQTT (environment, remembered):
  MQTT_OWNERS          owners, rights on users/<owner>/#  [$MQTT_OWNERS]
  MQTT_GATEWAYS        gateways, rights on their comms/ branch
                                          [$MQTT_GATEWAYS]
  MQTT_READERS         read-only logins for everything   [$MQTT_READERS]
  COLOTA_PORT          HTTP port of the Colota receiver  [$COLOTA_PORT]
  RECORDER_KEEP_DAYS   delete recordings older than this, 0 = keep [$RECORDER_KEEP_DAYS]
EOF
}

# @description Fail on login names that would break the ACL or topics.
service_preflight() {
  local name
  for name in $FIXED_USERS $MQTT_OWNERS $MQTT_GATEWAYS $MQTT_READERS; do
    [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && continue
    die "bad login name '$name': use a-z, 0-9, '_' and '-'"
  done
}

# @description Print "login:password" lines for all users, creating
#   passwords on the host when they are new.
# @stdout One line per user.
all_credentials() {
  local name
  for name in $FIXED_USERS $MQTT_OWNERS $MQTT_GATEWAYS $MQTT_READERS; do
    printf '%s:%s\n' "$name" "$(secret_or_new "users/$name")"
  done
}

service_exports() {
  export_var MQTT_OWNERS "$MQTT_OWNERS"
  export_var MQTT_GATEWAYS "$MQTT_GATEWAYS"
  export_var MQTT_READERS "$MQTT_READERS"
  export_var COLOTA_PORT "$COLOTA_PORT"
  export_var RECORDER_KEEP_DAYS "$RECORDER_KEEP_DAYS"
  export_var MQTT_CREDENTIALS "$(all_credentials)"
}

service_summary() {
  local ip
  ip="$(guest_address || true)"
  printf 'Broker    : mqtt://%s:1883\n' "$ip"
  printf 'Colota    : http://%s:%s/<device>  (Basic auth: owner login)\n' \
    "$ip" "$COLOTA_PORT"
  printf 'Logins    : ls %s/users/   (password: cat users/<login>)\n' \
    "$STATE_DIR"
  printf 'Records   : /var/lib/mqtt-recorder/ in the container\n'
}

# ---- Inside the container ----

service_script() {
  cat << 'SCRIPT'
REC_DIR=/var/lib/mqtt-recorder

# Prints the comms/ branch of a gateway (lookup table, unknown -> own name).
gateway_branch() {
  local -A branches=(
    [meshtastic]=comms/mesh/meshtastic
    [meshcore]=comms/mesh/meshcore
    [reticulum]=comms/reticulum
  )
  printf '%s' "${branches[$1]:-comms/$1}"
}

setup_broker() {
  write_file /etc/mosquitto/conf.d/pve-mqtt.conf 644 << 'EOF'
# Managed by pve-mqtt.sh, rewritten on every run.
per_listener_settings false
listener 1883
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
max_queued_messages 10000
EOF
  # Plain "login:password" lines, hashed in place by mosquitto_passwd, so
  # passwords never appear in process arguments.
  printf '%s\n' "$MQTT_CREDENTIALS" | write_file /etc/mosquitto/passwd 600
  mosquitto_passwd -U /etc/mosquitto/passwd
  # Mosquitto 2 wants its files owned by its own user.
  chown mosquitto:mosquitto /etc/mosquitto/passwd
  chmod 600 /etc/mosquitto/passwd

  local name
  {
    printf '# Managed by pve-mqtt.sh, rewritten on every run.\n'
    printf 'user admin\ntopic readwrite #\n\n'
    printf 'user recorder\ntopic read #\ntopic read $SYS/#\n\n'
    for name in $MQTT_READERS; do
      printf 'user %s\ntopic read #\n\n' "$name"
    done
    for name in $MQTT_GATEWAYS; do
      printf 'user %s\ntopic readwrite %s/#\n\n' "$name" "$(gateway_branch "$name")"
    done
    for name in $MQTT_OWNERS; do
      printf 'user %s\ntopic read comms/#\n\n' "$name"
    done
    printf '# Every login owns its own branch under users/.\n'
    printf 'pattern readwrite users/%%u/#\n'
  } | write_file /etc/mosquitto/acl 600 mosquitto:mosquitto

  systemctl enable mosquitto > /dev/null 2>&1
  systemctl restart mosquitto
  ok "Mosquitto is running with $(grep -c . /etc/mosquitto/passwd) logins"
}

# Prints the password of a login from MQTT_CREDENTIALS.
password_of() {
  printf '%s\n' "$MQTT_CREDENTIALS" | awk -F: -v u="$1" '$1 == u { sub(/^[^:]*:/, ""); print; exit }'
}

setup_recorder() {
  id mqtt-rec > /dev/null 2>&1 \
    || useradd --system --home-dir "$REC_DIR" --shell /usr/sbin/nologin mqtt-rec
  install -d -m 750 -o mqtt-rec -g mqtt-rec "$REC_DIR"

  write_file /usr/local/lib/mqtt-recorder/recorder.py 755 << 'EOF'
#!/usr/bin/env python3
"""Append every MQTT message as one JSON line, one file per topic branch and
day. Managed by pve-mqtt.sh."""
import base64
import datetime
import json
import os
import re
import sys

import paho.mqtt.client as mqtt

ROOT = os.environ.get("REC_DIR", "/var/lib/mqtt-recorder")
SAFE = re.compile(r"[^A-Za-z0-9_.-]")


def path_for(topic):
    """Map the first three topic levels to a directory, never outside ROOT."""
    parts = [SAFE.sub("_", p).lstrip(".") or "_" for p in topic.split("/")[:3]]
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    return os.path.join(ROOT, *parts, day + ".jsonl")


def record(msg):
    entry = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "topic": msg.topic,
        "qos": msg.qos,
        "retain": bool(msg.retain),
    }
    try:
        text = msg.payload.decode("utf-8")
        try:
            entry["json"] = json.loads(text)
        except ValueError:
            entry["text"] = text
    except UnicodeDecodeError:
        entry["b64"] = base64.b64encode(msg.payload).decode("ascii")
    path = path_for(msg.topic)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as out:
        out.write(json.dumps(entry, ensure_ascii=False) + "\n")


def on_connect(client, *_args):
    client.subscribe("#", qos=1)


def on_message(_client, _userdata, msg):
    try:
        record(msg)
    except OSError as err:
        print(f"cannot record {msg.topic}: {err}", file=sys.stderr)


def make_client():
    # paho-mqtt 2.x wants the callback API version, 1.x does not know it.
    if hasattr(mqtt, "CallbackAPIVersion"):
        return mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="recorder")
    return mqtt.Client(client_id="recorder")


def main():
    client = make_client()
    client.username_pw_set(os.environ["MQTT_USER"], os.environ["MQTT_PASSWORD"])
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect("127.0.0.1", 1883, keepalive=60)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()
EOF

  printf 'MQTT_USER=recorder\nMQTT_PASSWORD=%s\nREC_DIR=%s\n' \
    "$(password_of recorder)" "$REC_DIR" \
    | write_file /etc/mqtt-recorder.env 600

  write_file /etc/systemd/system/mqtt-recorder.service 644 << 'EOF'
# Managed by pve-mqtt.sh, rewritten on every run.
[Unit]
Description=MQTT recorder (every message to JSON lines)
After=mosquitto.service
Wants=mosquitto.service

[Service]
User=mqtt-rec
EnvironmentFile=/etc/mqtt-recorder.env
ExecStart=/usr/bin/python3 /usr/local/lib/mqtt-recorder/recorder.py
Restart=always
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/mqtt-recorder

[Install]
WantedBy=multi-user.target
EOF

  local delete=""
  [[ "$RECORDER_KEEP_DAYS" == "0" ]] \
    || delete="find $REC_DIR -name '*.jsonl.gz' -mtime +$RECORDER_KEEP_DAYS -delete"
  write_file /usr/local/sbin/mqtt-recorder-compress 755 << EOF
#!/bin/sh
# Managed by pve-mqtt.sh: gzip finished days, drop old ones if configured.
find $REC_DIR -name '*.jsonl' -mtime +0 -exec gzip -9 {} +
$delete
EOF
  write_file /etc/systemd/system/mqtt-recorder-compress.service 644 << 'EOF'
[Unit]
Description=Compress old MQTT recordings

[Service]
Type=oneshot
User=mqtt-rec
ExecStart=/usr/local/sbin/mqtt-recorder-compress
EOF
  write_file /etc/systemd/system/mqtt-recorder-compress.timer 644 << 'EOF'
[Unit]
Description=Compress old MQTT recordings daily

[Timer]
OnCalendar=*-*-* 00:20
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable mqtt-recorder mqtt-recorder-compress.timer > /dev/null 2>&1
  systemctl restart mqtt-recorder
  systemctl start mqtt-recorder-compress.timer
  ok "Recorder writes to $REC_DIR"
}

setup_colota_receiver() {
  write_file /usr/local/lib/mqtt-colota/receiver.py 755 << 'EOF'
#!/usr/bin/env python3
"""Receive OwnTracks-style HTTP location posts (Colota) and publish them to
users/<login>/<device>/location with the poster's own MQTT login.
Managed by pve-mqtt.sh."""
import base64
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import paho.mqtt.publish as publish

DEVICE = re.compile(r"^/([a-z0-9][a-z0-9_-]{0,31})/?$")
LOGIN = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
MAX_BODY = 64 * 1024


class Handler(BaseHTTPRequestHandler):
    server_version = "mqtt-colota"

    def reply(self, code, body=b"[]"):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def credentials(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return None
        try:
            login, _, password = base64.b64decode(header[6:]).decode().partition(":")
        except ValueError:
            return None
        return (login, password) if LOGIN.match(login) and password else None

    def do_POST(self):
        device = DEVICE.match(self.path.split("?")[0])
        creds = self.credentials()
        if not creds:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="mqtt"')
            self.end_headers()
            return
        if not device:
            return self.reply(404)
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            return self.reply(413)
        body = self.rfile.read(length)
        try:
            json.loads(body)
        except ValueError:
            return self.reply(400)
        login, password = creds
        try:
            publish.single(
                f"users/{login}/{device.group(1)}/location", body,
                qos=1, retain=True, hostname="127.0.0.1", port=1883,
                auth={"username": login, "password": password})
        except Exception:  # bad login or broker down: never leak details
            return self.reply(401)
        self.reply(200)

    def log_message(self, fmt, *args):
        pass  # positions are personal; the recorder keeps what is needed


def main():
    port = int(os.environ.get("COLOTA_PORT", "8880"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
EOF
  write_file /etc/systemd/system/mqtt-colota.service 644 << EOF
# Managed by pve-mqtt.sh, rewritten on every run.
[Unit]
Description=Colota HTTP receiver publishing to MQTT
After=mosquitto.service

[Service]
DynamicUser=yes
Environment=COLOTA_PORT=$COLOTA_PORT
ExecStart=/usr/bin/python3 /usr/local/lib/mqtt-colota/receiver.py
Restart=always
RestartSec=5s
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mqtt-colota > /dev/null 2>&1
  systemctl restart mqtt-colota
  ok "Colota receiver listens on port $COLOTA_PORT"
}

check_services() {
  sleep 2
  log "Services: $(systemctl is-active mosquitto mqtt-recorder mqtt-colota | tr '\n' ' ')"
}

main() {
  upgrade_os
  apt_install mosquitto mosquitto-clients python3-paho-mqtt
  setup_broker
  setup_recorder
  setup_colota_receiver
  check_services
}
SCRIPT
}

guest_main "$@"
