import { it, expect } from "vitest";
import { render } from "svelte/server";
import History from "./History.svelte";
import type { Row } from "./core";

const records: Row[] = [
  {
    id: "item",
    entity: "item",
    version: 0,
    deleted: false,
    data: {
      name: "Example",
      color: "#b49aef",
      unit: "tablet",
      order: 0,
      archived: false,
    },
  },
  {
    id: "day",
    entity: "day",
    version: 0,
    deleted: false,
    data: {
      date: "2026-10-30",
      note: "Day note first line\nDay note second line",
      zero: false,
    },
  },
  {
    id: "entry",
    entity: "entry",
    version: 0,
    deleted: false,
    data: {
      item_id: "item",
      item_name: "Example",
      color: "#b49aef",
      occurred_at: "2026-10-30T12:00:00Z",
      quantity: "1",
      unit: "tablet",
      note: "Entry note first line\nEntry note second line",
    },
  },
];
function history(rows: Row[]) {
  return render(History, {
    props: {
      records: rows,
      profile: {
        id: "account",
        username: "sample",
        settings: { timezone: "UTC", day_start: 0 },
      },
      today: "2026-10-30",
      onentry: () => {},
      onday: () => {},
    },
  }).body;
}
it("shows the full daily and entry notes directly in History", () => {
  const html = history(records);
  expect(html).toContain("Day note first line\nDay note second line");
  expect(html).toContain("Entry note first line\nEntry note second line");
  expect(html).not.toContain("Note added");
});
it("treats notes as text and excludes deleted notes", () => {
  const html = history([
    {
      ...records[1],
      data: { ...records[1].data, note: "<script>alert('example')</script>" },
    },
    { ...records[2], deleted: true },
  ]);
  expect(html).toContain("&lt;script>");
  expect(html).not.toContain("<script>");
  expect(html).not.toContain("Entry note first line");
});
