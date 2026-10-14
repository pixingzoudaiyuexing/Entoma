import argparse,datetime,json,os,subprocess,sys,threading,socket,re
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--adb',default=os.environ.get('ADB','adb'))
parser.add_argument('--source',required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
adb=args.adb
path=args.output
if path.exists(): raise SystemExit('Refusing to replace prior device evidence')
records=[]; lock=threading.Lock(); workers=[]
def record(v):
 with lock:
  records.append(v);path.write_text(json.dumps({'source':args.source,'records':records},indent=2))
 print(json.dumps(v),flush=True)
def probe(row):
 cmd=[adb,'-d','shell','CLASSPATH=/data/local/tmp/entoma-https-probe.dex','app_process','/system/bin','EntomaHttpsProbe','https://www.cloudflare.com/cdn-cgi/trace?entoma_acceptance=android_matrix','hold']
 result=subprocess.run(cmd,capture_output=True,text=True,timeout=24)
 try: data=json.loads(result.stdout.strip())
 except Exception: data={'probeOutputInvalid':True}
 record({'phase':'shell_probe','stack':row['stack'],'proxy':row['proxy'],'cycle':row['cycle'],'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exit':result.returncode,'https':data})
def negative_lan(row):
 data=subprocess.check_output([adb,'-d','shell','ip','-4','-o','addr','show','dev','wlan0'],text=True)
 match=re.search(r'inet (\d+\.\d+\.\d+\.\d+)/',data)
 forwarder=row['native']['coreTun'].get('forwarder',{})
 if not match or not forwarder.get('wildcardListen'): return
 port=forwarder.get('port')
 try:
  control=socket.create_connection((match.group(1),row['lanControlPort']),timeout=1);control.close();reachable=True
 except (OSError,TimeoutError): reachable=False
 try:
  conn=socket.create_connection((match.group(1),port),timeout=1);conn.close();accepted=True
 except (OSError,TimeoutError): accepted=False
 record({'phase':'lan_negative','cycle':row['cycle'],'acceptedOnWifi':accepted,'controlReachable':reachable,'port':port,'sameListenerReported':forwarder.get('bindingMatchesTun')})
p=subprocess.Popen([adb,'-d','logcat','-v','raw','-T','1','flutter:I','*:S'],stdout=subprocess.PIPE,text=True)
try:
 for line in p.stdout:
  if 'ENTOMA_NET ' not in line: continue
  try: row=json.loads(line.split('ENTOMA_NET ',1)[1])
  except Exception: continue
  record(row)
  if row.get('phase')=='connected':
   t=threading.Thread(target=negative_lan,args=(row,));t.start();workers.append(t)
  if row.get('phase')=='connected' and row.get('shellProbeWindow',25)>0:
   t=threading.Thread(target=probe,args=(row,));t.start();workers.append(t)
  if row.get('phase') in ('complete','harness_error'): break
finally:
 p.terminate()
 for t in workers:t.join()
