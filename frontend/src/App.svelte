<script lang="ts">
  import { onMount } from "svelte";
  import {
    Journal,
    api,
    basic,
    cacheProfile,
    dayKey,
    dayId,
    snapshot,
    synchronize,
    signupError,
    type Profile,
    type Row,
    type State,
  } from "./core";
  import { previewImport, type Preview } from "./import";
  let profile: Profile | undefined = $state(),
    auth = $state(""),
    journal: Journal | undefined,
    store: State = $state({ records: [], queue: [], cursor: 0 });
  let view = $state("today"),
    now = $state(new Date()),
    selected = $state(""),
    modal = $state(""),
    error = $state(""),
    status = $state(""),
    busy = $state(false),
    username = $state(""),
    password = $state("");
  let quickNote = $state(""),
    quickTime = $state(""),
    backdate = $state(false),
    undoKind = $state("delete");
  let name = $state(""),
    color = $state("#8874c7"),
    unit = $state(""),
    amount = $state<string | number>(1),
    presets = $state(""),
    note = $state(""),
    time = $state(""),
    editing: Row | undefined = $state(),
    target: Row | undefined = $state(),
    undo: Row | undefined = $state();
  let timezone = $state(Intl.DateTimeFormat().resolvedOptions().timeZone),
    boundary = $state(0),
    dailyNote = $state(""),
    zero = $state(false),
    importPreview: Preview | undefined = $state();
  const items = $derived(
    store.records
      .filter((r) => r.entity === "item" && !r.deleted)
      .sort((a, b) => a.data.order - b.data.order),
  );
  const entries = $derived(
    store.records
      .filter((r) => r.entity === "entry" && !r.deleted)
      .sort(
        (a, b) =>
          Date.parse(b.data.occurred_at) - Date.parse(a.data.occurred_at),
      ),
  );
  const today = $derived(
    profile
      ? dayKey(now, profile.settings.timezone, profile.settings.day_start)
      : "",
  );
  const activeDate = $derived(selected || today);
  const dayEntries = $derived(
    entries.filter(
      (r) =>
        profile &&
        dayKey(
          r.data.occurred_at,
          profile.settings.timezone,
          profile.settings.day_start,
        ) === activeDate,
    ),
  );
  const todays = $derived(
    entries.filter(
      (r) =>
        profile &&
        dayKey(
          r.data.occurred_at,
          profile.settings.timezone,
          profile.settings.day_start,
        ) === today,
    ),
  );
  const days = $derived(
    Array.from({ length: 7 }, (_, i) =>
      new Date(
        Date.parse((today || "2026-01-01") + "T12:00:00Z") - i * 86400000,
      )
        .toISOString()
        .slice(0, 10),
    ),
  );
  const conflicts = $derived(store.queue.filter((o) => o.blocked));
  let registrationAllowed = $state(false),
    firstRun = $state(false),
    registrationError = $state(""),
    checkingRegistration = $state(false),
    confirmPassword = $state(""),
    authSubmitting = $state(false);
  async function checkRegistration() {
    checkingRegistration = true;
    registrationError = "";
    try {
      const result = await (await api("/registration", "")).json();
      registrationAllowed = result.allowed;
      firstRun = result.first_run;
      if (firstRun && !profile) {
        modal = "signup";
        error = "";
      }
    } catch {
      registrationError =
        "Can’t reach the server. Account creation needs an online connection.";
    } finally {
      checkingRegistration = false;
    }
  }
  let dialogEpoch = 0,
    loginAttempt = 0;
  async function refresh() {
    const active = journal;
    if (!active) return;
    const next = await active.read();
    if (active === journal) {
      store = next;
      if (next.queue.length) syncNeeded = true;
    }
  }
  let syncError = $state(""),
    syncNeeded = $state(false);
  function syncPending() {
    if (!auth) {
      username = profile?.username ?? "";
      modal = "login";
      return;
    }
    void sync();
  }
  async function sync() {
    if (!journal || !auth || busy) return;
    syncError = "";
    busy = true;
    const active = journal,
      credential = auth;
    try {
      await synchronize(active, credential);
      if (active !== journal || credential !== auth) return;
      await refresh();
      if (active === journal) {
        syncNeeded = store.queue.length > 0;
        status = store.queue.length
          ? "Some changes still need attention."
          : "Synced just now";
      }
    } catch (e) {
      if (active === journal) {
        await refresh();
        if (active !== journal) return;
        syncError =
          e instanceof TypeError
            ? "Could not reach the server."
            : (e as Error).message;
        if (syncError === "Sign in again to sync.") auth = "";
        status = syncError;
      }
    } finally {
      busy = false;
    }
  }
  async function write(
    entity: "item" | "entry" | "day",
    id: string,
    data: any,
    deleted = false,
    expected = journal,
  ) {
    if (!expected || expected !== journal) return false;
    error = "";
    try {
      const current = expected;
      await current.put(entity, id, data, deleted);
      if (current !== journal) return false;
      syncNeeded = true;
      await refresh();
      if (current !== journal) return false;
      void sync();
      return true;
    } catch (e) {
      error =
        e instanceof DOMException && e.name === "QuotaExceededError"
          ? "Device storage is full."
          : "Could not save changes. Try again.";
      return false;
    }
  }
  async function login(event: SubmitEvent) {
    event.preventDefault();
    error = "";
    const creating = modal === "signup";
    if (creating) {
      error = signupError(username, password, confirmPassword);
      if (error) return;
      if (!navigator.onLine) {
        error = "Connect to the server to create your account.";
        return;
      }
    }
    const attempt = ++loginAttempt;
    authSubmitting = true;
    try {
      const credential = basic(username.trim(), password);
      const p = await (
        await (creating
          ? api("/signup", "", {
              username: username.trim(),
              password,
              timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            })
          : api("/me", credential))
      ).json();
      if (attempt !== loginAttempt) return;
      dialogEpoch++;
      undo = undefined;
      editing = undefined;
      target = undefined;
      quickNote = "";
      quickTime = "";
      backdate = false;
      selected = "";
      store = { records: [], queue: [], cursor: 0 };
      syncError = "";
      syncNeeded = false;
      profile = p;
      auth = credential;
      password = "";
      confirmPassword = "";
      if (firstRun) registrationAllowed = false;
      firstRun = false;
      journal = new Journal(p.id);
      await cacheProfile(p);
      await refresh();
      modal = "";
      void sync();
    } catch (e) {
      if (attempt === loginAttempt)
        error =
          e instanceof TypeError
            ? "Can’t reach the server. Check your connection and try again."
            : (e as Error).message;
    } finally {
      if (attempt === loginAttempt) authSubmitting = false;
    }
  }
  function focusDialog(node: HTMLDialogElement) {
    const previous = document.activeElement as HTMLElement;
    queueMicrotask(() =>
      node.querySelector<HTMLElement>("input,textarea,select,button")?.focus(),
    );
    return {
      destroy() {
        previous?.focus();
      },
    };
  }
  function close() {
    dialogEpoch++;
    modal = "";
    editing = undefined;
    error = "";
  }
  function itemForm(item?: Row) {
    editing = item;
    name = item?.data.name ?? "";
    color = item?.data.color ?? "#8874c7";
    unit = item?.data.unit ?? "";
    amount = item?.data.amount ?? 1;
    presets = item?.data.presets.join(", ") ?? "";
    modal = "item";
  }
  async function saveItem(event: SubmitEvent) {
    event.preventDefault();
    const p = presets.trim() ? presets.split(",").map((v) => v.trim()) : [];
    if (
      p.some((n) => !Number.isFinite(+n) || +n <= 0) ||
      !name.trim() ||
      !unit.trim() ||
      !(+amount > 0)
    ) {
      error = "Use a name, unit and positive amounts.";
      return;
    }
    if (
      await write("item", editing?.id ?? crypto.randomUUID(), {
        name: name.trim(),
        color,
        unit: unit.trim(),
        amount: String(amount),
        presets: p,
        archived: editing?.data.archived ?? false,
        order: editing?.data.order ?? items.length,
      })
    )
      close();
  }
  function localTime(date = new Date()) {
    return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
      .toISOString()
      .slice(0, 16);
  }
  function logForm(item: Row, entry?: Row) {
    target = item;
    editing = entry;
    amount = entry?.data.quantity ?? item.data.amount;
    note = entry?.data.note ?? "";
    time = localTime(entry ? new Date(entry.data.occurred_at) : new Date());
    modal = "log";
  }
  async function log(item: Row, qty = item.data.amount, custom = false) {
    const active = journal;
    const data: Record<string, any> =
      editing && custom
        ? { ...editing.data }
        : {
            item_id: item.id,
            item_name: item.data.name,
            color: item.data.color,
            unit: item.data.unit,
            timezone: profile!.settings.timezone,
          };
    Object.assign(data, {
      quantity: String(qty),
      occurred_at: custom
        ? new Date(time).toISOString()
        : quickTime
          ? new Date(quickTime).toISOString()
          : new Date().toISOString(),
      note: custom ? note : quickNote,
    });
    const entryId = custom && editing ? editing.id : crypto.randomUUID();
    if (await write("entry", entryId, data, false, active)) {
      const date = dayKey(
        data.occurred_at,
        profile!.settings.timezone,
        profile!.settings.day_start,
      );
      const zeroDay = store.records.find(
        (r) =>
          r.entity === "day" &&
          !r.deleted &&
          r.data.date === date &&
          r.data.zero,
      );
      if (zeroDay)
        await write(
          "day",
          zeroDay.id,
          { ...zeroDay.data, zero: false },
          false,
          active,
        );
      if (active !== journal) return;
      if (!editing) {
        undo = {
          id: entryId,
          entity: "entry",
          version: 0,
          deleted: false,
          data,
        };
        undoKind = "log";
      }
      quickNote = "";
      quickTime = "";
      status = `${qty} ${data.unit} logged`;
      if (custom) close();
    }
  }
  function editEntry(row: Row) {
    logForm(
      items.find((i) => i.id === row.data.item_id) ?? {
        ...row,
        data: { ...row.data, amount: row.data.quantity },
      },
      row,
    );
  }
  async function remove(row: Row) {
    if (await write(row.entity, row.id, row.data, true)) {
      undo = row;
      undoKind = "delete";
      status = "Entry deleted";
      close();
    }
  }
  async function restore() {
    if (undo) {
      await write(undo.entity, undo.id, undo.data, undoKind === "log");
      undo = undefined;
      status = "Undone";
    }
  }
  async function reorder(item: Row, direction: number) {
    const active = journal;
    const index = items.indexOf(item),
      other = items[index + direction];
    if (!other) return;
    await write(
      "item",
      item.id,
      { ...item.data, order: other.data.order },
      false,
      active,
    );
    await write(
      "item",
      other.id,
      { ...other.data, order: item.data.order },
      false,
      active,
    );
  }
  function openDay() {
    const row = store.records.find(
      (r) => r.entity === "day" && !r.deleted && r.data.date === activeDate,
    );
    dailyNote = row?.data.note ?? "";
    zero = row?.data.zero ?? false;
    modal = "day";
  }
  async function saveDay(event: SubmitEvent) {
    event.preventDefault();
    const active = journal;
    if (zero && dayEntries.length) {
      error = "This day has entries. Remove them before marking a zero day.";
      return;
    }
    const row = store.records.find(
      (r) => r.entity === "day" && r.data.date === activeDate,
    );
    const data = { date: activeDate, note: dailyNote, zero };
    const id = row?.id ?? (await dayId(data.date));
    if (await write("day", id, data, false, active)) close();
  }
  async function settings(event: SubmitEvent) {
    event.preventDefault();
    const active = journal,
      identity = profile?.id,
      credential = auth,
      originalModal = modal,
      epoch = dialogEpoch;
    try {
      new Intl.DateTimeFormat("en", { timeZone: timezone });
      const p = await (
        await api(
          "/settings",
          credential,
          { timezone, day_start: +boundary },
          "PUT",
        )
      ).json();
      if (
        active !== journal ||
        identity !== profile?.id ||
        credential !== auth ||
        epoch !== dialogEpoch
      )
        return;
      profile = { ...profile!, settings: p.settings ?? p };
      await cacheProfile(profile);
      if (active !== journal || identity !== profile?.id) return;
      selected = "";
      if (modal === originalModal && epoch === dialogEpoch) close();
    } catch (e) {
      if (
        active === journal &&
        modal === originalModal &&
        epoch === dialogEpoch
      )
        error = (e as Error).message;
    }
  }
  function download(blob: Blob, filename: string) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  async function exportData(xls = false) {
    if (!xls) {
      download(
        new Blob(
          [
            JSON.stringify(
              {
                format: "intake-1",
                settings: profile?.settings,
                ...snapshot(store.records),
              },
              null,
              2,
            ),
          ],
          { type: "application/json" },
        ),
        `intake-${today}.json`,
      );
      return;
    }
    try {
      if (!auth || !navigator.onLine)
        throw new Error(
          "Excel export needs an online sign-in. JSON backup works offline.",
        );
      download(
        await (await api("/export", auth, snapshot(store.records))).blob(),
        `intake-${today}.xls`,
      );
    } catch (e) {
      error = (e as Error).message;
    }
  }
  async function chooseFile(event: Event) {
    const file = (event.target as HTMLInputElement).files?.[0];
    if (!file) return;
    if (file.size > 5_000_000) {
      error = "Choose a file smaller than 5 MB.";
      return;
    }
    importPreview = previewImport(await file.text(), file.name);
  }
  async function importRows() {
    const active = journal;
    if (!importPreview || importPreview.errors.length) return;
    const all = new Map(items.map((i) => [i.id, i]));
    for (const r of importPreview.rows)
      if (r.entity === "item") all.set(r.id, r);
    if (
      importPreview.rows.some(
        (r) => r.entity === "entry" && !all.has(r.data.item_id),
      )
    ) {
      error =
        "Some entries reference unknown item IDs. Import a JSON backup containing those items first.";
      return;
    }
    for (const r of importPreview.rows) {
      const existingDay =
        r.entity === "day"
          ? store.records.find(
              (x) => x.entity === "day" && x.data.date === r.data.date,
            )
          : undefined;
      const id =
        r.entity === "day"
          ? (existingDay?.id ?? (await dayId(r.data.date)))
          : r.id;
      if (!(await write(r.entity, id, r.data, false, active))) return;
    }
    close();
    importPreview = undefined;
    status = "Import saved on this device";
  }
  function count(item: Row, list = todays) {
    return Number(
      list
        .filter((e) => e.data.item_id === item.id)
        .reduce((s, e) => s + Number(e.data.quantity), 0)
        .toPrecision(12),
    );
  }
  function elapsed(item: Row) {
    const e = entries.find((e) => e.data.item_id === item.id);
    if (!e) return "No entries yet";
    const minutes = Math.max(
      0,
      Math.floor((now.getTime() - Date.parse(e.data.occurred_at)) / 60000),
    );
    return minutes < 1
      ? "Just now"
      : minutes < 60
        ? `${minutes}m ago`
        : minutes < 1440
          ? `${Math.floor(minutes / 60)}h ${minutes % 60}m ago`
          : `${Math.floor(minutes / 1440)}d ago`;
  }
  function clock(value: string) {
    return new Intl.DateTimeFormat(undefined, {
      timeZone: profile?.settings.timezone,
      hour: "numeric",
      minute: "2-digit",
    }).format(new Date(value));
  }
  function pretty(date: string) {
    return new Intl.DateTimeFormat(undefined, {
      weekday: "long",
      month: "long",
      day: "numeric",
      timeZone: "UTC",
    }).format(new Date(date + "T12:00:00Z"));
  }
  onMount(() => {
    void (async () => {
      profile = await cacheProfile();
      if (profile) {
        journal = new Journal(profile.id);
        await refresh();
        status = "On this device · sign in to sync";
      } else modal = "login";
      void checkRegistration();
      await navigator.storage?.persist?.();
    })();
    const tick = setInterval(() => (now = new Date()), 30000);
    const retry = setInterval(() => void sync(), 30000);
    const resume = () => void sync();
    window.addEventListener("online", resume);
    window.addEventListener("focus", resume);
    return () => {
      clearInterval(tick);
      clearInterval(retry);
      window.removeEventListener("online", resume);
      window.removeEventListener("focus", resume);
    };
  });
