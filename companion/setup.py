#!/usr/bin/env python3
"""Local-only configuration wizard. Never discovers or rewrites boot entries automatically."""
import argparse
import datetime
import hashlib
import ipaddress
import json
import os
import platform
import secrets
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
import platform_ops


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dir', default='config')
    p.add_argument('--host', help='Reserved LAN IP or VPN DNS name used by iPhone')
    p.add_argument('--name',default='My PC'); p.add_argument('--machine-id',default='my-pc')
    p.add_argument('--mac',help='PC Ethernet MAC, e.g. AA:BB:CC:DD:EE:FF')
    p.add_argument('--broadcast',default='192.168.1.255')
    p.add_argument('--port',type=int,default=45831)
    p.add_argument('--relay',action='store_true')
    p.add_argument('--list-boots',action='store_true')
    p.add_argument('--linux-entry'); p.add_argument('--windows-entry')
    p.add_argument('--enable-power',action='store_true',help='Enable actual power/firmware/WOL operations')
    a=p.parse_args(); dest=Path(a.dir).resolve()
    if a.list_boots:
        print(json.dumps(platform_ops.boot_entries(),indent=2)); return
    if not a.host or not a.mac:
        p.error('--host and --mac are required')
    platform_ops.magic_packet(a.mac)
    ipaddress.IPv4Address(a.broadcast)
    if not 1024<=a.port<=65535:
        p.error('Use a port between 1024 and 65535')
    if any(c in a.host for c in '/:@?# \\'):
        p.error('Use an IPv4 address or DNS hostname, without a URL/port')
    if not a.machine_id or len(a.machine_id)>80:
        p.error('Invalid machine ID')
    if dest.exists():
        p.error('Config directory already exists. Preserve it; choose a new directory to rotate pairing.')
    entries={k:v.upper() for k,v in [('linux',a.linux_entry),('windows',a.windows_entry)] if v}
    if a.relay and entries:
        p.error('Relay cannot have boot entries')
    if entries:
        found=platform_ops.boot_entries()
        for v in entries.values():
            if v not in found:
                p.error(f'Entry {v} is not an active firmware boot entry')
    if len(set(entries.values()))!=len(entries):
        p.error('Linux and Windows must have different boot entries')
    dest.mkdir(mode=0o700,parents=True)
    key=rsa.generate_private_key(public_exponent=65537,key_size=3072)
    subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'PowerBridge')])
    now=datetime.datetime.now(datetime.timezone.utc)
    try: san=x509.IPAddress(ipaddress.ip_address(a.host))
    except ValueError: san=x509.DNSName(a.host)
    cert=(x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
          .public_key(key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(days=3650))
          .add_extension(x509.SubjectAlternativeName([san]),critical=False).sign(key,hashes.SHA256()))
    cfg={'name':a.name,'machine_id':a.machine_id,'os':platform.system().lower(),
         'role':'relay' if a.relay else 'pc','dry_run':not a.enable_power,'bind':'0.0.0.0','port':a.port,
         'mac':a.mac.upper(),'broadcast':a.broadcast,'secret':secrets.token_hex(32),'boot_entries':entries}
    endpoint={'url':f'https://{a.host}:{a.port}','secret':cfg['secret'],
              'pin':hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest(),
              'role':cfg['role'],'os':cfg['os']}
    pairing={'id':a.machine_id,'name':a.name,'mac':cfg['mac'],'broadcast':a.broadcast,'endpoints':[endpoint]}
    files={'config.json':json.dumps(cfg,indent=2).encode(),'pairing.json':json.dumps(pairing,indent=2).encode(),
           'cert.pem':cert.public_bytes(serialization.Encoding.PEM),
           'key.pem':key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())}
    for name,raw in files.items():
        path=dest/name; path.write_bytes(raw); path.chmod(0o600)
    print(f'Created {dest}. Dry run: {cfg["dry_run"]}.')
    print('Import pairing.json into the iPhone app using Files or paste its contents. Keep it private.')
    print('On Windows, run install-windows.ps1 to restrict file permissions before starting the service.')

if __name__=='__main__': main()
