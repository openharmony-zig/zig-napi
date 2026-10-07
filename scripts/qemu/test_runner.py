"""Regression checks for release integrity and full-system readiness failures."""
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

from boot_ohos_guest import account_ready, qmp_command, verify_archive


class RunnerTests(unittest.TestCase):
    def test_corrupted_image_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.tar.gz'
            image.write_bytes(b'original release')
            expected = hashlib.sha256(image.read_bytes()).hexdigest()
            self.assertEqual(verify_archive(image, expected), expected)
            image.write_bytes(b'corrupted release')
            with self.assertRaisesRegex(RuntimeError, 'SHA256 mismatch'):
                verify_archive(image, expected)

    def test_hdc_alone_is_not_hap_readiness(self):
        ready = 'bootevent.account.ready=true\nID: 100\nisForeground: 1\n'
        self.assertTrue(account_ready(ready))
        for incomplete in (ready.replace('ready=true', 'ready=false'),
                           ready.replace('ID: 100', 'ID: 0'),
                           ready.replace('isForeground: 1', 'isForeground: 0'),
                           ready.replace('ID: 100', 'ID: 1000'),
                           ready.replace('isForeground: 1', 'isForeground: 0') + 'ID: 101\nisForeground: 1\n'):
            with self.subTest(state=incomplete):
                self.assertFalse(account_ready(incomplete))

    def test_qmp_disconnect_fails_without_hanging(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'qmp.sock'
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)

                def disconnect():
                    client, _ = server.accept()
                    with client:
                        client.sendall((json.dumps({'QMP': {}}) + '\n').encode())
                        client.recv(4096)

                thread = threading.Thread(target=disconnect)
                thread.start()
                try:
                    with self.assertRaisesRegex(RuntimeError, 'disconnected'):
                        qmp_command(path, 'query-status')
                finally:
                    thread.join(timeout=10)
                self.assertFalse(thread.is_alive())

    def test_product_prerequisites_fail_before_build(self):
        script = Path(__file__).with_name('run_matrix.py')
        for product, missing in [('ohos', '--ohos-zig'), ('node', '--node-guest'), ('both', '--ohos-zig')]:
            with self.subTest(product=product):
                result = subprocess.run([sys.executable, str(script), '--product', product,
                                         '--output', '/unused'], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn(missing + ' is required', result.stderr)


if __name__ == '__main__':
    unittest.main()
