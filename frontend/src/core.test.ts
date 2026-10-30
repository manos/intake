import "fake-indexeddb/auto";
import { describe, it, expect } from "vitest";
import { dayKey, Journal } from "./core";
describe("journal day", () => {
  it("uses wall clock boundary across DST, not a fixed duration", () => {
    expect(dayKey("2026-03-08T07:30:00Z", "America/New_York", 4)).toBe(
      "2026-03-07",
    );
    expect(dayKey("2026-03-08T08:00:00Z", "America/New_York", 4)).toBe(
      "2026-03-08",
    );
    expect(dayKey("2026-11-01T06:30:00Z", "America/New_York", 4)).toBe(
      "2026-10-31",
    );
  });
});
describe("durable account journal", () => {
  it("persists optimistic writes and ordered outbox atomically, isolated by account", async () => {
    const a = new Journal("a");
    await a.put("day", "d", { date: "2026-10-30", note: "first", zero: false });
    await a.put("day", "d", {
      date: "2026-10-30",
      note: "second",
      zero: false,
    });
    const restored = await new Journal("a").read();
    expect(restored.records[0].data.note).toBe("second");
    expect(restored.queue).toHaveLength(2);
    expect((await new Journal("b").read()).queue).toHaveLength(0);
  });
  it("acknowledges one revision without overwriting a newer local edit", async () => {
    const a = new Journal("c");
    await a.put("day", "d", { date: "2026-10-30", note: "one", zero: false });
    const sent = (await a.read()).queue[0];
    await a.put("day", "d", { date: "2026-10-30", note: "two", zero: false });
    await a.accept({
      results: [
        {
          id: sent.id,
          status: "applied",
          record: {
            id: "d",
            entity: "day",
            version: 1,
            deleted: false,
            data: sent.data,
          },
        },
      ],
      changes: [
        { id: "d", entity: "day", version: 1, deleted: false, data: sent.data },
      ],
      cursor: 1,
      has_more: false,
    });
    const state = await a.read();
    expect(state.records[0].data.note).toBe("two");
    expect(state.queue[0].base_version).toBe(1);
  });
});
it("acknowledged write survives historical change pages", async () => {
  const j = new Journal("pages");
  await j.put("day", "d", { date: "2026-10-30", note: "new", zero: false });
  const op = (await j.read()).queue[0];
  await j.accept({
    results: [
      {
        id: op.id,
        status: "applied",
        record: {
          id: "d",
          entity: "day",
          version: 9,
          deleted: false,
          data: op.data,
        },
      },
    ],
    changes: [
      {
        id: "d",
        entity: "day",
        version: 2,
        deleted: false,
        data: { note: "old" },
      },
    ],
    cursor: 2,
  });
  expect((await j.read()).records[0].data.note).toBe("new");
  expect((await j.read()).records[0].version).toBe(9);
});
it("preserves latest optimistic edit when selecting server conflict resolution", async () => {
  const j = new Journal("resolve");
  await j.put("day", "d", { date: "2026-10-30", note: "first", zero: false });
  const op = (await j.read()).queue[0];
  await j.put("day", "d", { date: "2026-10-30", note: "latest", zero: false });
  op.server = {
    id: "d",
    entity: "day",
    version: 2,
    deleted: false,
    data: { date: "2026-10-30", note: "server", zero: false },
  };
  const copy = await j.resolve(op, false);
  expect(copy?.data.note).toBe("latest");
  expect((await j.read()).records[0].data.note).toBe("server");
});
it("uses stable day identities for offline creation across devices", async () => {
  const { dayId } = await import("./core");
  expect(await dayId("2026-10-30")).toBe(await dayId("2026-10-30"));
  expect(await dayId("2026-10-30")).not.toBe(await dayId("2026-10-29"));
});
it("limits each sync request to 500 operations while draining the full queue", async () => {
  const { synchronize } = await import("./core");
  const j = new Journal("large");
  for (let i = 0; i < 501; i++)
    await j.put("day", "d" + i, {
      date: "2026-10-30",
      note: String(i),
      zero: false,
    });
  const sizes: number[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    const body = JSON.parse(options!.body as string);
    sizes.push(body.operations.length);
    return new Response(
      JSON.stringify({
        results: body.operations.map((o: any) => ({
          id: o.id,
          status: "applied",
          record: {
            id: o.record_id,
            entity: o.entity,
            version: 1,
            deleted: false,
            data: o.data,
          },
        })),
        changes: [],
        cursor: 0,
        has_more: false,
      }),
    );
  };
  try {
    await synchronize(j, "Basic test");
    expect(sizes).toEqual([500, 1]);
    expect((await j.read()).queue).toHaveLength(0);
  } finally {
    globalThis.fetch = original;
  }
});
it("keeps cached data recoverable after server history reset", async () => {
  const j = new Journal("reset");
  await j.put("day", "d", { date: "2026-10-30", note: "device", zero: false });
  const op = (await j.read()).queue[0];
  await j.accept({
    results: [
      {
        id: op.id,
        status: "applied",
        record: {
          id: "d",
          entity: "day",
          version: 9,
          deleted: false,
          data: op.data,
        },
      },
    ],
    changes: [],
    cursor: 99,
  });
  await j.resetCursor();
  await j.accept({
    results: [],
    changes: [
      {
        id: "d",
        entity: "day",
        version: 2,
        deleted: false,
        data: { date: "2026-10-30", note: "restored server", zero: false },
      },
    ],
    cursor: 2,
  });
  const s = await j.read();
  expect(s.records[0].data.note).toBe("device");
  expect(s.queue[0].server?.data.note).toBe("restored server");
  expect(s.queue[0].blocked).toBeTruthy();
});
it("does not downgrade a returned conflict with an older change page", async () => {
  const j = new Journal("conflict-page");
  await j.put("day", "d", { date: "2026-10-30", note: "local", zero: false });
  const op = (await j.read()).queue[0];
  const server = {
    id: "d",
    entity: "day",
    version: 9,
    deleted: false,
    data: { note: "latest server" },
  };
  await j.accept({
    results: [{ id: op.id, status: "conflict", record: server }],
    changes: [{ ...server, version: 2, data: { note: "old" } }],
    cursor: 2,
  });
  expect((await j.read()).queue[0].server?.version).toBe(9);
});
it("can explicitly discard an absent restored tombstone while retaining its backup", async () => {
  const j = new Journal("tombstone");
  await j.put(
    "day",
    "d",
    { date: "2026-10-30", note: "backup note", zero: false },
    true,
  );
  const op = (await j.read()).queue[0];
  await j.resetCursor();
  const copy = await j.resolve(op, false);
  expect(copy?.data.note).toBe("backup note");
  expect((await j.read()).queue).toHaveLength(0);
  expect((await j.read()).records).toHaveLength(0);
});
it("bounds sync payload by encoded bytes for large unicode notes", async () => {
  const { synchronize } = await import("./core");
  const j = new Journal("bytes");
  for (let i = 0; i < 120; i++)
    await j.put("day", "d" + i, {
      date: "2026-10-30",
      note: "🙂".repeat(10000),
      zero: false,
    });
  const sizes: number[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    sizes.push(new TextEncoder().encode(options!.body as string).byteLength);
    const b = JSON.parse(options!.body as string);
    return new Response(
      JSON.stringify({
        results: b.operations.map((o: any) => ({
          id: o.id,
          status: "applied",
          record: {
            id: o.record_id,
            entity: o.entity,
            version: 1,
            deleted: false,
            data: o.data,
          },
        })),
        changes: [],
        cursor: 0,
        has_more: false,
      }),
    );
  };
  try {
    await synchronize(j, "Basic test");
    expect(Math.max(...sizes)).toBeLessThan(3 * 1024 * 1024);
    expect(sizes.length).toBeGreaterThan(1);
  } finally {
    globalThis.fetch = original;
  }
});
it("validates account creation before sending credentials", async () => {
  const { signupError } = await import("./core");
  expect(signupError("me", "short", "short")).toMatch(/12/);
  expect(signupError("me", "longpassword12", "different")).toMatch(/match/);
  expect(signupError("me", "longpassword12", "longpassword12")).toBe("");
});

