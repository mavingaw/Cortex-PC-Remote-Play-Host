#!/usr/bin/env python3
"""Minimal stand-in for Razer PC Remote Play Host's HTTP(S) side.

Implements the pairing protocol exactly as src/nvhttp.cpp + src/crypto.cpp in the
host repo do it, plus /serverinfo, /applist, /launch, /resume, /cancel, /unpair.
Every request is appended as JSON to the log file so a test can inspect what the
client sent. The stream itself is not implemented: /launch answers with an RTSP
URL on a closed port, so the client fails right after the launch request.

usage: fake_host.py <workdir> <pin>
"""
import base64, datetime, hashlib, http.server, json, os, secrets, ssl, sys, threading, urllib.parse, uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.x509.oid import NameOID

WORK = sys.argv[1]
PIN = sys.argv[2]
LOG = os.path.join(WORK, "requests.jsonl")
HTTP_PORT, HTTPS_PORT = 47989, 47984
UNIQUE_ID = str(uuid.uuid4())

# ----------------------------------------------------------------------------- server identity
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "FakeRazerHost")])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650)).sign(key, hashes.SHA256()))
CERT_PEM = cert.public_bytes(serialization.Encoding.PEM)
KEY_PEM = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())
open(os.path.join(WORK, "server.crt"), "wb").write(CERT_PEM)
open(os.path.join(WORK, "server.key"), "wb").write(KEY_PEM)

sessions = {}   # uniqueid -> dict(aeskey, serversecret, serverchallenge, clienthash, clientcert)
paired = set()  # client cert PEMs that completed pairing
lock = threading.Lock()

def sha256(b): return hashlib.sha256(b).digest()
def ecb(keyb): return Cipher(algorithms.AES(keyb), modes.ECB())
def ecb_encrypt(keyb, data):
    e = ecb(keyb).encryptor(); return e.update(data) + e.finalize()
def ecb_decrypt(keyb, data):
    d = ecb(keyb).decryptor(); return d.update(data) + d.finalize()
# 1x1 green PNG used as remote "Cortex library" box art
TEST_ART_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

