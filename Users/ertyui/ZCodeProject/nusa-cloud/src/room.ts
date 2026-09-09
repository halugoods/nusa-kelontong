import type { Env } from './index';

/**
 * RoomDO — Durable Object realtime (pengganti 3 channel Supabase).
 *
 * Channel (idFromName = channel):
 *   backup_updated:{uid}   — broadcast backup baru → device lain pullNow()
 *   ring:{uid}             — broadcast panggilan karyawan (kasir/owner)
 *   orders:{storeId}       — order_new / order_updated (storefront ↔ app)
 *   sync:{uid}             — broadcast delta sync event ke semua device
 *
 * WebSocket hibernation: koneksi tetap hidup walau DO di-evict; event
 * diserahkan ke stub serverWebSocket.
 */
export class RoomDO {
  private state: DurableObjectState;

  constructor(state: DurableObjectState, _env: unknown) {
    this.state = state;
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    // Internal publish endpoint (dipakai publishToRoom via stub.fetch).
    if (url.pathname === '/publish') {
      const event = await req.text();
      for (const client of this.state.getWebSockets()) {
        client.send(event);
      }
      return new Response('ok');
    }

    if (req.headers.get('Upgrade') !== 'websocket') {
      return new Response('websocket upgrade required', { status: 426 });
    }

    const pair = new WebSocketPair();
    this.state.acceptWebSocket(pair[1]);
    this.state.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair('ping', 'pong'),
    );

    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** DO message handler via stub: broadcast JSON ke semua klien. */
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // Klien tidak mengirim data untuk broadcast; abaikan kecuali {"broadcast": ...}
    if (typeof message === 'string') {
      try {
        const data = JSON.parse(message);
        if (data && data.broadcast) {
          for (const client of this.state.getWebSockets()) {
            if (client !== ws) client.send(JSON.stringify(data.broadcast));
          }
        }
      } catch {
        // abaikan payload tak-valid
      }
    }
  }

  async webSocketClose(_ws: WebSocket): Promise<void> {
    // hibernation API — tidak perlu cleanup eksplisit
  }

  /** Broadcast sync event ke semua WebSocket client yang terhubung. */
  async broadcastSync(uid: string, tableName: string, ids: string[]) {
    const event = JSON.stringify({
      event: 'sync',
      payload: { uid, table: tableName, ids, at: new Date().toISOString() },
    });
    for (const ws of this.state.getWebSockets()) {
      try { ws.send(event); } catch {}
    }
  }
}

/**
 * Helper worker: publish event ke room channel.
 * Dipakai fn/online_store (order_new/order_updated), fn/app_ping-like
 * backup path (backup_updated), dan fn/call (ring).
 */
export async function publishToRoom(
  env: { ROOM: DurableObjectNamespace },
  channel: string,
  event: Record<string, unknown>,
): Promise<void> {
  const id = env.ROOM.idFromName(channel);
  const stub = env.ROOM.get(id);
  await stub.fetch('https://do.internal/publish', {
    method: 'POST',
    body: JSON.stringify(event),
  });
}

/**
 * Helper worker: broadcast sync event ke RoomDO sync:{uid} channel.
 * Dipakai fn/sync_delta saat ada delta baru di-push.
 */
export async function publishSyncEvent(
  env: Env,
  uid: string,
  tableName: string,
  ids: string[]
) {
  try {
    const id = env.ROOM.idFromName(`sync:${uid}`);
    const stub = env.ROOM.get(id);
    await stub.broadcastSync(uid, tableName, ids);
  } catch {}
}
