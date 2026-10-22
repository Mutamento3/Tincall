import {configFromEnvironment, createConnector, createSupabaseStore} from '../_shared/tincall/service.mjs';

const config = configFromEnvironment((key: string) => Deno.env.get(key));
const store = createSupabaseStore(config);
const connector = createConnector({
  config, store,
  schedule: (task: Promise<unknown>) => EdgeRuntime.waitUntil(task.catch(() => {
    // Durable jobs remain visible to the next scheduled worker; no content is logged.
    console.error('tincall_background_task_failed');
  })),
});
Deno.serve(connector.handle);
