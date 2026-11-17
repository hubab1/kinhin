import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'ci/simslim/benchmark.py'
spec = importlib.util.spec_from_file_location('simulator_benchmark', MODULE)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class SimulatorBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.runtimes = [dict(identifier='iOS-18-6', isAvailable=True, version='18.6'),
                         dict(identifier='iOS-27-1', isAvailable=True, version='27.1')]
        self.types = [dict(identifier='iPhone-16-Pro'), dict(identifier='iPhone-17-Pro')]
        self.inventory = {'devices': {'iOS-18-6': [dict(name='GitHub Actions iPhone', deviceTypeIdentifier='iPhone-16-Pro')]}}

    def test_newer_preview_runtime_does_not_replace_the_production_configuration(self):
        runtime, device_type = benchmark.production_configuration(self.runtimes, self.types, self.inventory)
        self.assertEqual(runtime['identifier'], 'iOS-18-6')
        self.assertEqual(device_type['identifier'], 'iPhone-16-Pro')

    def test_missing_template_refuses_to_benchmark_an_arbitrary_device(self):
        with self.assertRaisesRegex(RuntimeError, 'one production'):
            benchmark.production_configuration(self.runtimes, self.types, {'devices': {}})

    def test_unavailable_production_runtime_refuses_preview_fallback(self):
        self.runtimes[0]['isAvailable'] = False
        with self.assertRaisesRegex(RuntimeError, 'must be available'):
            benchmark.production_configuration(self.runtimes, self.types, self.inventory)


if __name__ == '__main__':
    unittest.main()
