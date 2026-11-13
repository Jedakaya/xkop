"""Exercise real curl against a local synthetic HTTP server, never a provider."""
import gzip
import http.server
import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        try:
            if self.path == '/slow':
                time.sleep(3)
            self.send_response(200)
            if self.path == '/headers':
                self.send_header('Announce', 'a' * 100000)
            if self.path == '/gzip':
                self.send_header('Content-Encoding', 'gzip')
            if self.path == '/partial':
                self.send_header('Content-Length', '1000')
            self.end_headers()
            if self.path in ('/gzip', '/raw-gzip'):
                body = gzip.compress(b'a' * 65536)
            elif self.path == '/large':
                body = b'a' * 65536
            else:
                body = b'valid'
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class SubscriptionHTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def fetch(self, route, decompress=False, deadline=False):
        library = Path(__file__).resolve().parents[1] / 'xkop/files/usr/lib/xkop/subscription.sh'
        with tempfile.TemporaryDirectory() as directory:
            script = '''set -u
. "$LIBRARY"
uci() { case "$*" in *subscription_max_bytes) echo 1024;; *) return 1;; esac; }
subscription_hwid() { echo fixture; }
subscription_device_model() { echo fixture; }
if [ "$DEADLINE" = 1 ]; then XKOP_SUBSCRIPTION_DEADLINE=$(( $(subscription_clock) + 1 )); fi
subscription_fetch_one "$URL" fixture "$OUT/body" "$OUT/headers" || exit 1
if [ "$DECOMPRESS" = 1 ]; then subscription_decompress_gzip "$OUT/body" || exit 1; fi
'''
            env = dict(os.environ, LIBRARY=str(library), OUT=directory,
                       URL=f'http://127.0.0.1:{self.server.server_port}{route}',
                       DECOMPRESS=str(int(decompress)), DEADLINE=str(int(deadline)),
                       NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
            start = time.monotonic()
            result = subprocess.run(['sh', '-c', script], env=env, capture_output=True, timeout=8, check=False)
            body = Path(directory) / 'body'
            data = body.read_bytes() if body.exists() else None
            return result.returncode, data, time.monotonic() - start

    def test_small_response(self):
        code, data, _ = self.fetch('/ok')
        self.assertEqual((code, data), (0, b'valid'))

    def test_chunked_or_unknown_length_bound(self):
        code, data, _ = self.fetch('/large')
        self.assertEqual(code, 1)
        self.assertIsNone(data)

    def test_curl_decompression_bound(self):
        code, data, _ = self.fetch('/gzip')
        self.assertEqual(code, 1)
        self.assertIsNone(data)

    def test_unannounced_gzip_bound(self):
        code, data, _ = self.fetch('/raw-gzip', decompress=True)
        self.assertEqual(code, 1)
        self.assertLess(len(data), 1024)

    def test_header_file_bound(self):
        code, data, _ = self.fetch('/headers')
        self.assertEqual(code, 1)
        self.assertIsNone(data)

    def test_partial_transfer_rejected(self):
        code, data, _ = self.fetch('/partial')
        self.assertEqual(code, 1)
        self.assertIsNone(data)

    def test_total_deadline_applies_to_request(self):
        code, data, elapsed = self.fetch('/slow', deadline=True)
        self.assertEqual(code, 1)
        self.assertIsNone(data)
        self.assertLess(elapsed, 3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
