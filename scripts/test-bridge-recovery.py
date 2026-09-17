import argparse,json,os,pathlib,secrets,subprocess,tempfile,time,selectors
p=argparse.ArgumentParser();p.add_argument("--bin-dir",required=True);a=p.parse_args()
root=pathlib.Path(tempfile.mkdtemp(prefix='wr-',dir='/private/tmp'));home=root/'home';run=root/'run';run.mkdir();token=home/'profiles/codex/token';token.parent.mkdir(parents=True);token.write_text(secrets.token_hex(32));token.chmod(0o600)
bins=pathlib.Path(a.bin_dir).resolve();env=dict(os.environ,WORKSHOP_HOME=str(home),WORKSHOP_RUNTIME_DIR=str(run),WORKSHOP_ADAPTERS='fake');daemon=None
bridge=subprocess.Popen([str(bins/'workshop-mcp'),'--principal','codex','--token-file',str(token),'--runtime-dir',str(run)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
seq=0
def call(name,args={}):
 global seq
 seq+=1;bridge.stdin.write(json.dumps({'jsonrpc':'2.0','id':seq,'method':'tools/call','params':{'name':name,'arguments':args}})+'\n');bridge.stdin.flush();sel=selectors.DefaultSelector();sel.register(bridge.stdout,selectors.EVENT_READ);assert sel.select(10),'timeout';v=json.loads(bridge.stdout.readline());sel.close();return v['result']
def start():
 global daemon
 log=open(root/'daemon.log','ab');daemon=subprocess.Popen([str(bins/'workshop-daemon')],env=env,stdout=log,stderr=log)
 for _ in range(100):
  if not call('workshop_list_tasks').get('isError'):return
  time.sleep(.1)
 raise AssertionError('daemon unavailable')
def stop():
 global daemon
 daemon.terminate();daemon.wait(timeout=10);daemon=None
try:
 assert call('workshop_list_tasks')['isError'];start();assert not call('workshop_list_tasks')['isError'];stop();assert call('workshop_list_tasks')['isError'];start();assert not call('workshop_list_tasks')['isError']
 print(json.dumps({'passed':True,'checks':['bridge starts offline','same bridge recovers after daemon startup','same bridge reports stopped daemon','same bridge recovers after daemon restart'],'bridge_pid':bridge.pid,'root':str(root)}))
finally:
 bridge.terminate();bridge.wait(timeout=5)
 if daemon:stop()
