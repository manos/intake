<script lang="ts">
  import { untrack } from "svelte";
  import type { Profile, Row } from "./core";
  import {
    addDays,
    calendarDates,
    historyDays,
    historyItems,
    historySummary,
    monthRange,
    quantityTotals,
    timePosition,
    weekStart,
    type HistoryDay,
    type HistoryItem,
  } from "./history";
  let {
    records,
    profile,
    today,
    onentry,
    onday,
  }: {
    records: Row[];
    profile: Profile;
    today: string;
    onentry: (entry: Row) => void;
    onday: (date: string) => void;
  } = $props();
  type Mode = "week" | "timeline" | "item" | "calendar";
  let mode = $state<Mode>("week"),
    itemId = $state(""),
    metric = $state("entries");
  const initialWeek = untrack(() => weekStart(today));
  let from = $state(initialWeek),
    to = $state(addDays(initialWeek, 6));
  const options = $derived(historyItems(records));
  const chosen = $derived(options.find((i) => i.id === itemId));
  const shownItems = $derived(
    options.filter((i) => !itemId || i.id === itemId),
  );
  const range = $derived.by(() => {
    try {
      return {
        days: historyDays(records, profile.settings, from, to, itemId),
        error: "",
      };
    } catch (error) {
      return { days: [] as HistoryDay[], error: (error as Error).message };
    }
  });
  const entries = $derived(range.days.flatMap((d) => d.entries));
  const summary = $derived(historySummary(range.days));
  const showEntryNotes = $derived(!(mode === "item" && chosen));
  const notedDays = $derived(
    [...range.days]
      .reverse()
      .filter(
        (day) =>
          day.note.trim() ||
          (showEntryNotes &&
            day.entries.some((entry) => entry.data.note?.trim())),
      ),
  );
  const calendar = $derived(
    mode === "calendar" && !range.error ? calendarDates(from) : [],
  );
  const dayMap = $derived(new Map(range.days.map((d) => [d.date, d])));
  const period = $derived(
    from === to ? dateLabel(from) : `${dateLabel(from)} – ${dateLabel(to)}`,
  );
  const monthLabel = $derived(
    dateLabel(from, { month: "long", year: "numeric" }),
  );
  const charts = $derived(
    shownItems.map((item) => {
      const list = itemEntries(item);
      const totals = quantityTotals(list);
      const units =
        metric === "entries" ? ["entries"] : totals.map((t) => t.unit);
      return {
        item,
        count: list.length,
        totals,
        series: units.map((unit) => {
          const days = range.days.map((day) => {
            const matching = itemEntries(item, day);
            const amount =
              metric === "entries"
                ? matching.length
                : (quantityTotals(matching).find((t) => t.unit === unit)
                    ?.quantity ?? 0);
            return { day: { ...day, entries: matching }, amount };
          });
          return {
            unit,
            days,
            maximum: Math.max(1, ...days.map((d) => d.amount)),
          };
        }),
      };
    }),
  );

  function dateLabel(
    date: string,
    format: Intl.DateTimeFormatOptions = {
      month: "short",
      day: "numeric",
      year: "numeric",
    },
  ) {
    if (!date || !Number.isFinite(Date.parse(`${date}T12:00Z`)))
      return "Select dates";
    return new Intl.DateTimeFormat(undefined, {
      ...format,
      timeZone: "UTC",
    }).format(new Date(`${date}T12:00Z`));
  }
  function clock(timestamp: string, full = false) {
    return new Intl.DateTimeFormat(undefined, {
      timeZone: profile.settings.timezone,
      hour: "numeric",
      minute: "2-digit",
      ...(full
        ? ({
            year: "numeric",
            month: "short",
            day: "numeric",
            timeZoneName: "short",
          } as const)
        : {}),
    }).format(new Date(timestamp));
  }
  function fmt(value: number) {
    return new Intl.NumberFormat(undefined, {
      maximumSignificantDigits: 12,
    }).format(value);
  }
  function interval(value: number | null) {
    if (value === null) return "—";
    const minutes = Math.round(value / 60000);
    return minutes < 60
      ? `${minutes} min`
      : minutes < 1440
        ? `${fmt(Math.round(minutes / 6) / 10)} hr`
        : `${fmt(Math.round(minutes / 144) / 10)} days`;
  }
  function setMode(next: Mode) {
    mode = next;
    if (next === "calendar") [from, to] = monthRange(from || today);
  }
  function move(direction: number) {
    if (range.error) return;
    if (mode === "calendar") [from, to] = monthRange(from, direction);
    else {
      const length = range.days.length;
      from = addDays(from, direction * length);
      to = addDays(to, direction * length);
    }
  }
  function resetPeriod() {
    if (mode === "calendar") [from, to] = monthRange(today);
    else {
      from = weekStart(today);
      to = addDays(from, 6);
    }
  }
  function selectItem(id: string) {
    itemId = id;
    mode = "item";
  }
  function itemEntries(item: HistoryItem, day?: HistoryDay) {
    return (day?.entries ?? entries).filter((e) => e.data.item_id === item.id);
  }
  function stateLabel(day: HistoryDay) {
    return day.entries.length
      ? `${day.entries.length} ${day.entries.length === 1 ? "entry" : "entries"}`
      : day.state === "zero"
        ? "Zero day"
        : day.state === "recorded"
          ? "Other items logged"
          : day.date > today
            ? "Upcoming"
            : "Not logged";
  }
  function dots(day: HistoryDay) {
    const lanes: number[][] = [];
    return day.entries.map((entry) => {
      const position = timePosition(entry.data.occurred_at, profile.settings);
      let lane = lanes.findIndex((points) =>
        points.every((p) => Math.abs(p - position) > 0.065),
      );
      if (lane < 0) {
        lane = lanes.length;
        lanes.push([]);
      }
      lanes[lane].push(position);
      return { entry, position, lane };
    });
  }
  function dotLabel(entry: Row) {
    return `${entry.data.item_name}, ${entry.data.quantity} ${entry.data.unit}, ${clock(entry.data.occurred_at, true)}${entry.data.note ? `, ${entry.data.note}` : ""}`;
  }
