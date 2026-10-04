import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from server import Auth, Controller, Server, signature
from platform_ops import magic_packet

SECRET='ab'*32

def config(role='pc'):
    return {'name':'Test PC','os':'linux','role':role,'dry_run':True,'secret':SECRET,
            'boot_entries':{'linux':'0001','windows':'0002'},'mac':'00:11:22:33:44:55','broadcast':'192.168.1.255'}

def headers(body=b'', method='GET', path='/v1/status', nonce=None, stamp=None):
    nonce=nonce or secrets.token_hex(16); stamp=stamp or str(int(time.time()))
    return {'X-PB-Time':stamp,'X-PB-Nonce':nonce,'X-PB-Signature':signature(SECRET,method,path,stamp,nonce,body)}

class AuthTests(unittest.TestCase):
    def test_valid_and_replay(self):
        auth=Auth(SECRET); h=headers()
        self.assertTrue(auth.verify('GET','/v1/status',h,b''))
        self.assertFalse(auth.verify('GET','/v1/status',h,b''))
    def test_tampered_body(self):
        self.assertFalse(Auth(SECRET).verify('GET','/v1/status',headers(),b'bad'))
    def test_wrong_path(self):
        self.assertFalse(Auth(SECRET).verify('GET','/v1/action',headers(),b''))
    def test_expired(self):
        self.assertFalse(Auth(SECRET).verify('GET','/v1/status',headers(stamp=str(int(time.time())-90)),b''))
    def test_malformed(self):
        self.assertFalse(Auth(SECRET).verify('GET','/v1/status',{},b''))
    def test_concurrent_replay(self):
        auth=Auth(SECRET); h=headers(); results=[]
        ts=[threading.Thread(target=lambda:results.append(auth.verify('GET','/v1/status',h,b''))) for _ in range(20)]
        for t in ts:t.start()
        for t in ts:t.join()
        self.assertEqual(sum(results),1)
    def test_signature_vector(self):
        # Stable interoperability vector also documented in docs/API.md.
        self.assertEqual(signature('00'*32,'POST','/v1/action','1700000000','1'*32,b'{"action":"shutdown","delay":10,"target":""}'),
                         '7787f86186ff393c381bee4cade135ce9cc6b5c17596a15b818ec628fe146a2d')

class ControllerTests(unittest.TestCase):
    def setUp(self): self.c=Controller(config())
    def test_cancel_prevents_power_and_boot(self):
        self.c.action({'action':'shutdown','target':'windows'})
        self.c.action({'action':'cancel'})
        with patch('platform_ops.power') as power, patch('platform_ops.set_boot') as boot:
            self.c.tick(); power.assert_not_called(); boot.assert_not_called()
    def test_dry_run(self):
        self.c.action({'action':'boot','target':'windows'}); self.c.pending['at']=0
        with patch('platform_ops.power') as power, patch('platform_ops.set_boot') as boot:
            self.c.tick(); power.assert_not_called(); boot.assert_not_called()
        self.assertIn('DRY RUN',self.c.history[0]['message'])
    def test_boot_failure_never_shuts_down(self):
        self.c.cfg['dry_run']=False
        self.c.pending={'action':'shutdown','target':'windows','at':0}
        with patch('platform_ops.set_boot',side_effect=RuntimeError('firmware rejected')) as boot, patch('platform_ops.power') as power:
            self.c.tick(); boot.assert_called_once_with('0002'); power.assert_not_called()
        self.assertIn('Failed',self.c.history[0]['message'])
    def test_boot_then_restart(self):
        self.c.cfg['dry_run']=False
        self.c.pending={'action':'boot','target':'linux','at':0}; calls=[]
        with patch('platform_ops.set_boot',side_effect=lambda x:calls.append(('boot',x))), patch('platform_ops.power',side_effect=lambda x:calls.append(('power',x))):
            self.c.tick()
        self.assertEqual(calls,[('boot','0001'),('power','restart')])
    def test_conflicting_action(self):
        self.c.action({'action':'shutdown'})
        with self.assertRaises(ValueError):self.c.action({'action':'restart'})
    def test_input_validation(self):
        for d in [{'action':'shell'},{'action':'shutdown','delay':True},{'action':'shutdown','delay':0},{'action':'boot'},{'action':'shutdown','target':'hack'},{'action':'shutdown','command':'x'},[],{'action':'shutdown','target':[]}]:
            with self.subTest(d=d),self.assertRaises(ValueError):self.c.action(d)
    def test_unmapped_target(self):
        self.c.cfg['boot_entries']={}
        with self.assertRaises(ValueError):self.c.action({'action':'boot','target':'linux'})
    def test_relay_rejects_power(self):
        c=Controller(config('relay'))
        with self.assertRaises(ValueError):c.action({'action':'shutdown'})
        with patch('platform_ops.wake') as wake:
            c.action({'action':'wake'}); wake.assert_not_called()
    def test_wake_packet(self):
        self.assertEqual(magic_packet('00:11:22:33:44:55'),b'\xff'*6+bytes.fromhex('001122334455')*16)
        with self.assertRaises(ValueError):magic_packet('$(shutdown)')

class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(); cls.dest=Path(cls.temp.name)/'config'
        subprocess.run([sys.executable,str(Path(__file__).resolve().parents[1]/'setup.py'),'--dir',str(cls.dest),'--host','127.0.0.1','--mac','00:11:22:33:44:55'],check=True,capture_output=True)
        cls.cfg=json.loads((cls.dest/'config.json').read_text()); cls.cfg['secret']=SECRET
        cls.srv=Server(('127.0.0.1',0),cls.cfg)
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cls.dest/'cert.pem',cls.dest/'key.pem')
        cls.srv.socket=ctx.wrap_socket(cls.srv.socket,server_side=True,do_handshake_on_connect=False)
        cls.thread=threading.Thread(target=cls.srv.serve_forever,daemon=True);cls.thread.start()
    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown();cls.srv.server_close();cls.thread.join();cls.temp.cleanup()
    def request(self,method,path,body=None,auth=True):
        raw=b'' if body is None else json.dumps(body).encode()
        h=headers(raw,method,path) if auth else {}
        conn=http.client.HTTPSConnection('127.0.0.1',self.srv.server_port,context=ssl.create_default_context(cafile=str(self.dest/'cert.pem')),timeout=3)
        conn.request(method,path,body=raw,headers=h);r=conn.getresponse();result=(r.status,json.loads(r.read()));conn.close();return result
    def test_tls_status(self):
        code,body=self.request('GET','/v1/status');self.assertEqual(code,200);self.assertTrue(body['dry_run'])
    def test_reject_anonymous(self):self.assertEqual(self.request('GET','/v1/status',auth=False)[0],401)
    def test_action_cancel(self):
        self.assertEqual(self.request('POST','/v1/action',{'action':'shutdown'})[0],200)
        code,body=self.request('POST','/v1/action',{'action':'cancel'});self.assertEqual(code,200);self.assertIsNone(body['pending'])
    def test_unknown_route(self):self.assertEqual(self.request('GET','/nope')[0],404)
    def test_bad_action(self):self.assertEqual(self.request('POST','/v1/action',{'action':'exec'})[0],400)
    def test_pairing_fingerprint(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
        cert=x509.load_pem_x509_certificate((self.dest/'cert.pem').read_bytes())
        pair=json.loads((self.dest/'pairing.json').read_text())
        self.assertEqual(pair['endpoints'][0]['pin'],hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest())

if __name__=='__main__':unittest.main()