it("deletes an entry supplied by reactive UI state and retains undo data", async () => {
  const journal = new Journal("reactive-delete");
  const data = {
    item_id: "item",
    quantity: "1",
    unit: "tablet",
    note: "example",
  };
  await journal.put("entry", "entry", data);
  const reactive = new Proxy((await journal.read()).records[0].data, {});
  await journal.put("entry", "entry", reactive, true);
  const state = await journal.read();
  expect(state.records[0].deleted).toBe(true);
  expect(state.queue.at(-1)?.deleted).toBe(true);
  await journal.put("entry", "entry", reactive);
  expect((await journal.read()).records[0].deleted).toBe(false);
});

it("persists a profile supplied by reactive UI settings", async () => {
  const { cacheProfile } = await import("./core");
  const profile = new Proxy(
    {
      id: "reactive-profile",
      username: "sample",
      settings: { timezone: "UTC", day_start: 4 },
    },
    {},
  );
  await cacheProfile(profile);
  expect((await cacheProfile())?.settings.day_start).toBe(4);
});
it("retains a durable account-scoped sync requirement after acknowledged writes and a failed pull", async () => {
  const { synchronize } = await import("./core");
  const journal = new Journal("durable-banner");
  await journal.put("day", "day", {
    date: "2026-10-30",
    note: "saved",
    zero: false,
  });
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (_url, options) => {
    const b = JSON.parse(options!.body as string);
    if (++calls === 2) throw new TypeError("offline");
    return new Response(
      JSON.stringify({
        results: b.operations.map((o: any) => ({
          id: o.id,
          status: "applied",
          record: {
            id: o.record_id,
            entity: o.entity,
            version: 1,
            deleted: false,
            data: o.data,
          },
        })),
        changes: [],
        cursor: 1,
        has_more: true,
      }),
    );
  };
  try {
    await expect(synchronize(journal, "Basic test")).rejects.toThrow("offline");
    const restored = await new Journal("durable-banner").read();
    expect(restored.queue).toHaveLength(0);
    expect(restored.syncNeeded).toBe(true);
    expect((await new Journal("other-banner").read()).syncNeeded).toBe(false);
    globalThis.fetch = async () =>
      new Response(
        JSON.stringify({
          results: [],
          changes: [],
          cursor: 1,
          has_more: false,
        }),
      );
    await synchronize(new Journal("durable-banner"), "Basic test");
    expect((await journal.read()).syncNeeded).toBe(false);
  } finally {
    globalThis.fetch = original;
  }
});
it("does not clear a concurrent local write when marking a sync complete", async () => {
  const j = new Journal("concurrent-banner");
  await j.put("day", "day", {
    date: "2026-10-30",
    note: "pending",
    zero: false,
  });
  await j.completeSync();
  expect((await j.read()).syncNeeded).toBe(true);
  expect((await j.read()).queue).toHaveLength(1);
});
it("does not create a pending banner for a failed read-only periodic sync", async () => {
  const { synchronize } = await import("./core");
  const j = new Journal("quiet-banner");
  const original = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new TypeError("offline");
  };
  try {
    await expect(synchronize(j, "Basic test")).rejects.toThrow();
    expect((await j.read()).syncNeeded).toBe(false);
  } finally {
    globalThis.fetch = original;
  }
});

