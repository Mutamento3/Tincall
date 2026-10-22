// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

test('contact directory exposes names and preserves owner and role authorization', async () => {
  const connector = createConnector({
    store: {async authenticate(token) {
      return token === 'role-token' ? {owner_id: 'owner-a', contact_id: 'role-a'} : {owner_id: 'owner-a'};
    },async mcpRoleCommand() {return {bindings:[]};}},
    config: {bindings: [
      {owner_id: 'owner-a', contact_id: 'role-a', display_name: ' Example A ', mode: 'tools', token: 'private'},
      {owner_id: 'owner-a', contact_id: 'role-b', mode: 'http', generation_url: 'https://example.com/generate', cancel_url: 'https://example.com/cancel'},
      {owner_id: 'owner-b', contact_id: 'other-owner', display_name: 'Private name', mode: 'tools'},
    ]},
  });
  async function directory(token) {
    const response = await connector.handle(new Request('https://example.com/capabilities', {headers: {Authorization: `Bearer ${token}`}}));
    assert.equal(response.status, 200);
    return response.json();
  }
  const all = await directory('owner-token');
  assert.deepEqual(all.bindings, [
    {contact_id: 'role-a', display_name: 'Example A', mode: 'tools', generation_configured: true, wake_supported: false},
    {contact_id: 'role-b', mode: 'http', generation_configured: true, wake_supported: true},
  ]);
  const scoped = await directory('role-token');
  assert.deepEqual(scoped.bindings, [all.bindings[0]]);
  assert.equal(scoped.owner_id, undefined);
});
