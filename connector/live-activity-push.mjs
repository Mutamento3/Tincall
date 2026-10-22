// Shared by the Node and Cloudflare senders. Routing and delivery state are stored;
// the display name is forwarded for this start only, never persisted here.
export class ActivityPushError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}
const requireValue = (value, code, status) => { if (!value) throw new ActivityPushError(code, status); };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function validateActivityToken(value) {
  requireValue(value == null || (typeof value === 'string' && /^[a-f0-9]{32,512}$/i.test(value)), 'invalid_activity_token');
}

export function activityStartPayload(callID, now = Math.floor(Date.now() / 1000), avatarContactID, displayName) {
  const name = displayName?.trim() || 'Tincall';
  return { aps: {
    timestamp: now, event: 'start', 'input-push-token': 1,
    'attributes-type': 'TincallCallAttributes',
    attributes: { callID, name, isPreview: false, ...(avatarContactID ? {avatarContactID} : {}) },
    // ActivityKit uses JSONDecoder's default Date representation (since 2001).
    'content-state': { status: '通话中', startedAt: now - 978307200, isMuted: false,
      microphoneAvailable: true, audioActivity: 'idle' },
    'stale-date': now + 30,
    // ActivityKit decodes localized strings within title/body. A top-level
    // APNs loc-key doesn't supply the required Live Activity alert body.
    alert: { title: { 'loc-key': '%@', 'loc-args': [name] }, body: { 'loc-key': '通话中' } }
  } };
}

export class LiveActivityPushRegistry {
  constructor(exec, send) {
    this.exec = exec; this.send = send;
    exec('CREATE TABLE IF NOT EXISTS activity_devices(binding_id TEXT PRIMARY KEY, start_token TEXT NOT NULL)');
    exec(`CREATE TABLE IF NOT EXISTS activity_deliveries(binding_id TEXT NOT NULL, call_id TEXT NOT NULL,
      state TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(binding_id, call_id))`);
  }
  register(bindingID, token) {
    validateActivityToken(token);
    if (token) this.exec(`INSERT INTO activity_devices VALUES(?, ?) ON CONFLICT(binding_id)
      DO UPDATE SET start_token=excluded.start_token`, bindingID, token);
    else this.exec('DELETE FROM activity_devices WHERE binding_id=?', bindingID);
  }
  remove(bindingID) {
    this.exec('DELETE FROM activity_devices WHERE binding_id=?', bindingID);
    this.exec('DELETE FROM activity_deliveries WHERE binding_id=?', bindingID);
  }
  prune() { this.exec('DELETE FROM activity_deliveries WHERE created_at<=?', Date.now() - 7 * 86400000); }
  nextExpiry() {
    const oldest = this.exec('SELECT MIN(created_at) AS value FROM activity_deliveries')[0]?.value;
    return oldest == null ? null : oldest + 7 * 86400000;
  }
  async start(device, callID, avatarContactID, displayName) {
    requireValue(UUID.test(callID), 'invalid_call_id');
    requireValue(avatarContactID == null || UUID.test(avatarContactID), 'invalid_avatar_contact_id');
    requireValue(displayName == null || (typeof displayName === 'string' && displayName.trim().length > 0 && displayName.length <= 200 && !/[\u0000-\u001f\u007f]/.test(displayName)), 'invalid_display_name');
    const bindingID = device.binding_id;
    const token = this.exec('SELECT start_token FROM activity_devices WHERE binding_id=?', bindingID)[0]?.start_token;
    requireValue(token, 'activity_not_registered', 422);
    const old = this.exec('SELECT state FROM activity_deliveries WHERE binding_id=? AND call_id=?', bindingID, callID)[0];
    if (old?.state === 'sent') return { accepted_by_apns: true };
    // Do not resend an ambiguous timed-out start: APNs might already have
    // accepted it. The phone can recover its presentation in the foreground.
    requireValue(!old, 'activity_start_already_requested', 409);
    this.exec("INSERT INTO activity_deliveries VALUES(?, ?, 'sending', ?)", bindingID, callID, Date.now());
    try {
      await this.send({ ...device, device_token: token }, { event: 'activity_start', call_id: callID, avatar_contact_id: avatarContactID, ...(displayName ? {display_name: displayName.trim()} : {}) });
      this.exec("UPDATE activity_deliveries SET state='sent' WHERE binding_id=? AND call_id=?", bindingID, callID);
      this.prune();
      return { accepted_by_apns: true };
    } catch (error) {
      this.exec("UPDATE activity_deliveries SET state='failed' WHERE binding_id=? AND call_id=?", bindingID, callID);
      if (error.code === 'apns_device_expired') {
        this.exec('DELETE FROM activity_devices WHERE binding_id=? AND start_token=?', bindingID, token);
      }
      throw error;
    }
  }
}
