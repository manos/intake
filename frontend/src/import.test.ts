import { it, expect } from "vitest";
import { previewImport } from "./import";
const id = "c7149fd8-c42d-45b1-91ce-c78686d221e1";
it("round trips decimal strings in backups", () => {
  const p = previewImport(
    JSON.stringify({
      items: [
        {
          id,
          name: "Personal item",
          unit: "unit",
          color: "#123456",
          amount: "0.125",
          presets: ["0.25"],
          archived: false,
          order: 0,
        },
      ],
      entries: [],
      days: [],
    }),
    "backup.json",
  );
  expect(p.errors).toEqual([]);
});
it("maps CSV identity separately and supplies optional note", () => {
  const p = previewImport(
    `id,item_id,item_name,quantity,unit,occurred_at,timezone,color\n${id},${id},Personal item,1,unit,2026-10-30T12:00:00Z,UTC,#123456`,
    "entries.csv",
  );
  expect(p.errors).toEqual([]);
  expect(p.rows[0].data).not.toHaveProperty("id");
  expect(p.rows[0].data.note).toBe("");
});
it("rejects ambiguous dates and malformed identity", () => {
  expect(
    previewImport(
      JSON.stringify({ items: [], entries: [{ id: "wrong" }], days: [] }),
      "a.json",
    ).errors.length,
  ).toBe(1);
});
it("rejects ambiguous duplicate day records", () => {
  const d = { date: "2026-10-30", note: "", zero: false };
  const p = previewImport(
    JSON.stringify({ items: [], entries: [], days: [d, d] }),
    "days.json",
  );
  expect(p.errors.length).toBe(1);
});
