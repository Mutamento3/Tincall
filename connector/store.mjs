import {createSupabaseStore,ConnectorError} from '../supabase/functions/_shared/tincall/service.mjs';
import {createSQLiteStore,defaultDatabasePath} from './sqlite-store.mjs';

export function createNodeStore(config,get=key=>process.env[key]) {
  const selected=get('TINCALL_STORAGE');
  if(selected && !['supabase','sqlite'].includes(selected))throw new ConnectorError('invalid_server_configuration',503);
  const hasSupabase=Boolean(config.supabaseURL || config.serviceKey || config.publicKey);
  const backend=selected || (hasSupabase?'supabase':'sqlite');
  // Partial Supabase credentials must fail closed instead of silently switching DBs.
  return backend==='supabase'?createSupabaseStore(config):createSQLiteStore(config,get('TINCALL_SQLITE_PATH') || defaultDatabasePath);
}
