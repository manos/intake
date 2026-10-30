export type Entity = "item" | "entry" | "day";
export interface Row {
  id: string;
  entity: Entity;
  version: number;
  deleted: boolean;
  data: Record<string, any>;
}
export interface Op {
  id: string;
  entity: Entity;
  record_id: string;
  base_version: number;
  data: Record<string, any>;
  deleted: boolean;
  blocked?: string;
  server?: Row;
}
export interface Profile {
  id: string;
  username: string;
  settings: { timezone: string; day_start: number };
}
export interface State {
  records: Row[];
  queue: Op[];
  cursor: number;
}
export function dayKey(
  instant: string | Date,
  timezone: string,
  boundary: number,
): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(instant));
  const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
  const date = `${p.year}-${p.month}-${p.day}`;
  return +p.hour < boundary
    ? new Date(Date.parse(date + "T12:00:00Z") - 86400000)
        .toISOString()
        .slice(0, 10)
    : date;
}
const request = <T>(req: IDBRequest<T>) =>
  new Promise<T>((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
let dbPromise: Promise<IDBDatabase>;
function database() {
  return (dbPromise ??= new Promise((resolve, reject) => {
    const r = indexedDB.open("intake-journal", 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore("accounts");
      r.result.createObjectStore("profiles");
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  }));
}
export async function cacheProfile(profile?: Profile) {
  const db = await database();
  const tx = db.transaction("profiles", profile ? "readwrite" : "readonly");
  const store = tx.objectStore("profiles");
  if (profile) {
    store.put(profile, "last");
    await finished(tx);
    return profile;
  }
  return request<Profile | undefined>(store.get("last"));
}
function finished(tx: IDBTransaction) {
  return new Promise<void>((res, rej) => {
    tx.oncomplete = () => res();
    tx.onerror = () => rej(tx.error);
    tx.onabort = () =>
      rej(tx.error ?? new Error("Storage transaction aborted"));
  });
}
export class Journal {
  constructor(public account: string) {}
  async read(): Promise<State> {
    const db = await database();
    return (
      (await request<State>(
        db.transaction("accounts").objectStore("accounts").get(this.account),
      )) ?? { records: [], queue: [], cursor: 0 }
    );
  }
  private async mutate(fn: (s: State) => void) {
    const db = await database();
    const tx = db.transaction("accounts", "readwrite");
    const done = finished(tx);
    const store = tx.objectStore("accounts");
    const s = (await request<State>(store.get(this.account))) ?? {
      records: [],
      queue: [],
      cursor: 0,
    };
    fn(s);
    store.put(s, this.account);
    await done;
  }
  async put(
    entity: Entity,
    id: string,
    data: Record<string, any>,
    deleted = false,
  ) {
    await this.mutate((s) => {
      const prior = s.records.find((r) => r.entity === entity && r.id === id);
      s.records = s.records.filter(
        (r) => !(r.entity === entity && r.id === id),
      );
      s.records.push({
        id,
        entity,
        version: prior?.version ?? 0,
        deleted,
        data,
      });
      s.queue.push({
        id: crypto.randomUUID(),
        entity,
        record_id: id,
        base_version: prior?.version ?? 0,
        data,
        deleted,
      });
    });
  }
  async accept(response: any) {
    await this.mutate((s) => {
      for (const result of response.results) {
        const op = s.queue.find((o) => o.id === result.id);
        if (!op) continue;
        if (result.status === "applied") {
          s.queue = s.queue.filter((o) => o.id !== op.id);
          const next = s.queue.find(
            (o) => o.entity === op.entity && o.record_id === op.record_id,
          );
          if (next) next.base_version = result.record.version;
          else {
            s.records = s.records.filter(
              (r) => !(r.entity === op.entity && r.id === op.record_id),
            );
            s.records.push(result.record);
          }
        } else {
          op.blocked = result.message ?? result.status;
          op.server = result.record;
        }
      }
      for (const row of response.changes) {
        const pending = s.queue.filter(
          (o) => o.entity === row.entity && o.record_id === row.id,
        );
        if (pending.length) {
          for (const op of pending)
            if (op.blocked && (!op.server || row.version > op.server.version))
              op.server = row;
          continue;
        }
        const old = s.records.find(
          (r) => r.id === row.id && r.entity === row.entity,
        );
        if (!old || row.version >= old.version) {
          s.records = s.records.filter(
            (r) => !(r.id === row.id && r.entity === row.entity),
          );
          s.records.push(row);
        }
      }
      s.cursor = response.cursor;
    });
  }
  async resetCursor() {
    await this.mutate((s) => {
      s.cursor = 0;
      for (const row of s.records) {
        const pending = s.queue.filter(
          (o) => o.entity === row.entity && o.record_id === row.id,
        );
        if (pending.length) {
          for (const op of pending) delete op.server;
          continue;
        }
        s.queue.push({
          id: crypto.randomUUID(),
          entity: row.entity,
          record_id: row.id,
          base_version: row.version,
          data: row.data,
          deleted: row.deleted,
          blocked:
            "Server history was restored. Compare and recover this device copy before syncing.",
        });
      }
      for (const row of s.records) row.version = 0;
    });
  }
  async resolve(op: Op, local: boolean) {
    let copy: Row | undefined;
    await this.mutate((s) => {
      const related = s.queue.filter(
        (o) => o.entity === op.entity && o.record_id === op.record_id,
      );
      s.queue = s.queue.filter((o) => !related.includes(o));
      const row = s.records.find(
        (r) => r.entity === op.entity && r.id === op.record_id,
      );
      copy = row ? structuredClone(row) : undefined;
      if (local && row) {
        s.queue.push({
          id: crypto.randomUUID(),
          entity: row.entity,
          record_id: row.id,
          base_version: op.server?.version ?? row.version,
          data: row.data,
          deleted: row.deleted,
        });
      } else {
        s.records = s.records.filter(
          (r) => !(r.entity === op.entity && r.id === op.record_id),
        );
        if (op.server) s.records.push(op.server);
      }
    });
    return copy;
  }
}
export function basic(username: string, password: string) {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  return "Basic " + btoa(String.fromCharCode(...bytes));
}
export async function api(
  path: string,
  auth: string,
  body?: unknown,
  method?: string,
) {
  const response = await fetch("/api" + path, {
    method: method ?? (body ? "POST" : "GET"),
    headers: {
      Authorization: auth,
      "X-Requested-With": "XMLHttpRequest",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    cache: "no-store",
  });
  if (response.status === 409) {
    const body = await response
      .clone()
      .json()
      .catch(() => ({}));
    if (body.detail?.code === "cursor_reset") throw new Error("cursor_reset");
  }
  if (!response.ok)
    throw new Error(
      response.status === 401
        ? path === "/me"
          ? "Username or password wasn’t recognized."
          : "Sign in again to sync."
        : `Server could not complete this request (${response.status}).`,
    );
  return response;
}
const running = new Map<string, Promise<void>>();
export function synchronize(journal: Journal, auth: string) {
  const existing = running.get(journal.account);
  if (existing) return existing;
  const promise = (async () => {
    let more = true;
    while (more) {
      const s = await journal.read();
      const seen = new Set<string>();
      const candidates = s.queue
        .filter((o) => {
          const key = o.entity + o.record_id;
          if (seen.has(key)) return false;
          seen.add(key);
          return !o.blocked;
        })
        .slice(0, 500)
        .map(({ blocked, server, ...o }) => o);
      const operations: typeof candidates = [];
      let bytes = new TextEncoder().encode(
        JSON.stringify({ operations: [], cursor: s.cursor }),
      ).byteLength;
      for (const op of candidates) {
        const size =
          new TextEncoder().encode(JSON.stringify(op)).byteLength + 1;
        if (bytes + size >= 3 * 1024 * 1024) break;
        operations.push(op);
        bytes += size;
      }
      let response;
      try {
        response = await (
          await api("/sync", auth, { operations, cursor: s.cursor })
        ).json();
      } catch (e) {
        if ((e as Error).message === "cursor_reset") {
          await journal.resetCursor();
          continue;
        }
        throw e;
      }
      await journal.accept(response);
      const next = await journal.read();
      more =
        response.has_more ||
        (next.queue.some((o) => !o.blocked) && operations.length > 0);
    }
  })().finally(() => running.delete(journal.account));
  running.set(journal.account, promise);
  return promise;
}
export function snapshot(records: Row[]) {
  return {
    items: records
      .filter((r) => r.entity === "item" && !r.deleted)
      .map((r) => ({ id: r.id, ...r.data })),
    entries: records
      .filter((r) => r.entity === "entry" && !r.deleted)
      .map((r) => ({ id: r.id, ...r.data })),
    days: records
      .filter((r) => r.entity === "day" && !r.deleted)
      .map((r) => ({ id: r.id, ...r.data })),
  };
}
export async function dayId(date: string) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode("intake-day:" + date),
    ),
  ).slice(0, 16);
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const h = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
