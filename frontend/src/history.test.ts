import { describe, it, expect } from "vitest";
import type { Row } from "./core";
import {
  addDays,
  datesBetween,
  weekStart,
  monthRange,
  calendarDates,
  historyDays,
  historyItems,
  quantityTotals,
  historySummary,
  timePosition,
} from "./history";

const settings = { timezone: "America/New_York", day_start: 4 };
function entry(
  id: string,
  occurred_at: string,
  quantity = "1",
  unit = "tablet",
  item_id = "a",
): Row {
  return {
    id,
    entity: "entry",
    version: 0,
    deleted: false,
    data: {
      item_id,
      item_name: `Item ${item_id}`,
      color: "#b594ed",
      quantity,
      unit,
      occurred_at,
      note: "a note",
    },
  };
}
const day = (date: string, zero = true): Row => ({
  id: date,
  entity: "day",
  version: 0,
  deleted: false,
  data: { date, zero, note: "daily note" },
});

describe("calendar periods", () => {
  it("navigates weeks and months across year and leap-day boundaries", () => {
    expect(weekStart("2027-01-01")).toBe("2026-12-28");
    expect(addDays("2024-02-28", 1)).toBe("2024-02-29");
    expect(monthRange("2026-12-30", 1)).toEqual(["2027-01-01", "2027-01-31"]);
    expect(monthRange("2024-03-31", -1)).toEqual(["2024-02-01", "2024-02-29"]);
    const grid = calendarDates("2026-10-30");
    expect(grid).toHaveLength(42);
    expect(grid[0]).toBe("2026-09-28");
    expect(grid.at(-1)).toBe("2026-11-08");
  });
  it("validates inclusive ranges and bounds work on a device", () => {
    expect(datesBetween("2026-10-29", "2026-10-30")).toEqual([
      "2026-10-29",
      "2026-10-30",
    ]);
    expect(() => datesBetween("2026-10-30", "2026-10-29")).toThrow();
    expect(() => datesBetween("2026-02-30", "2026-03-01")).toThrow();
    expect(() => datesBetween("2020-01-01", "2026-01-01")).toThrow();
  });
});

describe("local history", () => {
  it("groups pending entries by configured day, excludes deletions, and keeps notes", () => {
    const deleted = {
      ...entry("deleted", "2026-10-30T13:00:00Z"),
      deleted: true,
    };
    const rows = [
      entry("before", "2026-10-30T07:59:59Z"),
      entry("after", "2026-10-30T08:00:00Z"),
      deleted,
      day("2026-10-29", false),
    ];
    const result = historyDays(rows, settings, "2026-10-29", "2026-10-30");
    expect(result[0].entries.map((e) => e.id)).toEqual(["before"]);
    expect(result[0].note).toBe("daily note");
    expect(result[1].entries.map((e) => e.id)).toEqual(["after"]);
  });
  it("never turns missing or filtered-out logs into confirmed zero days", () => {
    const rows = [
      day("2026-10-27"),
      entry("other", "2026-10-28T15:00:00Z", "1", "glass", "b"),
      day("2026-10-28"),
    ];
    const result = historyDays(rows, settings, "2026-10-27", "2026-10-29", "a");
    expect(result.map((d) => d.state)).toEqual([
      "zero",
      "recorded",
      "unlogged",
    ]);
    expect(result[1].entries).toHaveLength(0);
    expect(result[1].allEntries).toHaveLength(1);
  });
  it("keeps archived and orphan historical medicines available under stable IDs", () => {
    const item: Row = {
      id: "a",
      entity: "item",
      version: 1,
      deleted: false,
      data: { name: "Renamed", color: "#123abc", archived: true, order: 0 },
    };
    expect(
      historyItems([
        item,
        entry("a1", "2026-01-01T12:00Z"),
        entry("b1", "2026-01-01T13:00Z", "1", "mg", "b"),
      ]),
    ).toEqual([
      { id: "a", name: "Renamed", color: "#123abc", archived: true },
      { id: "b", name: "Item b", color: "#b594ed", archived: true },
    ]);
  });
  it("keeps historical units separate and avoids floating-point display noise", () => {
    expect(
      quantityTotals([
        entry("a", "2026-01-01T12:00Z", "0.1"),
        entry("b", "2026-01-01T13:00Z", "0.2"),
        entry("c", "2026-01-01T14:00Z", "5", "mg"),
      ]),
    ).toEqual([
      { unit: "tablet", quantity: 0.3 },
      { unit: "mg", quantity: 5 },
    ]);
  });
  it("measures frequency from recorded entries, not assumed missing-day zeros", () => {
    const days = historyDays(
      [
        entry("a", "2026-10-28T12:00Z"),
        entry("b", "2026-10-28T14:00Z"),
        entry("c", "2026-10-30T12:00Z"),
      ],
      settings,
      "2026-10-27",
      "2026-10-30",
    );
    expect(historySummary(days)).toEqual({
      entries: 3,
      daysUsed: 2,
      medianInterval: 24 * 60 * 60 * 1000,
    });
    expect(
      historySummary(historyDays([], settings, "2026-10-30", "2026-10-30"))
        .medianInterval,
    ).toBeNull();
  });
  it("retains distinct fall-back instants and plots exact wall-clock positions", () => {
    const early = entry("early", "2026-11-01T01:30:00-04:00");
    const late = entry("late", "2026-11-01T01:30:00-05:00");
    const days = historyDays(
      [late, early],
      settings,
      "2026-10-31",
      "2026-10-31",
    );
    expect(days[0].entries.map((e) => e.id)).toEqual(["early", "late"]);
    expect(historySummary(days).medianInterval).toBe(3600000);
    expect(timePosition(early.data.occurred_at, settings)).toBeCloseTo(
      21.5 / 24,
    );
    expect(timePosition(late.data.occurred_at, settings)).toBeCloseTo(
      21.5 / 24,
    );
    expect(timePosition("2026-10-30T04:00:30-04:00", settings)).toBeCloseTo(
      30 / 86400,
    );
  });
});
