#!/usr/bin/env python3
"""PowerBridge TLS/HMAC companion, Python 3.11+. Run setup.py first."""
import argparse
import hashlib
import hmac
import json
import logging
import platform
import re
import ssl
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import platform_ops


def signature(secret, method, path, timestamp, nonce, body):
    payload = '\n'.join([method, path, timestamp, nonce, hashlib.sha256(body).hexdigest()])
    return hmac.new(bytes.fromhex(secret), payload.encode(), hashlib.sha256).hexdigest()


class Auth:
    def __init__(self, secret):
        self.secret, self.nonces, self.lock = secret, {}, threading.Lock()

    def verify(self, method, path, headers, body):
        stamp, nonce, signed = [headers.get(k, '') for k in ('X-PB-Time', 'X-PB-Nonce', 'X-PB-Signature')]
        now = time.time()
        if not re.fullmatch(r'\d{10}', stamp) or abs(now-int(stamp)) > 60:
            return False
        if not re.fullmatch(r'[a-f0-9]{32}', nonce) or not re.fullmatch(r'[a-f0-9]{64}', signed):
            return False
        if not hmac.compare_digest(signature(self.secret, method, path, stamp, nonce, body), signed):
            return False
        with self.lock:
            self.nonces = {n: t for n,t in self.nonces.items() if t > now-125}
            if nonce in self.nonces or len(self.nonces) >= 10000:
                return False
            self.nonces[nonce] = now
        return True


class Controller:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.RLock()
        self.pending = None
        self.history = deque(maxlen=40)
        self.started = time.monotonic()

    def record(self, message):
        self.history.appendleft({'time': int(time.time()), 'message': message})
        logging.info(message)

    def status(self):
        with self.lock:
            return {'name': self.cfg['name'], 'os': self.cfg['os'], 'role': self.cfg['role'],
                    'dry_run': self.cfg['dry_run'], 'uptime': int(time.monotonic()-self.started),
                    'boot_targets': sorted(self.cfg['boot_entries']),
                    'pending': self.pending, 'history': list(self.history)}

    def action(self, data):
        if not isinstance(data, dict) or set(data)-{'action','target','delay'}:
            raise ValueError('Invalid command fields')
        action, target, delay = data.get('action'), data.get('target', ''), data.get('delay', 10)
        if action not in ('shutdown','restart','boot','cancel','wake'):
            raise ValueError('Unknown action')
        if type(delay) is not int or not 5 <= delay <= 3600:
            raise ValueError('Delay must be 5–3600 seconds')
        if not isinstance(target,str) or target not in ('', 'linux','windows'):
            raise ValueError('Unknown OS target')
        with self.lock:
            if self.cfg['role'] == 'relay':
                if action != 'wake' or target:
                    raise ValueError('Relay only supports waking its configured PC')
                if not self.cfg['dry_run']:
                    platform_ops.wake(self.cfg['mac'], self.cfg['broadcast'])
                self.record('Wake packet sent' if not self.cfg['dry_run'] else 'DRY RUN: wake packet')
                return self.status()
            if action == 'wake':
                raise ValueError('Use an always-on relay or direct iPhone wake')
            if action == 'cancel':
                self.pending = None
                self.record('Pending power action cancelled')
                return self.status()
            if self.pending:
                raise ValueError('Cancel the pending action first')
            if action == 'boot' and not target:
                raise ValueError('Select a boot target')
            if target and target not in self.cfg['boot_entries']:
                raise ValueError('OS has no configured UEFI entry')
            # Verify before accepting a request, and again before execution.
            if target and not self.cfg['dry_run']:
                entry = self.cfg['boot_entries'][target]
                if entry not in platform_ops.boot_entries():
                    raise ValueError('Configured UEFI entry unavailable')
            self.pending = {'action':action, 'target':target, 'at':int(time.time())+delay}
            self.record(f'Scheduled {action}' + (f' → {target}' if target else ''))
            return self.status()

    def tick(self):
        with self.lock:
            if not self.pending or self.pending['at'] > time.time():
                return
            p, self.pending = self.pending, None
            try:
                if self.cfg['dry_run']:
                    self.record(f"DRY RUN: {p['action']} target={p['target'] or 'default'}")
                    return
                if p['target']:
                    platform_ops.set_boot(self.cfg['boot_entries'][p['target']])
                platform_ops.power('restart' if p['action']=='boot' else p['action'])
                self.record('Power command submitted to OS')
            except Exception as e:
                self.record(f'Failed: {e}. If BootNext was set, it may still apply at next boot.')


class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, cfg):
        super().__init__(address, Handler)
        self.controller = Controller(cfg)
        self.auth = Auth(cfg['secret'])
        self.slots = threading.BoundedSemaphore(16)
    def process_request(self, request, client_address):
        if not self.slots.acquire(False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise
    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    server_version = 'PowerBridge/1'
    def setup(self):
        self.request.settimeout(5)
        super().setup()
    def log_message(self, *_):
        pass
    def reply(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(raw)))
        self.send_header('Cache-Control','no-store')
        self.end_headers()
        self.wfile.write(raw)
    def do_GET(self):
        self.handle_api()
    def do_POST(self):
        self.handle_api()
    def handle_api(self):
        try:
            if self.headers.get('Transfer-Encoding'):
                return self.reply(400, {'error':'Chunked requests unsupported'})
            length = int(self.headers.get('Content-Length','0'))
            if length < 0 or length > 4096:
                return self.reply(413, {'error':'Request too large'})
            body = self.rfile.read(length)
            if not self.server.auth.verify(self.command, self.path, self.headers, body):
                return self.reply(401, {'error':'Authentication failed. Check pairing and clock synchronization.'})
            if self.command=='GET' and self.path=='/v1/status':
                return self.reply(200, self.server.controller.status())
            if self.command=='POST' and self.path=='/v1/action':
                return self.reply(200, self.server.controller.action(json.loads(body)))
            self.reply(404, {'error':'Unknown endpoint'})
        except (ValueError, TypeError) as e:
            self.reply(400, {'error':str(e)})
        except Exception:
            logging.exception('Request failed')
            self.reply(500, {'error':'PC operation failed. Check companion logs.'})


def main():
    p=argparse.ArgumentParser(); p.add_argument('--config', required=True); a=p.parse_args()
    path=Path(a.config).resolve(); cfg=json.loads(path.read_text())
    if cfg['os'] != platform.system().lower() and cfg['role'] != 'relay':
        raise SystemExit('Configuration OS does not match this computer')
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
    srv=Server((cfg['bind'],cfg['port']),cfg)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(path.parent/'cert.pem',path.parent/'key.pem')
    # Delay handshakes until worker threads so one slow peer cannot block accept().
    srv.socket=context.wrap_socket(srv.socket,server_side=True,do_handshake_on_connect=False)
    stop=threading.Event()
    def worker():
        while not stop.wait(0.5):
            srv.controller.tick()
    threading.Thread(target=worker,daemon=True).start()
    logging.info('PowerBridge listening; dry_run=%s',cfg['dry_run'])
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set(); srv.server_close()

if __name__=='__main__':
    main()
