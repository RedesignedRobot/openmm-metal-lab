"""CPU-only campaign contract checks. No OpenMM imports or contexts, real prepares or runs."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, TOOLS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


holdout = load('holdout_under_test', 'holdout.py')
campaign = load('campaign_under_test', 'window-m029-summary.py')


def evidence(name, text):
    if os.environ.get('M029_EVIDENCE'):
        path = Path(os.environ['M029_EVIDENCE'])
        path.mkdir(parents=True, exist_ok=True)
        (path / name).write_text(text)


class PropertyContract(unittest.TestCase):
    def test_match_and_every_property_mismatch(self):
        requested = holdout.requested_properties('Metal', 'mixed', {
            'DeviceIndex': '0', 'DisablePmeStream': 'true', 'DeterministicForces': 'true'})
        receipt = holdout.verify_properties(requested, requested)
        self.assertEqual(receipt['requested_properties'], receipt['effective_properties'])
        for key, wrong in [('Precision', 'single'), ('DeviceIndex', '1'),
                           ('DisablePmeStream', 'false'), ('DeterministicForces', 'false')]:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'Context property mismatch'):
                holdout.verify_properties(requested, dict(requested, **{key: wrong}))
        trap = holdout.requested_properties('Metal', 'mixed', {'DisablePmeStream': '1'})
        with self.assertRaisesRegex(ValueError, 'Context property mismatch'):
            holdout.verify_properties(trap, {'Precision': 'mixed', 'DisablePmeStream': 'false'})
        print('property maps: match PASS; all four mismatches rejected; requested "1" / effective "false" rejected')

    def test_opencl_unsupported_key_rejected_before_import_or_context(self):
        with patch.dict(sys.modules, {'openmm': None, 'numpy': None}):
            with self.assertRaisesRegex(ValueError, 'OpenCL: unsupported properties.*DeterministicForces'):
                holdout.worker('/does-not-exist', 'OpenCL', 'single', {'DeterministicForces': 'true'})
        print('OpenCL DeterministicForces rejected before imports, context creation and timing')

    def test_sample_attests_before_timing_and_records_counters_as_unavailable(self):
        step = 'reorder-cost-tip4pew'
        props = campaign.context_properties(step, 'Metal', 'mixed')
        for step, arm, mismatch in [(step, 0, False), (step, 0, True)] + [
                ('fah-owner-' + unit, arm, mismatch) for unit in campaign.FAH_UNITS
                for arm in (0, 1) for mismatch in (False, True)]:
            props = campaign.context_properties(step, 'Metal', 'mixed')
            with self.subTest(step=step, arm=arm, mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                effective = dict(props, DisablePmeStream='false') if mismatch else props
                calls = []

                class Process:
                    def poll(self):
                        return 0

                class Worker:
                    process = Process()

                    def __init__(self, *args, properties):
                        self.properties = properties

                    def read(self):
                        return dict(ready=True, requested_properties=self.properties, effective_properties=effective)

                    def send(self, command):
                        calls.append(command)
                        return dict(warm_us=100, steps=10, seconds=0.001,
                                    **holdout.verify_properties(self.properties, effective))

                with patch.object(campaign, 'guard'), patch.object(campaign, 'holdout_module', return_value=holdout), \
                        patch.object(holdout, 'Worker', Worker), \
                        patch.dict(os.environ, {'GPUQ_JOB': 'cpu-test', 'OPENMM_LEASE_PID': 'cpu-test'}):
                    if mismatch:
                        with self.assertRaisesRegex(ValueError, 'Context property mismatch'):
                            campaign.sample(step, arm, output, 30, False)
                        self.assertEqual(calls, [])
                        self.assertFalse((output / 'result.json').exists())
                    else:
                        campaign.sample(step, arm, output, 30, False)
                        row = json.loads((output / 'result.json').read_text())
                        self.assertEqual(row['requested_properties'], props)
                        self.assertEqual(row['effective_properties'], props)
                        if step.startswith('reorder-cost-'):
                            self.assertIsNone(row['diagnostics']['reorder_count'])
                            self.assertIsNone(row['diagnostics']['tile_count'])
                        else:
                            self.assertEqual(row['environment_settings']['OPENMM_METAL_PME_OWNER'], str(arm))

    def test_opencl_mixed_failure_preserves_stderr_without_timing(self):
        step = 'fah-map-ocl-mixed-tip4pew'
        props = campaign.context_properties(step, 'OpenCL', 'mixed')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)

            class Process:
                def poll(self):
                    return 0

                def wait(self, timeout):
                    return 0

            class Worker:
                process = Process()

                def __init__(self, *args, properties):
                    self.log_path = str(output / 'workers/failure.log')
                    Path(self.log_path).write_text('Selected device does not support double precision\n')

                def read(self):
                    return dict(ready=False, failure='context_creation_failed', requested_properties=props,
                                effective_properties={}, error='Selected device does not support double precision')

                def send(self, command):
                    raise AssertionError('failed context must not be timed')

            with patch.object(campaign, 'guard'), patch.object(campaign, 'holdout_module', return_value=holdout), \
                    patch.object(holdout, 'Worker', Worker), \
                    patch.dict(os.environ, {'GPUQ_JOB': 'cpu-test', 'OPENMM_LEASE_PID': 'cpu-test'}):
                campaign.sample(step, 1, output, 30, False)
            row = json.loads((output / 'result.json').read_text())
            self.assertEqual(row['status'], 'failed')
            self.assertNotIn('seconds', row)
            self.assertNotIn('us_per_step', row)
            self.assertNotIn('ratio', row)
            self.assertIn('double precision', (output / row['stderr_log']).read_text())


class CampaignContract(unittest.TestCase):
    def test_dry_runs_pending_and_explicit_maps(self):
        with tempfile.TemporaryDirectory() as directory:
            base = [str(TOOLS / 'window-m029.sh'), '--dry-run', '--out', directory]
            pending = subprocess.run(base, capture_output=True, text=True)
            self.assertEqual(pending.returncode, 0, pending.stderr)
            for name in ('stack4', 'pme-base', 'reorder-diag'):
                self.assertIn('PENDING --' + name + '-commit', pending.stdout)
            full = subprocess.run(base + ['--stack3-commit', '82cd1a2c6', '--stack4-commit', 'dbd483237',
                                  '--pme-base-commit', '9925fa322', '--reorder-diag-commit', '35930334d'],
                                  capture_output=True, text=True)
            self.assertEqual(full.returncode, 0, full.stderr)
            self.assertNotIn('PENDING --', full.stdout)
            self.assertEqual(list(Path(directory).iterdir()), [])
            for step in campaign.steps():
                self.assertIn('\n' + step + ':', full.stdout)
            for unit in campaign.FAH_UNITS:
                block = full.stdout.split('\nfah-owner-' + unit + ':', 1)[1].split('\n\n', 1)[0]
                self.assertIn('3x30s', block)
                self.assertIn('clear, bin, splines, gather, conversion', block)
                commands = [shlex.split(line[len('  payload: '):]) for line in block.splitlines()
                            if line.startswith('  payload: ')]
                self.assertEqual(len(commands), 2)
                for arm, command in enumerate(commands):
                    self.assertIn('OPENMM_METAL_PME_OWNER=' + str(arm), command)
                    for flag in ('DEVICE_BOX=1', 'DEVICE_BAROSTAT=1', 'COOP_SHAKE=0'):
                        self.assertIn('OPENMM_METAL_' + flag, command)
                    self.assertIn(str(campaign.arm('stack4') / 'venv/bin/python'), command)
                    self.assertEqual(json.loads(command[command.index('--properties') + 1]),
                                     dict(Precision='mixed', DeviceIndex='0', DisablePmeStream='true',
                                          DeterministicForces='true'))
            maps = set()
            for line in full.stdout.splitlines():
                if not line.startswith('  payload: ') or '--properties' not in line:
                    continue
                command = shlex.split(line[len('  payload: '):])
                index = command.index('--properties')
                props = json.loads(command[index + 1])
                platform, precision = command[index - 2:index]
                self.assertEqual(holdout.requested_properties(platform, precision, props), props)
                if platform == 'OpenCL':
                    self.assertNotIn('DeterministicForces', props)
                if platform == 'Metal' and 'DeviceIndex' in props:
                    maps.add((props['DisablePmeStream'], props['DeterministicForces']))
                    self.assertIn('OPENMM_METAL_COOP_SHAKE=0', command)
                    self.assertNotIn('OPENMM_METAL_COOP_SHAKE=1', command)
                    if not any(arg.startswith('OPENMM_METAL_PME_OWNER=') for arg in command):
                        self.assertIn('-u', command)
            self.assertEqual(maps, {('false', 'false'), ('false', 'true'), ('true', 'false'), ('true', 'true')})
            self.assertEqual(campaign.configurations('mission-tip4pew'),
                             [('candidate', 'Metal', 'mixed', {}), ('opencl', 'OpenCL', 'single', {})])
            self.assertEqual(campaign.context_properties('pme-energy-only-tip4pew', 'Metal', 'mixed'), {'Precision': 'mixed'})
            evidence('dry-run-pending.txt', pending.stdout)
            evidence('dry-run-shas.txt', full.stdout)

    def test_owner_executes_three_alternating_full_step_pairs(self):
        for unit in campaign.FAH_UNITS:
            with self.subTest(unit=unit), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                step = 'fah-owner-' + unit
                (out / 'campaign.json').write_text(json.dumps(dict(driver=campaign.digest(campaign.HERE),
                    arms={'tools': {}, 'holdout': 'frozen'})))
                calls = []

                def run_sample(command, log, any_hour):
                    self.assertEqual(command[2:4], ['sample', step])
                    arm, target, seconds = int(command[4]), command[5], command[6]
                    calls.append((arm, seconds))
                    (target / 'result.json').write_text(json.dumps({'us_per_step': 100 if arm == 0 else 80}))

                with patch.object(campaign, 'guard'), patch.object(campaign, 'ensure_clock'), \
                        patch.object(campaign, 'holdout_module', return_value=holdout), \
                        patch.object(holdout, 'verify', return_value='frozen'), \
                        patch.object(campaign, 'monitored', side_effect=run_sample):
                    campaign.execute_step(step, out / step, SimpleNamespace(out=out, any_hour=False))
                self.assertEqual(calls, [(0, '30'), (1, '30'), (1, '30'), (0, '30'), (0, '30'), (1, '30')])
                result = campaign.completed(out / step)
                self.assertEqual(result['ratio'], 1.25)
                self.assertEqual(result['saving_us'], 20)
                self.assertEqual(result['verdict'], 'full-path comparison; confirm required')
                self.assertIn('stack4 FAH map owner off', campaign.summary(out))

    def test_synthetic_receipts_report_both_references_and_raw_reorder(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            examples = {
                'fah-map-ocl-single-tip4pew': [[100, 100, 100], [220, 230, 210]],
                'fah-map-ocl-mixed-tip4pew': [[100, 100, 100], [180, 170, 190]],
                'reorder-cost-tip4pew': [[100, 100, 100], [100, 125, 80]],
            }
            for step, samples in examples.items():
                path = out / step
                path.mkdir()
                raw = path / 'synthetic.json'
                raw.write_text(json.dumps(samples))
                campaign.finish(path, campaign.comparison(step, samples), [raw])
            failed = out / 'fah-map-ocl-mixed-tip3p-hmr'
            failed.mkdir()
            campaign.finish(failed, dict(arm=failed.name, unit='tip3p-hmr', precision='mixed/OpenCL mixed',
                            ratio=None, spread=None, verdict='FAILED OpenCL mixed context creation'), [])
            text = campaign.summary(out)
            single = next(line for line in text.splitlines() if line.startswith('| fah-map-ocl-single-tip4pew |'))
            mixed = next(line for line in text.splitlines() if line.startswith('| fah-map-ocl-mixed-tip4pew |'))
            reorder = next(line for line in text.splitlines() if line.startswith('| reorder-cost-tip4pew |'))
            self.assertIn('2.2000 / OpenCL single FAH map', single)
            self.assertIn('TARGET MET', single)
            self.assertIn('1.8000 / OpenCL mixed FAH map', mixed)
            self.assertNotIn('TARGET MET', mixed)
            self.assertIn('1.0000 / stack4 FAH map | 45.00 pp | diagnostic only; no kill bar', reorder)
            self.assertNotIn('KILL', reorder)
            self.assertIn('n/a | n/a | FAILED OpenCL mixed context creation', text)
            evidence('synthetic-summary.txt', text)
            print('\n'.join([single, mixed, reorder]))


if __name__ == '__main__':
    unittest.main(verbosity=2)
