import { it, expect } from "vitest";
import { entryTimestamp, localTimeOptions } from "./core";

it("preserves seconds and the second DST occurrence on note-only edits", () => {
  const original = "2026-11-01T01:30:45-05:00";
  expect(entryTimestamp("2026-11-01T01:30", "America/New_York", original)).toBe(
    original,
  );
  expect(
    entryTimestamp(
      "2026-10-30T08:00",
      "America/New_York",
      "2026-10-30T12:00:38Z",
    ),
  ).toBe("2026-10-30T12:00:38Z");
});
it("requires an explicit offset for an edited repeated wall time", () => {
  const choices = localTimeOptions("2026-11-01T01:30", "America/New_York");
  expect(choices.map((c) => c.timestamp)).toEqual([
    "2026-11-01T05:30:00.000Z",
    "2026-11-01T06:30:00.000Z",
  ]);
  expect(choices.map((c) => c.offset)).toEqual(["UTC-04:00", "UTC-05:00"]);
  expect(() => entryTimestamp("2026-11-01T01:30", "America/New_York")).toThrow(
    "offset",
  );
  expect(
    entryTimestamp(
      "2026-11-01T01:30",
      "America/New_York",
      undefined,
      choices[1].timestamp,
    ),
  ).toBe(choices[1].timestamp);
});
it("rejects nonexistent spring-forward times instead of moving an entry", () => {
  expect(localTimeOptions("2026-03-08T02:30", "America/New_York")).toEqual([]);
  expect(() => entryTimestamp("2026-03-08T02:30", "America/New_York")).toThrow(
    "does not exist",
  );
});
it("supports ordinary edits and fractional-hour timezone transitions", () => {
  expect(
    entryTimestamp(
      "2026-10-30T08:01",
      "America/New_York",
      "2026-10-30T12:00:45Z",
    ),
  ).toBe("2026-10-30T12:01:00.000Z");
  const choices = localTimeOptions("2026-04-05T01:45", "Australia/Lord_Howe");
  expect(choices.map((c) => c.offset)).toEqual(["UTC+11:00", "UTC+10:30"]);
  expect(entryTimestamp("2026-10-30T00:00", "Asia/Kathmandu")).toBe(
    "2026-10-29T18:15:00.000Z",
  );
});
