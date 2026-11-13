import importlib.util,pathlib,tempfile,unittest,zipfile,json
p=pathlib.Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('uart',p/'uart-logs.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_context_and_binary(self):
  raw=b'before\n\x1b[31mKernel panic\x1b[0m\nafter\n\xff'
  lines,hits,text=m.analyze(raw,m.DEFAULT)
  self.assertEqual(hits[0]['line'],2);self.assertIn('before',text);self.assertNotIn('\x1b',text)
 def test_packages(self):
  with tempfile.TemporaryDirectory() as d:
   f=pathlib.Path(d);raw=b'UEFI\nerror\x00\xff';(f/'full.bin').write_bytes(raw)
   m.package(f,m.DEFAULT,'test',{'status':'interrupted'})
   with zipfile.ZipFile(f/'all-logs.zip') as z:self.assertEqual(z.read('full.bin'),raw)
   with zipfile.ZipFile(f/'important-logs.zip') as z:self.assertNotIn('full.bin',z.namelist())
   self.assertEqual(json.loads((f/'summary.json').read_text())['status'],'interrupted')
 def test_rule_validation(self):
  with self.assertRaises(ValueError):m.validate({'version':1,'rules':[{'id':'x','terms':['']} ]})
if __name__=='__main__':unittest.main()
