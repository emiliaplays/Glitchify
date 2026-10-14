"""Create a PRIVATE, short-lived paired test IPA locally. Never upload its output.

Requires cryptography. The public CI artifact contains no identity or access key.
Each invocation creates a fresh private CA, TLS identity and random access key.
"""
import argparse
from datetime import datetime, timedelta, timezone
import ipaddress
from pathlib import Path
import plistlib
import secrets
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

PHONE = 'Payload/Spotify.app/'
WATCH = PHONE + 'Watch/GlitchifyWatch.app/'


def make_identity():
    now = datetime.now(timezone.utc)
    root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Glitchify temporary local pairing')])
    leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'glitchify.local')])
    root = (x509.CertificateBuilder().subject_name(root_name).issuer_name(root_name)
        .public_key(root_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=2))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
        .sign(root_key, hashes.SHA256()))
    leaf = (x509.CertificateBuilder().subject_name(leaf_name).issuer_name(root_name)
        .public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.SubjectAlternativeName([x509.DNSName('glitchify.local')]), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), critical=True)
        .sign(root_key, hashes.SHA256()))
    password = secrets.token_hex(32)
    # Apple PKCS#12 import compatibility. TLS uses modern negotiated ciphers;
    # this password protects only the identity container inside the private IPA.
    encryption = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
        .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
        .hmac_hash(hashes.SHA1()).build(password.encode()))
    identity = pkcs12.serialize_key_and_certificates(b'Glitchify relay', leaf_key, leaf, [root], encryption)
    return identity, password, root.public_bytes(serialization.Encoding.DER)


def pair(source, output, host=''):
    source, output = Path(source), Path(output)
    if output.exists() or source.resolve() == output.resolve():
        raise ValueError('Refusing to overwrite an existing file')
    if host:
        address = ipaddress.IPv4Address(host)
        if not any(address in ipaddress.IPv4Network(net) for net in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
            raise ValueError('Expected private WLAN address')
    identity, password, root = make_identity()
    token = secrets.token_hex(32)
    additions = {
        PHONE + 'GlitchifyRelayIdentity.p12': identity,
        PHONE + 'GlitchifyRelayPairing.plist': plistlib.dumps({'enabled': True, 'token': token, 'password': password}),
        WATCH + 'GlitchifyRelayPairing.plist': plistlib.dumps({'token': token, 'root': root}),
    }
    with zipfile.ZipFile(source) as old:
        names = old.namelist()
        if len(names) != len(set(names)) or old.testzip() or any(name in names for name in additions):
            raise ValueError('Invalid or already paired source')
        info = plistlib.loads(old.read(PHONE + 'Info.plist'))
        wi = plistlib.loads(old.read(WATCH + 'Info.plist'))
        if info.get('GlitchifyPhoneRelayRevision') != '1.1-phone-relay-probe.1' or wi.get('GlitchifyPrototypeRevision') != '1.1-phone-relay-probe.1':
            raise ValueError('Expected the finite relay diagnostic')
        info['NSLocalNetworkUsageDescription'] = 'Sendet auf deine Anfrage Musik an deine gekoppelte Watch im selben WLAN.'
        if host:
            wi['GlitchifyPhoneRelayHost'] = host
        modified = {PHONE + 'Info.plist': plistlib.dumps(info), WATCH + 'Info.plist': plistlib.dumps(wi)}
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as new:
            for entry in old.infolist():
                new.writestr(entry, modified.get(entry.filename, old.read(entry)))
            for name, data in additions.items():
                new.writestr(name, data)
    with zipfile.ZipFile(source) as old, zipfile.ZipFile(output) as new:
        assert not new.testzip() and set(new.namelist()) == set(names) | additions.keys()
        assert all(new.read(name) == modified.get(name, old.read(name)) for name in names)
    print('Private paired IPA created. TLS identity expires in one day. Re-sign locally; do not publish this file.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phone-host', default='')
    args = parser.parse_args()
    pair(args.source, args.output, args.phone_host)
