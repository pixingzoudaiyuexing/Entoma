import javax.net.ssl.HttpsURLConnection;
import java.net.URL;
import java.net.Proxy;
import java.io.InputStream;
import java.security.MessageDigest;
public final class EntomaHttpsProbe {
 public static void main(String[] args) {
  try { if(args.length>0&&args[0].equals("local-closed")){boolean listening=false;java.net.Socket s=new java.net.Socket();try{s.connect(new java.net.InetSocketAddress("127.0.0.1",17890),1000);listening=true;}catch(java.net.ConnectException expected){}finally{s.close();}System.out.println("{\"mixedPortListening\":"+listening+"}");if(listening)System.exit(1);return;}probe(args); } catch(Throwable e) {
    StringBuilder chain=new StringBuilder();String errno="NONE";Throwable cur=e;int depth=0;
    while(cur!=null && depth++<8){if(chain.length()>0)chain.append(",");chain.append(cur.getClass().getSimpleName());String m=cur.getMessage();if(m!=null)for(String n:new String[]{"EACCES","EPERM","ECONNREFUSED","ENETUNREACH","ETIMEDOUT","ECONNRESET","EHOSTUNREACH"})if(m.contains(n))errno=n;cur=cur.getCause();}
    System.out.println("{\"errorClasses\":\""+chain+"\",\"errno\":\""+errno+"\",\"defaultTLSValidation\":true,\"explicitHttpProxy\":false}");System.exit(1);
  }
 }
 public static void probe(String[] args) throws Exception {
  String target=args.length>0?args[0]:"https://www.cloudflare.com/cdn-cgi/trace?entoma_acceptance=android_tun_20261012";
  if(!target.startsWith("https://www.cloudflare.com/")&&!target.startsWith("https://www.gstatic.com/"))throw new IllegalArgumentException("probe host");
  if(args.length>1 && args[1].equals("ipv4")){probeV4(target);return;}
  HttpsURLConnection c=(HttpsURLConnection)new URL(target).openConnection(Proxy.NO_PROXY);
  c.setConnectTimeout(15000);c.setReadTimeout(15000);c.setInstanceFollowRedirects(false);
  int status=c.getResponseCode();if(args.length>1&&args[1].equals("hold"))Thread.sleep(15000);MessageDigest hash=MessageDigest.getInstance("SHA-256");long bytes=0;java.io.ByteArrayOutputStream body=new java.io.ByteArrayOutputStream();
  try(InputStream input=c.getInputStream()){byte[] buf=new byte[4096];int n;while((n=input.read(buf))!=-1){bytes+=n;if(bytes>1048576)throw new IllegalStateException("bound");hash.update(buf,0,n);body.write(buf,0,n);}}
  StringBuilder hex=new StringBuilder();for(byte b:hash.digest())hex.append(String.format("%02x",b));
  String egress="";for(String line:new String(body.toByteArray(),"UTF-8").split("\\n")){if(line.startsWith("ip=")){StringBuilder h=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(line.substring(3).trim().getBytes("UTF-8")))h.append(String.format("%02x",b));egress=h.toString();}}
  System.out.println("{\"httpStatus\":"+status+",\"bytes\":"+bytes+",\"bodySha256\":\""+hex+"\",\"egressHash\":\""+egress+"\",\"defaultTLSValidation\":true,\"explicitHttpProxy\":false,\"uid\":\"adb-shell\"}");c.disconnect();
 }
 public static void probeV4(String target) throws Exception {
  URL u=new URL(target);java.net.InetAddress address=null;int a=0,aaaa=0;
  for(java.net.InetAddress ip:java.net.InetAddress.getAllByName(u.getHost())){if(ip instanceof java.net.Inet4Address){a++;if(address==null)address=ip;}else aaaa++;}
  if(address==null)throw new java.net.UnknownHostException("no IPv4");
  java.net.Socket raw=new java.net.Socket();raw.connect(new java.net.InetSocketAddress(address,443),15000);raw.setSoTimeout(15000);
  javax.net.ssl.SSLSocket tls=(javax.net.ssl.SSLSocket)((javax.net.ssl.SSLSocketFactory)javax.net.ssl.SSLSocketFactory.getDefault()).createSocket(raw,u.getHost(),443,true);
  javax.net.ssl.SSLParameters params=tls.getSSLParameters();params.setEndpointIdentificationAlgorithm("HTTPS");tls.setSSLParameters(params);tls.startHandshake();
  String path=u.getFile();if(path.isEmpty())path="/";
  tls.getOutputStream().write(("GET "+path+" HTTP/1.1\r\nHost: "+u.getHost()+"\r\nConnection: close\r\nUser-Agent: EntomaAcceptance/1\r\n\r\n").getBytes("US-ASCII"));
  java.io.BufferedReader reader=new java.io.BufferedReader(new java.io.InputStreamReader(tls.getInputStream(),"UTF-8"));String status=reader.readLine();int count=0;while(reader.readLine()!=null && count++<2000){};
  int code=Integer.parseInt(status.split(" ")[1]);System.out.println("{\"httpStatus\":"+code+",\"family\":\"IPv4\",\"aCount\":"+a+",\"aaaaCount\":"+aaaa+",\"defaultTrustValidation\":true,\"hostnameValidation\":true,\"explicitHttpProxy\":false}");tls.close();
 }

}
