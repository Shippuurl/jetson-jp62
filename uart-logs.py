#!/usr/bin/env python3
"""Local serial capture, versioned data-only filters and portable ZIP reports."""
import argparse, datetime, hashlib, json, os, pathlib, re, sys, time, urllib.request, zipfile
BASE = 'https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main/'
DEFAULT = {'version': 1, 'context': 3, 'rules': [
    {'id': 'fault', 'terms': ['error', 'fail', 'panic', 'timeout', 'watchdog', 'assert', 'abort', 'unable']},
    {'id': 'boot-stage', 'terms': ['MB1', 'MB2', 'UEFI', 'Linux version', 'Booting Linux', 'systemd[1]', 'Reached target']}]}

def validate(data):
    if data.get('version') != 1 or not isinstance(data.get('rules'), list):
        raise ValueError('Unsupported rules schema')
    if not 0 <= data.get('context', 3) <= 30 or len(data['rules']) > 100:
        raise ValueError('Rule limits exceeded')
    for r in data['rules']:
        if not isinstance(r.get('id'), str) or not isinstance(r.get('terms'), list) or not r['terms']:
            raise ValueError('Invalid rule')
        if len(r['terms']) > 100 or any(not isinstance(t, str) or not 1 <= len(t) <= 200 for t in r['terms']):
            raise ValueError('Invalid terms')
    return data

def load_rules(args):
    if args.rules:
        return validate(json.loads(pathlib.Path(args.rules).read_text(encoding='utf-8'))), str(args.rules)
    if not args.offline:
        try:
            with urllib.request.urlopen(args.rules_url, timeout=8) as response:
                raw = response.read(262145)
            if len(raw) > 262144: raise ValueError('Rules too large')
            return validate(json.loads(raw)), args.rules_url
        except Exception as e:
            print('Rules update unavailable; using bundled rules:', type(e).__name__)
    return DEFAULT, 'bundled'

def analyze(raw, rules):
    lines = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', raw.decode('utf-8', errors='replace')).splitlines()
    hits, selected = [], set()
    for n, line in enumerate(lines):
        matched = [r['id'] for r in rules['rules'] if any(t.casefold() in line.casefold() for t in r['terms'])]
        if matched:
            hits.append({'line': n+1, 'rules': matched})
            selected.update(range(max(0,n-rules.get('context',3)),min(len(lines),n+rules.get('context',3)+1)))
    return lines, hits, '\n'.join(f'{n+1:07d}: {lines[n]}' for n in sorted(selected))+'\n'

def package(folder, rules, source, status):
    raw = (folder/'full.bin').read_bytes()
    lines, hits, important = analyze(raw, rules)
    (folder/'full.log').write_text('\n'.join(lines)+'\n', encoding='utf-8')
    (folder/'important.log').write_text(important, encoding='utf-8')
    (folder/'rules.json').write_text(json.dumps(rules,ensure_ascii=False,indent=2),encoding='utf-8')
    report = dict(status, bytes=len(raw), lines=len(lines), hits=hits, rules_source=source,
                  sha256=hashlib.sha256(raw).hexdigest(), note='Matches are review clues, not fault diagnosis. No logs uploaded.')
    (folder/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    for name, members in [('all-logs.zip',['full.bin','full.log','important.log','summary.json','rules.json']),
                          ('important-logs.zip',['important.log','summary.json','rules.json'])]:
        with zipfile.ZipFile(folder/name,'w',zipfile.ZIP_DEFLATED) as z:
            for member in members: z.write(folder/member,member)
    (folder/'index.html').write_text('<meta charset="utf-8"><title>UART logs</title><h1>UART logs · 本地日志</h1><p><a href="all-logs.zip" download>全部日志 / All logs ZIP</a></p><p><a href="important-logs.zip" download>重要日志 / Important logs ZIP</a></p><p><a href="full.log">完整日志</a> · <a href="important.log">重要日志</a> · <a href="summary.json">报告</a></p>',encoding='utf-8')
    print(f'\nSaved locally: {folder}\nAll: {folder / "all-logs.zip"}\nImportant: {folder / "important-logs.zip"}\nShortcut: {(folder / "index.html").as_uri()}')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port');p.add_argument('--baud',type=int,default=115200)
    p.add_argument('--seconds',type=float,default=60,help='0: until Ctrl-C')
    p.add_argument('--input',type=pathlib.Path,help='Analyze an existing local log')
    p.add_argument('--output',type=pathlib.Path,default=pathlib.Path.home()/'Downloads'/'Jetson-Logs')
    p.add_argument('--rules');p.add_argument('--rules-url',default=BASE+'rules/uart.json')
    p.add_argument('--offline',action='store_true');p.add_argument('--list',action='store_true')
    a=p.parse_args()
    if a.seconds < 0 or a.baud <= 0: p.error('Invalid duration/baud')
    serial=None
    if not a.input:
        try:
            import serial
            from serial.tools import list_ports
        except ImportError:
            p.exit(2,'pyserial required. Run the one-command launcher or: python -m pip install pyserial==3.5\n')
        ports=list(list_ports.comports())
        if a.list:
            for v in ports: print(v.device, v.description)
            return
        if not a.port:
            candidates=[v for v in ports if v.vid in (0x10c4,0x1a86,0x0403,0x067b)]
            if len(candidates)==1:a.port=candidates[0].device
            else:
                for n,v in enumerate(ports,1): print(n,v.device,v.description)
                if not ports:p.exit(2,'No serial port found. Connect USB-TTL and check its driver.\n')
                if not sys.stdin.isatty():p.exit(2,'Specify --port; automatic selection is ambiguous.\n')
                try:
                    choice=int(input('Select port number: '))
                    if not 1 <= choice <= len(ports): raise ValueError('Invalid selection')
                    a.port=ports[choice-1].device
                except (ValueError,IndexError):p.exit(2,'Invalid selection\n')
    rules,source=load_rules(a)
    folder=a.output.expanduser().resolve()/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    folder.mkdir(parents=True)
    status={'port':a.port,'baud':a.baud,'status':'completed'};code=0
    try:
        if a.input:(folder/'full.bin').write_bytes(a.input.read_bytes())
        else:
            print(f'Capturing {a.port} @ {a.baud} 8N1; power on board now. Ctrl-C saves and packages logs.')
            with (folder/'full.bin').open('wb') as out:
                conn=serial.Serial(port=None,baudrate=a.baud,timeout=.2,rtscts=False,dsrdtr=False,xonxoff=False)
                conn.dtr=False;conn.rts=False;conn.port=a.port
                with conn:
                    deadline=time.monotonic()+a.seconds
                    while a.seconds==0 or time.monotonic()<deadline:
                        data=conn.read(conn.in_waiting or 1)
                        if data:out.write(data);out.flush()
    except KeyboardInterrupt:status['status']='interrupted'
    except Exception as e:
        status.update(status='error',error=str(e));code=1
    finally:
        if not (folder/'full.bin').exists():(folder/'full.bin').touch()
        package(folder,rules,source,status)
    return code
if __name__=='__main__':sys.exit(main())