def xml(fields, status=200, msg=None):
    body = "".join(f"<{k}>{v}</{k}>" for k, v in fields.items())
    attrs = f' status_code="{status}"' + (f' status_message="{msg}"' if msg else "")
    return f'<?xml version="1.0" encoding="utf-8"?><root protocol_version="0.1"{attrs}>{body}</root>'

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        args = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
        https = isinstance(self.server, HttpsServer)
        with lock, open(LOG, "a") as f:
            f.write(json.dumps({"https": https, "path": u.path, "query": u.query, "args": args}) + "\n")
        try:
            body = self.route(u.path, args, https)
        except Exception as e:  # noqa
            body = xml({}, 500, f"exception: {e!r}")
        if body is None:
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "image/png" if isinstance(body, bytes) else "text/xml")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def route(self, path, args, https):
        if path == "/serverinfo":
            return xml({
                "hostname": "FakeRazerHost", "appversion": "7.1.431.0", "GfeVersion": "3.23.0.74",
                "uniqueid": UNIQUE_ID, "HttpsPort": HTTPS_PORT, "ExternalPort": HTTP_PORT,
                "MaxLumaPixelsHEVC": "1869449984", "mac": "00:11:22:33:44:55",
                "MachineIdentifier": "deadbeef", "LocalIP": "127.0.0.1",
                "PrimayMonitorHdrEnabled": 0, "CurrentSessionCount": 0,
                "ServerCodecModeSupport": 3, "PairStatus": 1 if https else 0,
                "currentgame": 0, "state": "SUNSHINE_SERVER_FREE"})
        if path == "/pair":
            return self.pair(args, https)
        if path == "/applist":
            # Like the real host: a Cortex library game carries a remote CustomImagePath
            # and a GamePlatform, and /appasset has nothing for it.
            return ('<?xml version="1.0" encoding="utf-8"?><root protocol_version="0.1" status_code="200">'
                    '<App><IsHdrSupported>0</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>1</ID></App>'
                    '<App><IsHdrSupported>0</IsHdrSupported><AppTitle>Test Game</AppTitle><ID>2</ID>'
                    f'<CustomImagePath>http://127.0.0.1:{HTTP_PORT}/testart.png</CustomImagePath>'
                    '<GamePlatform>Steam</GamePlatform></App></root>')
        if path == "/appasset":
            return None   # 204, as the host answers when the image path does not exist
        if path == "/testart.png":
            return TEST_ART_PNG
        if path in ("/launch", "/resume"):
            return xml({"sessionUrl0": "rtsp://127.0.0.1:1", "gamesession": 1})
        if path in ("/cancel", "/unpair"):
            return xml({"cancel": 1})
        return xml({}, 404, "not found")

    def pair(self, args, https):
        uid = args.get("uniqueid", "")
        sess = sessions.setdefault(uid, {})
        if args.get("phrase") == "getservercert":
            salt = bytes.fromhex(args["salt"])
            sess["clientcert"] = bytes.fromhex(args["clientcert"])
            sess["aeskey"] = sha256(salt + PIN.encode())[:16]          # crypto::gen_aes_key
            return xml({"paired": 1, "plaincert": CERT_PEM.hex()})
        if "clientchallenge" in args:
            decrypted = ecb_decrypt(sess["aeskey"], bytes.fromhex(args["clientchallenge"]))
            serversecret = secrets.token_bytes(16)
            h = sha256(decrypted + cert.signature + serversecret)      # crypto::signature(x509) = signatureValue
            serverchallenge = secrets.token_bytes(16)
            sess.update(serversecret=serversecret, serverchallenge=serverchallenge)
            return xml({"paired": 1, "challengeresponse": ecb_encrypt(sess["aeskey"], h + serverchallenge).hex()})
        if "serverchallengeresp" in args:
            sess["clienthash"] = ecb_decrypt(sess["aeskey"], bytes.fromhex(args["serverchallengeresp"]))
            sign = key.sign(sess["serversecret"], padding.PKCS1v15(), hashes.SHA256())   # crypto::sign256
            return xml({"paired": 1, "pairingsecret": (sess["serversecret"] + sign).hex()})
        if "clientpairingsecret" in args:
            blob = bytes.fromhex(args["clientpairingsecret"])
            secret, sign = blob[:16], blob[16:]
            client_cert = x509.load_pem_x509_certificate(sess["clientcert"])
            h = sha256(sess["serverchallenge"] + client_cert.signature + secret)
            ok_hash = h == sess["clienthash"][:32]
            try:
                client_cert.public_key().verify(sign, secret, padding.PKCS1v15(), hashes.SHA256())   # crypto::verify256
                ok_sig = True
            except Exception:
                ok_sig = False
            if ok_hash and ok_sig:
                paired.add(sess["clientcert"])
                return xml({"paired": 1})
            return xml({"paired": 0}, 400, f"hash_ok={ok_hash} sig_ok={ok_sig}")
        if args.get("phrase") == "pairchallenge":
            return xml({"paired": 1})
        return xml({}, 404, "Invalid pairing request")

class HttpsServer(http.server.ThreadingHTTPServer):
    pass

http_srv = http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), Handler)
https_srv = HttpsServer(("127.0.0.1", HTTPS_PORT), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(WORK, "server.crt"), os.path.join(WORK, "server.key"))
ctx.verify_mode = ssl.CERT_NONE
https_srv.socket = ctx.wrap_socket(https_srv.socket, server_side=True)
threading.Thread(target=http_srv.serve_forever, daemon=True).start()
print("fake host up: http", HTTP_PORT, "https", HTTPS_PORT, "pin", PIN, flush=True)
https_srv.serve_forever()
