import importlib.util, pathlib, tempfile, unittest, zipfile, json, os, shutil

p = pathlib.Path(__file__).resolve().parents[1]
s = importlib.util.spec_from_file_location('uart', p / 'uart-logs.py')
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)


class Tests(unittest.TestCase):
    def test_context_and_binary(self):
        raw = b'before\n\x1b[31mKernel panic\x1b[0m\nafter\n\xff'
        lines, hits, text = m.analyze(raw, m.DEFAULT)
        self.assertEqual(hits[0]['line'], 2)
        self.assertIn('before', text)
        self.assertNotIn('\x1b', text)

    def test_packages(self):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d)
            raw = b'UEFI\nerror\x00\xff'
            (f / 'full.bin').write_bytes(raw)
            m.write_outputs(f, raw, raw.decode('utf-8', 'replace').splitlines(),
                            m.analyze(raw, m.DEFAULT)[1], m.DEFAULT, {'source': 'test'})
            m.package(f, m.DEFAULT, 'test', {'status': 'interrupted'})
            with zipfile.ZipFile(f / 'all-logs.zip') as z:
                self.assertEqual(z.read('full.bin'), raw)
            with zipfile.ZipFile(f / 'important-logs.zip') as z:
                self.assertNotIn('full.bin', z.namelist())
            self.assertEqual(json.loads((f / 'summary.json').read_text())['status'], 'interrupted')

    def test_rule_validation(self):
        with self.assertRaises(ValueError):
            m.validate({'version': 1, 'rules': [{'id': 'x', 'terms': ['']}]})
        with self.assertRaises(ValueError):
            m.validate({'version': 1, 'rules': [{'id': 'x', 'terms': ['a'], 'severity': 'fatal'}]})

    def test_board_detection(self):
        self.assertEqual(m.detect_board('NVIDIA Jetson Orin Nano tegra234 booting'), 'jetson')
        self.assertEqual(m.detect_board('Raspberry Pi 5 bcm2712 booting'), 'raspberrypi')
        self.assertEqual(m.detect_board('plain log without markers'), 'common')

    def test_index_board_filter_and_hash(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            common = {'version': 3, 'board': 'common', 'rules': [{'id': 'c', 'terms': ['panic']}]}
            jetson = {'version': 3, 'board': 'jetson', 'rules': [{'id': 'j', 'terms': ['tegra']}]}
            (folder / 'common.json').write_text(json.dumps(common))
            (folder / 'jetson.json').write_text(json.dumps(jetson))
            m.make_index(folder)
            rules, meta = m.load_rules(folder, 'jetson', verbose=False)
            self.assertEqual({r['id'] for r in rules['rules']}, {'c', 'j'})
            rules2, _ = m.load_rules(folder, 'common', verbose=False)
            self.assertEqual({r['id'] for r in rules2['rules']}, {'c'})
            # 篡改文件 → sha256 不匹配应报错，而不是半加载
            (folder / 'jetson.json').write_text(json.dumps({**jetson, 'rules': [{'id': 'j2', 'terms': ['x']}]}))
            with self.assertRaises(ValueError):
                m.load_rules(folder, 'jetson', verbose=False)

    def test_update_rules_and_no_downgrade(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            src = root / 'src'
            src.mkdir()
            (src / 'common.json').write_text(json.dumps(
                {'version': 5, 'board': 'common', 'rules': [{'id': 'c', 'terms': ['panic']}]}))
            m.make_index(src)
            target = root / 'rules'
            old = os.environ.get('SERIAL_LOG_RULES_DIR')
            os.environ['SERIAL_LOG_RULES_DIR'] = str(target)
            try:
                self.assertEqual(m.update_rules(str(src), verbose=False), 5)
                self.assertTrue((target / 'index.json').exists())
                # 同版本回退：把远端降到 4 应该被拒绝
                (src / 'common.json').write_text(json.dumps(
                    {'version': 4, 'board': 'common', 'rules': [{'id': 'c', 'terms': ['panic']}]}))
                m.make_index(src)
                with self.assertRaises(SystemExit):
                    m.update_rules(str(src), verbose=False)
                self.assertEqual(m.update_rules(str(src), force=True, verbose=False), 4)
            finally:
                if old is None:
                    os.environ.pop('SERIAL_LOG_RULES_DIR', None)
                else:
                    os.environ['SERIAL_LOG_RULES_DIR'] = old


if __name__ == '__main__':
    unittest.main()