</script>

<section class="heading history-heading">
  <div>
    <p class="eyebrow">JOURNAL</p>
    <h1>History</h1>
  </div>
  <button class="text-button" onclick={resetPeriod}
    >Current {mode === "calendar" ? "month" : "week"} ↗</button
  >
</section>
<div class="history-tabs" role="group" aria-label="History views">
  {#each [["week", "Week"], ["timeline", "Timeline"], ["item", "By item"], ["calendar", "Calendar"]] as [key, label]}<button
      class:active={mode === key}
      aria-pressed={mode === key}
      onclick={() => setMode(key as Mode)}>{label}</button
    >{/each}
</div>
<div class="history-filters">
  <label class="history-item-filter"
    >Item<select aria-label="History item" bind:value={itemId}
      ><option value="">All items</option>{#each options as item}<option
          value={item.id}
          >{item.name}{item.archived ? " (archived)" : ""}</option
        >{/each}</select
    ></label
  >
  {#if mode === "calendar"}<label
      >Month<input
        aria-label="History month"
        type="month"
        value={from.slice(0, 7)}
        onchange={(e) => {
          if (e.currentTarget.value)
            [from, to] = monthRange(e.currentTarget.value + "-01");
        }}
      /></label
    >{:else}
    <label
      >From<input
        aria-label="History from"
        type="date"
        bind:value={from}
      /></label
    ><label
      >Through<input
        aria-label="History through"
        type="date"
        bind:value={to}
      /></label
    >
  {/if}
</div>
<div class="history-period">
  <button
    class="history-arrow"
    aria-label="Previous period"
    disabled={!!range.error}
    onclick={() => move(-1)}>←</button
  ><strong>{mode === "calendar" ? monthLabel : period}</strong><button
    class="history-arrow"
    aria-label="Next period"
    disabled={!!range.error}
    onclick={() => move(1)}>→</button
  >
</div>
{#if range.error}<p class="error" role="alert">{range.error}</p>{:else}
  <div class="history-summary" aria-label="Period summary">
    <div><strong>{fmt(summary.entries)}</strong><span>Entries</span></div>
    <div><strong>{summary.daysUsed}</strong><span>Days with entries</span></div>
    {#if chosen}<div>
        <strong>{interval(summary.medianInterval)}</strong><span
          >Median interval</span
        >
      </div>{/if}
  </div>
  {#if chosen}<div class="history-selected">
      <i style={`background:${chosen.color}`}></i>
      <h2>{chosen.name}</h2>
      {#each quantityTotals(entries) as total}<span
          ><b>{fmt(total.quantity)}</b> {total.unit}</span
        >{/each}
    </div>{/if}

  {#if mode === "week" || (mode === "item" && chosen)}
    <div class="history-chart-heading">
      <h2>{mode === "item" ? "Daily use" : "Daily totals"}</h2>
      <div class="history-metric" role="group" aria-label="Chart measure">
        <button
          class:active={metric === "entries"}
          aria-pressed={metric === "entries"}
          onclick={() => (metric = "entries")}>Entries</button
        ><button
          class:active={metric === "amount"}
          aria-pressed={metric === "amount"}
          onclick={() => (metric = "amount")}>Amount</button
        >
      </div>
    </div>
    {#each charts as chart}{@const item = chart.item}
      <section
        class="history-chart"
        aria-label={`${item.name} daily chart`}
        style={`--history-color:${item.color}`}
      >
        <div class="history-chart-title">
          <button onclick={() => selectItem(item.id)}
            ><i style={`background:${item.color}`}></i>{item.name}
            <span>↗</span></button
          ><small
            >{chart.count} entries{#each chart.totals as total}
              · {fmt(total.quantity)} {total.unit}{/each}</small
          >
        </div>
        {#each chart.series as series}{@const unit = series.unit}
          <div class="history-chart-scale">
            <span>{metric === "entries" ? "Entries" : unit}</span><span
              >max {fmt(series.maximum)}</span
            >
          </div>
          <div class="history-chart-scroll">
            <div
              class="history-bars"
              style={`--history-days:${range.days.length}; min-width:${Math.max(0, range.days.length * 32)}px`}
            >
              {#each series.days as { day, amount }}<button
                  class="history-bar-day"
                  aria-label={`${dateLabel(day.date)}: ${fmt(amount)} ${unit}; ${stateLabel(day)}`}
                  onclick={() => onday(day.date)}
                >
                  <span class="history-bar-space"
                    ><span class="history-bar-value"
                      >{amount
                        ? fmt(amount)
                        : day.state === "zero"
                          ? "0"
                          : ""}</span
                    ><span
                      class="history-bar"
                      class:unlogged={!day.entries.length &&
                        day.state !== "zero"}
                      style={`height:${amount ? Math.max(3, (amount / series.maximum) * 90) : 2}px`}
                    ></span></span
                  >
                  <span class="history-bar-label"
                    >{dateLabel(day.date, { weekday: "short" })}<small
                      >{day.date.slice(8)}</small
                    ></span
                  >
                </button>{/each}
            </div>
          </div>
        {:else}<p class="history-empty">
            No quantities recorded in this range.
          </p>{/each}
      </section>{:else}<p class="history-empty">No items.</p>{/each}
    <p class="history-legend">Dashed: not logged · 0: confirmed zero day</p>
  {:else if mode === "timeline"}
    <div class="history-chart-heading">
      <h2>Time of day</h2>
      <small>{profile.settings.timezone}</small>
    </div>
    <div
      class="history-timeline-scroll"
      role="region"
      aria-label="Exact-time history timeline"
    >
      <div class="history-time-grid">
        <div class="history-time-axis">
          <span>Day</span>
          <div>
            {#each [0, 6, 12, 18, 24] as hour}<span
                style={`left:${(hour / 24) * 100}%`}
                >{String((profile.settings.day_start + hour) % 24).padStart(
                  2,
                  "0",
                )}:00</span
              >{/each}
          </div>
        </div>
        {#each range.days as day}{@const placed = dots(day)}
          <div class="history-time-row">
            <button class="history-time-date" onclick={() => onday(day.date)}
              ><b>{dateLabel(day.date, { weekday: "short" })}</b><small
                >{dateLabel(day.date, {
                  month: "short",
                  day: "numeric",
                })}</small
              ></button
            >
            <div
              class="history-time-track"
              style={`height:${Math.max(52, (Math.max(-1, ...placed.map((d) => d.lane)) + 1) * 36 + 12)}px`}
            >
              {#each placed as dot}<button
                  class="history-time-dot"
                  style={`left:${dot.position * 100}%; top:${dot.lane * 36 + 6}px; --history-color:${dot.entry.data.color}`}
                  aria-label={dotLabel(dot.entry)}
                  title={dotLabel(dot.entry)}
                  onclick={() => onentry(dot.entry)}><span></span></button
                >{:else}<span class="history-time-empty">{stateLabel(day)}</span
                >{/each}
            </div>
          </div>{/each}
      </div>
    </div>
    <div class="history-item-key">
      {#each shownItems as item}<button onclick={() => selectItem(item.id)}
          ><i style={`background:${item.color}`}></i>{item.name}</button
        >{/each}
    </div>
  {:else if mode === "calendar"}
    <div class="history-calendar-weekdays" aria-hidden="true">
      {#each ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as day}<span
          >{day}</span
        >{/each}
    </div>
    <div class="history-calendar" aria-label={monthLabel}>
      {#each calendar as date}{@const day = dayMap.get(date)}<button
          class="history-calendar-day"
          class:outside={!day}
          class:today={date === today}
          class:confirmed-zero={day?.state === "zero"}
          disabled={!day}
          aria-label={`${dateLabel(date)}: ${day ? stateLabel(day) : "Outside this month"}`}
          onclick={() => onday(date)}
        >
          <span>{Number(date.slice(8))}</span>{#if day?.entries.length}<b
              >{day.entries.length}</b
            >
            <div class="history-calendar-dots">
              {#each [...new Set(day.entries.map((e) => e.data.color))].slice(0, 4) as color}<i
                  style={`background:${color}`}
                ></i>{/each}
            </div>{:else if day?.state === "zero"}<b class="calendar-zero">0</b
            >{:else}<small>{day && date <= today ? "—" : ""}</small>{/if}
        </button>{/each}
    </div>
    <p class="history-legend">
      Count: entries · 0: confirmed zero day · —: not logged{itemId
        ? " or no matching entries"
        : ""}
    </p>
  {/if}

  {#if mode === "item" && !chosen}
    <div class="history-item-cards">
      {#each options as item}{@const list = entries.filter(
          (e) => e.data.item_id === item.id,
        )}<button class="history-item-card" onclick={() => selectItem(item.id)}
          ><div>
            <i style={`background:${item.color}`}></i>
            <h2>{item.name}</h2>
            <span>↗</span>
          </div>
          <strong>{list.length} <small>entries</small></strong>
          <p>
            {#each quantityTotals(list) as total}<span
                >{fmt(total.quantity)} {total.unit}</span
              >{/each}
          </p>
          {#if item.archived}<small>Archived</small>{/if}</button
        >{:else}<p class="history-empty">No items.</p>{/each}
    </div>
  {/if}
  {#if mode === "item" && chosen}
    <div class="history-chart-heading">
      <h2>Entries</h2>
      <small>{summary.entries}</small>
    </div>
    {#each [...range.days]
      .reverse()
      .filter((d) => d.entries.length) as day}<section
        class="history-entry-day"
      >
        <button class="history-entry-date" onclick={() => onday(day.date)}
          >{dateLabel(day.date, {
            weekday: "long",
            month: "short",
            day: "numeric",
          })} ↗</button
        >{#each [...day.entries].reverse() as entry}<button
            class="history-entry"
            onclick={() => onentry(entry)}
            ><time title={clock(entry.data.occurred_at, true)}
              >{clock(entry.data.occurred_at)}</time
            >
            <div>
              <strong>{entry.data.item_name}</strong>{#if entry.data.note}<small
                  class="history-note-text">{entry.data.note}</small
                >{/if}
            </div>
            <span>{entry.data.quantity} <small>{entry.data.unit}</small></span
            ><span>↗</span></button
          >{/each}
      </section>{:else}<p class="history-empty">
        No entries in this range.
      </p>{/each}
  {/if}
  {#if notedDays.length}<section
      class="history-notes"
      aria-label="History notes"
    >
      <h2>Notes</h2>
      {#each notedDays as day}<section class="history-notes-day">
          <button class="history-entry-date" onclick={() => onday(day.date)}
            >{dateLabel(day.date, {
              weekday: "long",
              month: "short",
              day: "numeric",
              year: "numeric",
            })} ↗</button
          >
          {#if day.note.trim()}<button
              class="history-day-note"
              onclick={() => onday(day.date)}
              ><span class="eyebrow">DAY NOTE</span>
              <p class="history-note-text">{day.note}</p></button
            >{/if}
          {#if showEntryNotes}{#each [...day.entries]
              .reverse()
              .filter((entry) => entry.data.note?.trim()) as entry}<button
                class="history-noted-entry"
                onclick={() => onentry(entry)}
              >
                <span class="history-note-meta"
                  ><time title={clock(entry.data.occurred_at, true)}
                    >{clock(entry.data.occurred_at)}</time
                  ><i style={`background:${entry.data.color}`}></i><strong
                    >{entry.data.item_name}</strong
                  ><span>{entry.data.quantity} {entry.data.unit}</span></span
                >
                <p class="history-note-text">{entry.data.note}</p>
              </button>{/each}{/if}
        </section>{/each}
    </section>{/if}
{/if}
