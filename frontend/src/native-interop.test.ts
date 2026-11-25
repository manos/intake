import raw from "../../ios/Tests/IntakeKitTests/Fixtures/web.json?raw";
import { expect, it } from "vitest";
import { dayId, dayKey, snapshot } from "./core";
import { previewImport } from "./import";

it("round-trips the same exact-time journal as the native client", async () => {
  const preview = previewImport(raw, "web.json");
  expect(preview.errors).toEqual([]);
  expect(snapshot(preview.rows)).toEqual(JSON.parse(raw));
  const entry = preview.rows.find((r) => r.entity === "entry")!;
  const date = dayKey(entry.data.occurred_at, entry.data.timezone, 4);
  expect(date).toBe("2026-10-31");
  expect(await dayId(date)).toBe("dc262c92-b17d-52f1-bddc-82ee5df8071b");
});
