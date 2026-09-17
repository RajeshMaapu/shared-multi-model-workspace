#!/usr/bin/env python3
"""Assemble a fresh, reviewable local bundle; never replace an installed app."""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess, tempfile
p=argparse.ArgumentParser(); p.add_argument('--bin',required=True); p.add_argument('--output-parent',required=True); a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]; binaries=pathlib.Path(a.bin).resolve(); parent=pathlib.Path(a.output_parent).resolve(); parent.mkdir(parents=True,exist_ok=True)
staging=pathlib.Path(tempfile.mkdtemp(prefix='upgrade-',dir=parent)); app=staging/'Workshop.app'; contents=app/'Contents'
for name in ['MacOS','Resources','Configuration','Library/LaunchAgents']:(contents/name).mkdir(parents=True,exist_ok=True)
for name in ['Workshop','workshop-daemon','workshop-mcp']:shutil.copy2(binaries/name,contents/'MacOS'/name)
info=plistlib.loads((repo/'Packaging/Info.plist').read_bytes()); revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(); info['CFBundleVersion']=revision[:12];(contents/'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copy2(repo/'Packaging/ai.maapu.workshop.daemon.plist',contents/'Library/LaunchAgents/ai.maapu.workshop.daemon.plist')
shutil.copy2(repo/'Configuration/engineers.template.json',contents/'Configuration/engineers.template.json')
for name in ['Workshop','workshop-daemon','workshop-mcp']:subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(contents/'MacOS'/name)],check=True)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
manifest={'revision':revision,'bundle':str(app),'signing':'ad-hoc, local use only; not notarized','binaries':{n:hashlib.sha256((contents/'MacOS'/n).read_bytes()).hexdigest() for n in ['Workshop','workshop-daemon','workshop-mcp']}}
(staging/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n'); print(json.dumps(manifest,indent=2))
