import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import {createAPNsTransport,createPushGateway} from './apns-sender.mjs';

const send=createAPNsTransport({teamID:process.env.TINCALL_APNS_TEAM_ID,keyID:process.env.TINCALL_APNS_KEY_ID,
  keyFile:process.env.TINCALL_APNS_KEY_FILE,topic:process.env.TINCALL_APNS_TOPIC});
const gateway=createPushGateway({send,token:process.env.TINCALL_PUSH_TOKEN,databasePath:process.env.TINCALL_APNS_DATABASE ?? 'connector/.local/apns.sqlite'});
const port=Number(process.env.PORT ?? 8788);
const server=createServer(async(req,res)=>{
  try{
    const request=new Request(`http://127.0.0.1:${port}${req.url}`,{method:req.method,headers:req.headers,
      ...(['GET','HEAD'].includes(req.method)?{}:{body:Readable.toWeb(req),duplex:'half'})});
    const response=await gateway.handle(request);res.writeHead(response.status,Object.fromEntries(response.headers));res.end(await response.text());
  }catch{res.writeHead(500,{'Content-Type':'application/json'});res.end('{"error":{"code":"push_failed"}}');}
});
server.listen(port,'127.0.0.1',()=>console.log(`Tincall APNs sender listening on 127.0.0.1:${port}`));
function stop(){server.close(()=>gateway.close());}
process.on('SIGINT',stop);process.on('SIGTERM',stop);