it("sends browser session requests bound to the journal account without a Basic password", async () => {
  const { api } = await import("./core");
  const original = globalThis.fetch;
  let options: RequestInit | undefined;
  globalThis.fetch = async (_url, init) => {
    options = init;
    return new Response("{}");
  };
  try {
    await api("/sync", "session:account-one", { operations: [], cursor: 0 });
    const headers = new Headers(options?.headers);
    expect(headers.get("Authorization")).toBeNull();
    expect(headers.get("X-Intake-Account")).toBe("account-one");
    expect(headers.get("X-Requested-With")).toBe("XMLHttpRequest");
    expect(options?.credentials).toBe("same-origin");
  } finally {
    globalThis.fetch = original;
  }
});

it("identifies expired sessions as authentication errors", async () => {
  const { api, AuthenticationError } = await import("./core");
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response("{}", { status: 401 });
  try {
    await expect(api("/sync", "session:expired", {})).rejects.toBeInstanceOf(
      AuthenticationError,
    );
  } finally {
    globalThis.fetch = original;
  }
});

it("syncs a local change made while the initial empty pull is in flight", async () => {
  const { synchronize } = await import("./core");
  const journal = new Journal("write-during-startup");
  const original = globalThis.fetch;
  let first = true;
  globalThis.fetch = async (_url, options) => {
    const body = JSON.parse(options!.body as string);
    if (first) {
      first = false;
      await journal.put("day", "day", {
        date: "2026-10-30",
        note: "logged during startup",
        zero: false,
      });
    }
    return new Response(
      JSON.stringify({
        results: body.operations.map((op: any) => ({
          id: op.id,
          status: "applied",
          record: {
            id: op.record_id,
            entity: op.entity,
            version: 1,
            data: op.data,
            deleted: false,
          },
        })),
        changes: [],
        cursor: 1,
        has_more: false,
      }),
    );
  };
  try {
    await synchronize(journal, "session:write-during-startup");
    expect((await journal.read()).queue).toHaveLength(0);
    expect((await journal.read()).syncNeeded).toBe(false);
  } finally {
    globalThis.fetch = original;
  }
});

it("refuses to sync a journal under a different restored account", async () => {
  const { synchronize, AuthenticationError } = await import("./core");
  const journal = new Journal("cached-account");
  await journal.put("day", "day", {
    date: "2026-10-30",
    note: "private",
    zero: false,
  });
  const original = globalThis.fetch;
  let requested = false;
  globalThis.fetch = async () => {
    requested = true;
    throw new Error("Unexpected network request");
  };
  try {
    await expect(
      synchronize(journal, "session:another-account"),
    ).rejects.toBeInstanceOf(AuthenticationError);
    expect(requested).toBe(false);
    expect((await journal.read()).queue).toHaveLength(1);
  } finally {
    globalThis.fetch = original;
  }
});

it("stops pulling when a conflict blocks a later edit of the same record", async () => {
  const { synchronize } = await import("./core");
  const journal = new Journal("blocked-startup");
  await journal.put("day", "day", {
    date: "2026-10-30",
    note: "first",
    zero: false,
  });
  const first = (await journal.read()).queue[0];
  await journal.accept({
    results: [{ id: first.id, status: "conflict", message: "Review conflict" }],
    changes: [],
    cursor: 0,
  });
  await journal.put("day", "day", {
    date: "2026-10-30",
    note: "later edit",
    zero: false,
  });
  const original = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async () => {
    if (++requests > 3) throw new Error("Repeated empty sync requests");
    return new Response(
      JSON.stringify({ results: [], changes: [], cursor: 0, has_more: false }),
    );
  };
  try {
    await synchronize(journal, "session:blocked-startup");
    expect(requests).toBe(1);
    expect((await journal.read()).queue).toHaveLength(2);
  } finally {
    globalThis.fetch = original;
  }
});