</script>

<svelte:head><title>Intake</title></svelte:head>
<div class="app-shell">
  <header class="topbar">
    <a
      class="wordmark"
      href="/"
      onclick={(e) => {
        e.preventDefault();
        view = "today";
        selected = "";
      }}>intake</a
    ><button
      class="profile-button"
      onclick={() => {
        username = profile?.username ?? "";
        modal = "login";
      }}
      ><span class="connection" class:online={!!auth && navigator.onLine}
      ></span>{profile?.username ?? "Sign in"}<span aria-hidden="true">↗</span
      ></button
    >
  </header>
  <div class="sync-header">
    {#if store.queue.length > 0 || syncNeeded}<section
        class="pending-banner"
        aria-label="Pending changes"
      >
        <div class="pending-copy">
          <strong
            >{store.queue.length
              ? `${store.queue.length} pending ${store.queue.length === 1 ? "change" : "changes"}`
              : "Sync incomplete"}</strong
          ><span role="status" aria-live="polite"
            >{busy
              ? "Syncing…"
              : syncError ||
                (!auth
                  ? "Sign in to sync."
                  : conflicts.length
                    ? `${conflicts.length} require review.`
                    : "Saved on this device.")}</span
          >
        </div>
        <button class="sync-now" disabled={busy} onclick={syncPending}
          >{busy ? "Syncing…" : "Sync now"}<span aria-hidden="true">↻</span
          ></button
        >
      </section>{/if}
    <div class="today-strip">
      <span class="eyebrow">TODAY SO FAR</span>
      <div class="pinned-totals">
        {#each items.filter((i) => !i.data.archived || count(i) > 0) as item}<span
            ><i style={`background:${item.data.color}`}></i><b>{count(item)}</b>
            {item.data.unit}<small>{item.data.name}</small></span
          >{:else}<span class="muted">No items</span>{/each}
      </div>
    </div>
  </div>
  <main>
    {#if !profile}<section class="sign-in-state">
        <button class="primary" onclick={() => (modal = "login")}
          >Sign in <span>↗</span></button
        >
      </section>
    {:else if view === "today"}
      <section class="heading">
        <div>
          <p class="eyebrow">{pretty(activeDate)}</p>
          <h1>
            {activeDate === today ? "Today" : "History"}
          </h1>
        </div>
        <span class="date-stamp"
          >{activeDate.slice(8)}<small
            >{new Intl.DateTimeFormat("en", {
              month: "short",
              timeZone: "UTC",
            }).format(new Date(activeDate + "T12:00Z"))}</small
          ></span
        >
      </section>
      {#if !items.length}<section class="empty-card">
          <button class="primary" onclick={() => itemForm()}
            >Add first item <span>+</span></button
          >
        </section>{:else}
        <div class="section-label">
          <h2>Quick log</h2>
          <button class="text-button" onclick={() => (view = "items")}
            >Manage items ↗</button
          >
        </div>
        <div class="quick-context">
          <label class="sr-only" for="quick-note"
            >Optional note for your next log</label
          ><input
            id="quick-note"
            placeholder="Note for next entry"
            maxlength="10000"
            bind:value={quickNote}
          /><button
            class="now-control"
            onclick={() => (backdate = !backdate)}
            aria-expanded={backdate}
            >◷ {quickTime ? "Custom time" : "Now"} <span>⌄</span></button
          >{#if backdate}<label class="time-control"
              >Log at<input
                aria-label="Time for next log, blank means now"
                type="datetime-local"
                bind:value={quickTime}
              /></label
            ><button
              class="text-button"
              onclick={() => {
                quickTime = "";
                backdate = false;
              }}>Use now</button
            >{/if}
        </div>
        <div class="item-grid">
          {#each items.filter((i) => !i.data.archived) as item}<article
              class="item-card"
              style={`--item-color:${item.data.color}`}
            >
              <div class="item-top">
                <span class="item-dot"></span><span class="micro"
                  >{elapsed(
                    item,
                  )}{#if entries.find((e) => e.data.item_id === item.id)}<small
                      class="last-time"
                      >{clock(
                        entries.find((e) => e.data.item_id === item.id)!.data
                          .occurred_at,
                      )}</small
                    >{/if}</span
                ><button
                  class="icon-button"
                  aria-label={`Log ${item.data.name} with note or time`}
                  onclick={() => logForm(item)}>···</button
                >
              </div>
              <h3>{item.data.name}</h3>
              <div class="card-quantity">
                <strong>{count(item)}</strong><span>{item.data.unit} today</span
                >
              </div>
              <div class="quick-actions">
                <button
                  class="log-button"
                  onclick={() => {
                    editing = undefined;
                    void log(item);
                  }}><span>+</span> {item.data.amount} {item.data.unit}</button
                >{#each item.data.presets.filter((p: number) => p !== item.data.amount) as preset}<button
                    class="preset"
                    aria-label={`Log ${preset} ${item.data.unit} of ${item.data.name}`}
                    onclick={() => {
                      editing = undefined;
                      void log(item, preset);
                    }}>+{preset}</button
                  >{/each}
              </div>
            </article>{/each}
        </div>{/if}
      <div class="section-label timeline-label">
        <h2>Timeline <span>{dayEntries.length}</span></h2>
        <button class="text-button" onclick={openDay}
          >Day note <span>↗</span></button
        >
      </div>
      {#if dayEntries.length}<div class="timeline">
          {#each dayEntries as entry}<button
              class="timeline-row"
              onclick={() => editEntry(entry)}
              ><time>{clock(entry.data.occurred_at)}</time><span
                class="timeline-dot"
                style={`background:${entry.data.color}`}
              ></span><span class="entry-copy"
                ><strong>{entry.data.item_name}</strong
                >{#if entry.data.note}<small>{entry.data.note}</small
                  >{/if}</span
              ><span class="entry-amount"
                >{entry.data.quantity} <small>{entry.data.unit}</small></span
              ><span class="entry-arrow">↗</span></button
            >{/each}
        </div>{:else}<div class="empty-timeline">
          <p>
            {store.records.some(
              (r) =>
                r.entity === "day" &&
                !r.deleted &&
                r.data.date === activeDate &&
                r.data.zero,
            )
              ? "Zero day"
              : "No entries"}
          </p>
        </div>{/if}
      {#each store.records.filter((r) => r.entity === "day" && !r.deleted && r.data.date === activeDate && r.data.note) as day}<button
          class="day-note"
          onclick={openDay}
          ><span class="eyebrow">DAY NOTE</span>
          <p>{day.data.note}</p>
          <span>↗</span></button
        >{/each}
    {:else if view === "week"}
      <section class="heading">
        <div>
          <h1>History</h1>
        </div>
      </section>
      <div class="week-list">
        {#each days as date}{@const list = entries.filter(
            (e) =>
              dayKey(
                e.data.occurred_at,
                profile!.settings.timezone,
                profile!.settings.day_start,
              ) === date,
          )}{@const d = store.records.find(
            (r) => r.entity === "day" && !r.deleted && r.data.date === date,
          )}<button
            class="week-day"
            onclick={() => {
              selected = date;
              view = "today";
            }}
            ><span class="week-date"
              ><strong
                >{date === today
                  ? "Today"
                  : new Intl.DateTimeFormat("en", {
                      weekday: "long",
                      timeZone: "UTC",
                    }).format(new Date(date + "T12:00Z"))}</strong
              ><small>{date}</small></span
            ><span class="week-counts"
              >{#each items.filter((i) => count(i, list) > 0) as i}<span
                  ><i style={`background:${i.data.color}`}></i>{count(i, list)}
                  {i.data.unit}<small>{i.data.name}</small></span
                >{:else}<small>{d?.data.zero ? "Zero day" : "Not logged"}</small
                >{/each}{#if d?.data.note}<em>Note added</em>{/if}</span
            ><span>↗</span></button
          >{/each}
      </div>
    {:else if view === "items"}
      <section class="heading">
        <div>
          <h1>Items</h1>
        </div>
        <button
          class="round-button"
          aria-label="Add item"
          onclick={() => itemForm()}>+</button
        >
      </section>
      <div class="manage-list">
        {#each items as item, i}<article
            class="manage-item"
            class:archived={item.data.archived}
          >
            <i style={`background:${item.data.color}`}></i>
            <div>
              <h3>
                {item.data.name}
                {#if item.data.archived}<small>Archived</small>{/if}
              </h3>
              <p>
                {item.data.amount}
                {item.data.unit} per tap · {item.data.presets.length} presets
              </p>
            </div>
            <div class="manage-actions">
              <button
                class="icon-button"
                disabled={i === 0}
                aria-label={`Move ${item.data.name} up`}
                onclick={() => reorder(item, -1)}>↑</button
              ><button
                class="icon-button"
                disabled={i === items.length - 1}
                aria-label={`Move ${item.data.name} down`}
                onclick={() => reorder(item, 1)}>↓</button
              ><button class="text-button" onclick={() => itemForm(item)}
                >Edit</button
              ><button
                class="text-button"
                onclick={() =>
                  write("item", item.id, {
                    ...item.data,
                    archived: !item.data.archived,
                  })}>{item.data.archived ? "Restore" : "Archive"}</button
              >
            </div>
          </article>{:else}<div class="empty-card">
            <button class="primary" onclick={() => itemForm()}
              >Add first item +</button
            >
          </div>{/each}
      </div>
    {:else}
      <section class="heading">
        <div>
          <h1>Settings</h1>
        </div>
      </section>
      <div class="settings-grid">
        <section class="settings-card">
          <h2>Timezone</h2>
          <p>
            {profile.settings.timezone}<br />Day starts at {String(
              profile.settings.day_start,
            ).padStart(2, "0")}:00.
          </p>
          <button
            class="text-button"
            onclick={() => {
              timezone = profile!.settings.timezone;
              boundary = profile!.settings.day_start;
              modal = "settings";
            }}>Change timezone ↗</button
          >
        </section>
        <section class="settings-card">
          <h2>Export</h2>
          <p>Includes unsynced changes.</p>
          <button class="secondary" onclick={() => exportData()}
            >JSON backup ↓</button
          ><button class="text-button" onclick={() => exportData(true)}
            >Excel (.xls) ↓</button
          >
        </section>
        <section class="settings-card">
          <h2>Import</h2>
          <p>
            Import a JSON backup or a CSV file. Review everything before saving.
          </p>
          <button
            class="text-button"
            onclick={() => {
              importPreview = undefined;
              modal = "import";
            }}>Import a file ↗</button
          >
        </section>
        <section class="settings-card">
          <h2>Sync</h2>
          <p>
            {store.queue.length
              ? `${store.queue.length} change${store.queue.length === 1 ? "" : "s"} waiting to sync.`
              : "Saved on this device."}<br />{auth
              ? "Signed in for sync."
              : "Sign in online to sync across devices."}
          </p>
          <button
            class="text-button"
            onclick={() => (auth ? sync() : (modal = "login"))}
            >{busy ? "Syncing…" : auth ? "Sync now ↻" : "Sign in ↗"}</button
          ><small class="micro"
            >Offline records may differ from other devices.</small
          >
        </section>
      </div>
    {/if}
    {#if conflicts.length}<section class="conflicts">
        <h2>Sync conflicts</h2>
        <p>Review conflicting or invalid changes.</p>
        {#each conflicts as op}<div>
            <strong
              >{op.entity}: {op.data.name ??
                op.data.item_name ??
                op.data.date}</strong
            >
            <p>{op.blocked}</p>
            <details>
              <summary>Compare versions</summary>
              <p>On this device</p>
              <pre>{JSON.stringify(
                  store.records.find(
                    (r) => r.entity === op.entity && r.id === op.record_id,
                  )?.data ?? op.data,
                  null,
                  2,
                )}</pre>
              <p>On server</p>
              <pre>{JSON.stringify(op.server?.data ?? {}, null, 2)}</pre>
            </details>
            <button
              class="secondary"
              onclick={async () => {
                await journal!.resolve(op, true);
                await refresh();
                void sync();
              }}>Keep local</button
            ><button
              class="text-button"
              onclick={async () => {
                const copy = await journal!.resolve(op, false);
                download(
                  new Blob([JSON.stringify({ record: copy }, null, 2)], {
                    type: "application/json",
                  }),
                  "intake-conflict-copy.json",
                );
                await refresh();
              }}
              >{op.server
                ? "Use server & save local copy"
                : "Discard local & save a copy"}</button
            >
          </div>{/each}
      </section>{/if}
    {#if error && !modal}<p class="error" role="alert">{error}</p>{/if}
    <footer class="page-footer">
      <span class="sync-state" role="status"
        >{busy
          ? "Syncing…"
          : store.queue.length
            ? `${store.queue.length} pending · saved locally`
            : status || "Saved on this device"}</span
      >
    </footer>
  </main>
  <nav class="bottom-nav" aria-label="Main navigation">
    {#each [["today", "◷", "Today"], ["week", "▥", "History"], ["items", "◌", "Items"], ["settings", "⚙", "Settings"]] as [key, icon, label]}<button
        class:active={view === key}
        onclick={() => {
          view = key;
          selected = "";
        }}
        aria-current={view === key ? "page" : undefined}
        ><span>{icon}</span>{label}</button
      >{/each}
  </nav>
  {#if undo}<div class="toast" role="status">
      {undoKind === "log" ? "Entry logged." : "Entry deleted."}<button
        onclick={restore}>Undo</button
      ><button aria-label="Dismiss undo" onclick={() => (undo = undefined)}
        >×</button
      >
    </div>{/if}
</div>

{#if modal}
  <div
    class="modal-backdrop"
    role="presentation"
    onclick={(e) => {
      if (e.target === e.currentTarget && profile) close();
    }}
  >
    <dialog
      open
      use:focusDialog
      aria-modal="true"
      aria-labelledby="dialog-title"
      onkeydown={(e) => {
        if (e.key === "Escape" && profile) close();
        if (e.key === "Tab") {
          const controls = Array.from(
            e.currentTarget.querySelectorAll<HTMLElement>(
              "button,input,select,textarea,a[href]",
            ),
          ).filter((el) => !el.hasAttribute("disabled"));
          const first = controls[0],
            last = controls.at(-1);
          if (e.shiftKey && document.activeElement === first) {
            e.preventDefault();
            last?.focus();
          } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault();
            first?.focus();
          }
        }
      }}
    >
      <div class="dialog-totals" aria-label="Today totals">
        <span class="eyebrow">TODAY</span
        >{#each items.filter((i) => !i.data.archived || count(i) > 0) as item}<span
            ><i style={`background:${item.data.color}`}></i>{count(item)}
            {item.data.unit}<small>{item.data.name}</small></span
          >{/each}
      </div>
      <div class="dialog-top">
        {#if profile}<button
            class="icon-button"
            aria-label="Close dialog"
            onclick={close}>×</button
          >{/if}
      </div>
      {#if modal === "login" || modal === "signup"}<h2 id="dialog-title">
          {modal === "signup" ? "Create account" : "Sign in"}
        </h2>
        <form onsubmit={login}>
          <label
            >Username<input
              required
              autocomplete="username"
              maxlength="64"
              autocapitalize="none"
              spellcheck={false}
              pattern={modal === "signup"
                ? "[A-Za-z0-9_.\\-]{1,64}"
                : undefined}
              bind:value={username}
            /></label
          ><label
            >Password<input
              type="password"
              required
              autocomplete={modal === "signup"
                ? "new-password"
                : "current-password"}
              minlength={modal === "signup" ? 12 : undefined}
              maxlength="1024"
              bind:value={password}
            /></label
          >{#if modal === "signup"}<label
              >Confirm password<input
                type="password"
                required
                autocomplete="new-password"
                minlength="12"
                maxlength="1024"
                bind:value={confirmPassword}
              /></label
            >
            <p class="micro">
              At least 12 characters. Choose a unique password.
            </p>{/if}<button
            class="primary"
            type="submit"
            disabled={authSubmitting}
            >{authSubmitting
              ? "Submitting…"
              : modal === "signup"
                ? "Create account"
                : "Sign in"} <span>↗</span></button
          >
        </form>
        {#if modal === "signup"}<button
            class="text-button"
            onclick={() => {
              modal = "login";
              error = "";
              confirmPassword = "";
            }}>Sign in ↗</button
          >{:else if registrationAllowed}<button
            class="text-button"
            onclick={() => {
              modal = "signup";
              error = "";
              password = "";
              confirmPassword = "";
            }}>Create an account ↗</button
          >{/if}
        {#if registrationError}<p class="error">{registrationError}</p>
          <button
            class="text-button"
            disabled={checkingRegistration}
            onclick={checkRegistration}
            >{checkingRegistration ? "Checking…" : "Try again ↻"}</button
          >{/if}
        {#if profile}<button
            class="text-button"
            onclick={() => {
              auth = "";
              close();
              status = "Offline mode · saved on this device";
            }}>Continue on this device</button
          >{/if}
        <p class="micro">
          Account changes require an online sign-in. Passwords are never stored.
        </p>
      {:else if modal === "item"}<h2 id="dialog-title">
          {editing ? "Edit item" : "Add item"}
        </h2>
        <form onsubmit={saveItem}>
          <label
            >Name<input
              required
              maxlength="120"
              placeholder="Name"
              bind:value={name}
            /></label
          >
          <div class="form-row">
            <label
              >Unit<input
                required
                maxlength="40"
                placeholder="Unit"
                bind:value={unit}
              /></label
            ><label
              >Amount per tap<input
                type="text"
                inputmode="decimal"
                required
                pattern="[0-9]+([.][0-9]+)?"
                bind:value={amount}
              /></label
            ><label class="color-label"
              >Color<input type="color" bind:value={color} /></label
            >
          </div>
          <label
            >Other quick amounts <small>optional · separated by commas</small
            ><input
              placeholder="Comma-separated amounts"
              bind:value={presets}
            /></label
          ><button class="primary" type="submit"
            >Save item <span>✓</span></button
          >
        </form>
      {:else if modal === "log" && target}<h2 id="dialog-title">
          {editing ? "Edit entry" : "Log intake"}
        </h2>
        <form
          onsubmit={(e) => {
            e.preventDefault();
            void log(target!, amount, true);
          }}
        >
          <label
            >Amount ({editing?.data.unit ?? target.data.unit})<input
              type="text"
              inputmode="decimal"
              pattern="[0-9]+([.][0-9]+)?"
              required
              bind:value={amount}
            /></label
          ><label
            >When <small>in this device’s local time</small><input
              type="datetime-local"
              required
              bind:value={time}
            /></label
          ><label
            >A note <small>optional</small><textarea
              rows="3"
              maxlength="10000"
              placeholder="Note"
              bind:value={note}></textarea></label
          ><button class="primary" type="submit"
            >{editing ? "Save changes" : "Log intake"} <span>✓</span></button
          >{#if editing}<button
              class="danger-button"
              type="button"
              onclick={() => remove(editing!)}>Delete entry</button
            >{/if}
        </form>
      {:else if modal === "day"}<h2 id="dialog-title">Day note</h2>
        <form onsubmit={saveDay}>
          <label
            >Note<textarea
              rows="5"
              maxlength="10000"
              placeholder="Note"
              bind:value={dailyNote}></textarea></label
          ><label class="checkbox"
            ><input
              type="checkbox"
              bind:checked={zero}
              disabled={dayEntries.length > 0}
            /><span
              >Mark as zero day<small
                >{dayEntries.length ? "This day has entries." : ""}</small
              ></span
            ></label
          ><button class="primary">Save day note <span>✓</span></button>
        </form>
      {:else if modal === "settings"}<h2 id="dialog-title">Timezone</h2>
        <p>
          Changing these settings regroups your timeline. Entries keep their
          exact original times.
        </p>
        <form onsubmit={settings}>
          <label
            >Timezone<input
              required
              list="timezones"
              bind:value={timezone}
            /><datalist id="timezones"
              >{#each Intl.supportedValuesOf("timeZone") as zone}<option
                  value={zone}
                ></option>{/each}</datalist
            ></label
          ><label
            >New day begins<select bind:value={boundary}
              >{#each Array.from({ length: 24 }, (_, i) => i) as h}<option
                  value={h}>{String(h).padStart(2, "0")}:00</option
                >{/each}</select
            ></label
          ><button class="primary" disabled={!auth || !navigator.onLine}
            >Save settings <span>✓</span></button
          >{#if !auth}<p class="micro">
              Sign in online to change account settings.
            </p>{/if}
        </form>
      {:else if modal === "import"}<h2 id="dialog-title">Import</h2>
        <p>
          Choose an Intake JSON backup or a CSV with explicit times and item
          IDs. Nothing is saved until you confirm.
        </p>
        <label class="file-picker"
          >Choose JSON or CSV<input
            type="file"
            accept=".json,.csv,application/json,text/csv"
            onchange={chooseFile}
          /></label
        >
        <details>
          <summary>CSV column guide</summary>
          <p class="micro">
            Required: item_id, item_name, quantity, unit, occurred_at, timezone,
            color. Optional: id, note. Times must include Z or an explicit
            offset. Item IDs must already exist. Export JSON to find them.
          </p>
        </details>
        {#if importPreview}<div class="import-preview">
            <h3>{importPreview.rows.length} records to review</h3>
            {#each importPreview.errors as message}<p class="error">
                {message}
              </p>{/each}
            <p class="micro">
              Existing matching IDs will be updated. Conflicting remote edits
              are preserved for review.
            </p>
            <div class="preview-scroll">
              {#each importPreview.rows.slice(0, 100) as row}<div>
                  <b>{row.entity}</b><span
                    >{row.data.name ??
                      row.data.item_name ??
                      row.data.date}</span
                  ><small
                    >{row.data.quantity ??
                      row.data.note ??
                      row.data.unit}</small
                  >
                </div>{/each}
            </div>
            <button
              class="primary"
              disabled={!!importPreview.errors.length ||
                !importPreview.rows.length}
              onclick={importRows}>Confirm import <span>↓</span></button
            >
          </div>{/if}
      {/if}
      {#if error}<p class="error" role="alert">{error}</p>{/if}
    </dialog>
  </div>
{/if}
