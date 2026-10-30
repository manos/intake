import { dayKey, type Profile, type Row } from "./core";

type Settings = Profile["settings"];
export interface HistoryItem {
  id: string;
  name: string;
  color: string;
  archived: boolean;
}
export interface HistoryDay {
  date: string;
  entries: Row[];
  allEntries: Row[];
  state: "recorded" | "zero" | "unlogged";
  note: string;
}
function dateMillis(date: string) {
  const value = Date.parse(`${date}T12:00:00Z`);
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(date) ||
    !Number.isFinite(value) ||
    new Date(value).toISOString().slice(0, 10) !== date
  )
    throw new Error("Choose valid dates.");
  return value;
}
export function addDays(date: string, amount: number) {
  return new Date(dateMillis(date) + amount * 86400000)
    .toISOString()
    .slice(0, 10);
}
export function datesBetween(from: string, to: string) {
  const length = Math.round((dateMillis(to) - dateMillis(from)) / 86400000) + 1;
  if (length < 1) throw new Error("The end date must follow the start date.");
  if (length > 366) throw new Error("Choose a range of up to 366 days.");
  return Array.from({ length }, (_, i) => addDays(from, i));
}
export function weekStart(date: string) {
  const weekday = new Date(dateMillis(date)).getUTCDay();
  return addDays(date, -((weekday + 6) % 7));
}
export function monthRange(date: string, offset = 0): [string, string] {
  const value = new Date(dateMillis(date));
  value.setUTCDate(1);
  value.setUTCMonth(value.getUTCMonth() + offset);
  const first = value.toISOString().slice(0, 10);
  value.setUTCMonth(value.getUTCMonth() + 1);
  return [first, addDays(value.toISOString().slice(0, 10), -1)];
}
export function calendarDates(date: string) {
  const first = weekStart(monthRange(date)[0]);
  return Array.from({ length: 42 }, (_, i) => addDays(first, i));
}
export function historyItems(records: Row[]): HistoryItem[] {
  const items = records
    .filter((r) => r.entity === "item" && !r.deleted)
    .sort((a, b) => (a.data.order ?? 0) - (b.data.order ?? 0));
  const found = new Map(
    items.map((r) => [
      r.id,
      {
        id: r.id,
        name: r.data.name,
        color: r.data.color,
        archived: !!r.data.archived,
      },
    ]),
  );
  const entries = records
    .filter((r) => r.entity === "entry" && !r.deleted)
    .sort(
      (a, b) => Date.parse(b.data.occurred_at) - Date.parse(a.data.occurred_at),
    );
  for (const row of entries) {
    if (!found.has(row.data.item_id))
      found.set(row.data.item_id, {
        id: row.data.item_id,
        name: row.data.item_name,
        color: row.data.color,
        archived: true,
      });
  }
  return [...found.values()];
}
export function historyDays(
  records: Row[],
  settings: Settings,
  from: string,
  to: string,
  itemId = "",
): HistoryDay[] {
  const days = new Map(
    datesBetween(from, to).map((date) => [
      date,
      {
        date,
        entries: [] as Row[],
        allEntries: [] as Row[],
        state: "unlogged" as HistoryDay["state"],
        note: "",
      },
    ]),
  );
  for (const row of records) {
    if (row.deleted) continue;
    if (row.entity === "day") {
      const day = days.get(row.data.date);
      if (day) {
        day.note = row.data.note ?? "";
        if (row.data.zero) day.state = "zero";
      }
    } else if (row.entity === "entry") {
      const day = days.get(
        dayKey(row.data.occurred_at, settings.timezone, settings.day_start),
      );
      if (day) {
        day.allEntries.push(row);
        if (!itemId || row.data.item_id === itemId) day.entries.push(row);
      }
    }
  }
  for (const day of days.values()) {
    if (day.allEntries.length) day.state = "recorded";
    day.entries.sort(
      (a, b) => Date.parse(a.data.occurred_at) - Date.parse(b.data.occurred_at),
    );
  }
  return [...days.values()];
}
export function quantityTotals(entries: Row[]) {
  const totals = new Map<string, number>();
  for (const row of entries)
    totals.set(
      row.data.unit,
      (totals.get(row.data.unit) ?? 0) + Number(row.data.quantity),
    );
  return [...totals].map(([unit, quantity]) => ({
    unit,
    quantity: Number(quantity.toPrecision(12)),
  }));
}
export function historySummary(days: HistoryDay[]) {
  const times = days
    .flatMap((day) => day.entries.map((e) => Date.parse(e.data.occurred_at)))
    .sort((a, b) => a - b);
  const gaps = times
    .slice(1)
    .map((time, i) => time - times[i])
    .sort((a, b) => a - b);
  const middle = Math.floor(gaps.length / 2);
  return {
    entries: times.length,
    daysUsed: days.filter((d) => d.entries.length).length,
    medianInterval: gaps.length
      ? gaps.length % 2
        ? gaps[middle]
        : (gaps[middle - 1] + gaps[middle]) / 2
      : null,
  };
}
export function timePosition(timestamp: string, settings: Settings) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en", {
      timeZone: settings.timezone,
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
      hourCycle: "h23",
    })
      .formatToParts(new Date(timestamp))
      .map((p) => [p.type, p.value]),
  );
  const seconds =
    Number(parts.hour) * 3600 +
    Number(parts.minute) * 60 +
    Number(parts.second);
  return ((seconds - settings.day_start * 3600 + 86400) % 86400) / 86400;
}
