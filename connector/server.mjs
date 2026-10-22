import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import {configFromEnvironment, createConnector} from '../supabase/functions/_shared/tincall/service.mjs';
import {createNodeStore} from './store.mjs';

const config=configFromEnvironment(key=>process.env[key]);
const store=createNodeStore(config);
const tasks=new Set();
function schedule(task){
  const pending=task.catch(()=>console.error('tincall_background_task_failed')).finally(()=>tasks.delete(pending));
  tasks.add(pending);
}
const connector=createConnector({config,store,schedule});
const port=Number(process.env.PORT ?? 8787);
const host=process.env.HOST ?? '127.0.0.1';
const server=createServer(async(req,res)=>{
  const controller=new AbortController();
  const disconnected=()=>{if(!res.writableEnded)controller.abort();};
  res.on('close',disconnected);
  try {
    const request=new Request(`http://127.0.0.1:${port}${req.url}`,{method:req.method,headers:req.headers,signal:controller.signal,
      ...(['GET','HEAD'].includes(req.method)?{}:{body:Readable.toWeb(req),duplex:'half'})});
    const response=await connector.handle(request);
    if(res.destroyed)return;
    res.writeHead(response.status,Object.fromEntries(response.headers));
    if(response.body){
      const body=Readable.fromWeb(response.body);
      body.on('error',()=>{if(!controller.signal.aborted)console.error('tincall_response_stream_failed');res.destroy();});
      body.pipe(res);
    }else res.end();
  } catch {if(!res.destroyed){res.writeHead(500,{'Content-Type':'application/json'});res.end('{"error":{"code":"internal_error"}}');}}
});
// LAN/public exposure requires the deployer's TLS reverse proxy.
server.listen(port,host,()=>console.log(`Tincall connector listening on ${host}:${port}`));
let busy=false;
const timer=setInterval(()=>{if(busy)return;busy=true;schedule(connector.runWorker().finally(()=>{busy=false;}));},15000);
function stop(){clearInterval(timer);server.close(async()=>{await Promise.allSettled([...tasks]);store.close?.();});}
process.on('SIGINT',stop);process.on('SIGTERM',stop);
