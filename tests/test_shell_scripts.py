import unittest
import os

from pathlib import Path
from subprocess import Popen, PIPE

import quippytest

class TestShellScripts(quippytest.QuippyTestCase):
    def test_shell_scripts(self):
        if 'QUIP_WHEEL_TEST' in os.environ:
            print(f'Skipping test when testing built wheels')
            return
        
        for f in Path(__file__).parent.glob('test_*.sh'):
            print("shell script test", f)

            p = Popen([f], stdout=PIPE, stderr=PIPE)
            stdout, stderr = p.communicate()

            self.assertEqual(p.returncode, 0, f'Shell script test {f} failed with error code '
                                              f'{p.returncode} stderr {stderr.decode()} stdout {stdout.decode()}')


if __name__ == '__main__':
    unittest.main()
