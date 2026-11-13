"""Local OpenSSH-compatible test server for the Flutter transport test."""

import base64
import hashlib
import http.server
import json
import os
import pathlib
import socket
import subprocess
import threading

import paramiko

root = pathlib.Path(__file__).resolve().parent.parent / ".tools"
root.mkdir(exist_ok=True)

def key_file(name):
    target = root / name
    if not target.exists():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(target)], check=True)
    return target

class Api(http.server.BaseHTTPRequestHandler):
    payload = b""

    def log_message(self, *_args):
        pass

    def emit(self, data, kind="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def valid(self):
        if self.headers.get("Authorization") != "Bearer " + "9" * 64:
            self.send_error(401)
            return False
        return True

    def do_GET(self):
        if not self.valid():
            return
        if self.path.endswith("/health"):
            self.emit(b'{"ok":true,"protocol":1,"maxUploadBytes":209715200}')
        elif "/events?" in self.path:
            self.emit(b'data: {"type":"ready"}\n\n', "text/event-stream")
        else:
            self.emit(Api.payload, "application/octet-stream")

    def do_POST(self):
        if self.valid():
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.emit(b'{"ok":true}')

    def do_PUT(self):
        if self.valid():
            Api.payload = self.rfile.read(int(self.headers["Content-Length"]))
            self.emit(b'{"ok":true,"attachment":{"id":"test-attachment"}}')

api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
threading.Thread(target=api.serve_forever, daemon=True).start()
api_port = int(os.environ.get("WORLDLINEBOX_TEST_TARGET_PORT", api.server_port))
token = os.environ.get("WORLDLINEBOX_TEST_TARGET_TOKEN", "9" * 64)
ssh = socket.create_server(("127.0.0.1", 0))
host_key = paramiko.Ed25519Key.from_private_key_file(str(key_file("test-host-key")))
client_key_path = key_file("test-client-key")
client_key = paramiko.Ed25519Key.from_private_key_file(str(client_key_path))
fingerprint = base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")

class Handler(paramiko.ServerInterface):
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "fixture" and key == client_key else paramiko.AUTH_FAILED

    def get_allowed_auths(self, _username):
        return "publickey"

    def check_channel_direct_tcpip_request(self, _channel, _origin, destination):
        return paramiko.OPEN_SUCCEEDED if destination == ("127.0.0.1", api_port) else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

def forward(channel):
    def to_host(upstream):
        try:
            while data := channel.recv(65536):
                upstream.sendall(data)
            upstream.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    with socket.create_connection(("127.0.0.1", api_port)) as upstream:
        threading.Thread(target=to_host, args=(upstream,), daemon=True).start()
        try:
            while data := upstream.recv(65536):
                channel.sendall(data)
            channel.shutdown_write()
        except OSError:
            pass
        finally:
            channel.close()

def connection(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    try:
        transport.start_server(server=Handler())
        while transport.is_active():
            channel = transport.accept(1)
            if channel:
                threading.Thread(target=forward, args=(channel,), daemon=True).start()
    except (paramiko.SSHException, EOFError, OSError):
        pass
    finally:
        transport.close()

profile = root / os.environ.get("WORLDLINEBOX_TEST_PROFILE_NAME", "ssh-fixture.json")
profile.write_text(json.dumps({
    "host": "127.0.0.1", "sshPort": ssh.getsockname()[1], "username": "fixture",
    "fingerprint": "SHA256:" + fingerprint, "apiPort": api_port,
    "token": token, "privateKey": client_key_path.read_text(),
}), encoding="utf-8")
print(profile, flush=True)
while True:
    client, _ = ssh.accept()
    threading.Thread(target=connection, args=(client,), daemon=True).start()
