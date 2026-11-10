"""Process-bounded lifecycle tests; no graphics or audio implementation is loaded."""
import os
from pathlib import Path
import subprocess
import unittest

EXE = Path(os.environ.get('DM_TEST_LIFECYCLE', Path(__file__).parent / 'build/t_lifecycle_exit')).resolve()


class LifecycleExit(unittest.TestCase):
    def child(self, *args, timeout=4):
        result = subprocess.run([str(EXE), *args], capture_output=True, text=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_hard_first_skips_callback(self):
        self.assertNotIn('callback', self.child('hard-first').stdout)

    def test_started_callback_is_not_reentered(self):
        self.assertEqual(self.child('started').stdout.count('callback'), 1)

    def test_normal_callback_runs_once(self):
        self.assertEqual(self.child('normal').stdout.count('callback'), 1)

    def test_hard_exit_without_callback(self):
        self.assertNotIn('callback', self.child('hard-null').stdout)

    def test_hard_exit_does_not_wait_for_log_lock(self):
        self.assertNotIn('callback', self.child('hard-log').stdout)

    def test_configuration(self):
        for value, expected in [('<unset>', 8000), ('', 8000), ('0', 0), ('17', 17),
                                ('  +2500 ', 2500), ('2147483647', 2147483647),
                                ('-1', 8000), ('junk', 8000), ('12ms', 8000),
                                ('2147483648', 8000), ('999999999999999999999', 8000)]:
            with self.subTest(value=value):
                self.child('config', value, str(expected))


if __name__ == '__main__':
    unittest.main()
