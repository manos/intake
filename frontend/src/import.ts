import type { Row } from "./core";
export interface Preview {
  rows: Row[];
  errors: string[];
}
function csv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let value = "",
    quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      if (quoted && text[i + 1] === '"') {
        value += '"';
        i++;
      } else quoted = !quoted;
    } else if (c === "," && !quoted) {
      row.push(value);
      value = "";
    } else if ((c === "\n" || c === "\r") && !quoted) {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(value);
      if (row.some(Boolean)) rows.push(row);
      row = [];
      value = "";
    } else value += c;
  }
  if (quoted) throw new Error("Unclosed quoted CSV field.");
  row.push(value);
  if (row.some(Boolean)) rows.push(row);
  return rows;
}
export function previewImport(text: string, filename: string): Preview {
  const rows: Row[] = [],
    errors: string[] = [];
  try {
    if (filename.toLowerCase().endsWith(".csv")) {
      const [headers, ...data] = csv(text);
      if (!headers) throw new Error("The file is empty.");
      const needed = [
        "item_id",
        "item_name",
        "quantity",
        "unit",
        "occurred_at",
        "timezone",
        "color",
      ];
      for (const name of needed)
        if (!headers.includes(name))
          throw new Error(
            `CSV needs column ${name}. Required: ${needed.join(", ")}. Optional: note, id.`,
          );
      data.forEach((values, i) => {
        const d = Object.fromEntries(
          headers.map((h, n) => [h.trim(), values[n] ?? ""]),
        );
        const { id, ...fields } = d;
        fields.note ??= "";
        validate("entry", fields, `Row ${i + 2}`);
        const recordId = id || crypto.randomUUID();
        if (!uuid(recordId))
          throw new Error(`Row ${i + 2}: invalid record ID.`);
        rows.push({
          id: recordId,
          entity: "entry",
          version: 0,
          deleted: false,
          data: fields,
        });
      });
    } else {
      const data = JSON.parse(text);
      for (const [key, entity] of [
        ["items", "item"],
        ["entries", "entry"],
        ["days", "day"],
      ] as const) {
        if (!Array.isArray(data[key]))
          throw new Error(`JSON needs a ${key} array.`);
        data[key].forEach((raw: any, i: number) => {
          const { id, ...d } = raw;
          if (id && !uuid(id))
            throw new Error(`${key} ${i + 1}: invalid record ID.`);
          validate(entity, d, `${key} ${i + 1}`);
          rows.push({
            id: id || crypto.randomUUID(),
            entity,
            version: 0,
            deleted: false,
            data: d,
          });
        });
      }
    }
  } catch (e) {
    errors.push((e as Error).message);
  }
  const identities = new Set<string>();
  const dates = new Set<string>();
  for (const row of rows) {
    const key = row.entity + row.id;
    if (identities.has(key)) errors.push("Duplicate record IDs are ambiguous.");
    identities.add(key);
    if (row.entity === "day") {
      if (dates.has(row.data.date))
        errors.push("Multiple notes for one date are ambiguous.");
      dates.add(row.data.date);
    }
  }
  return { rows, errors };
}
const uuid = (v: unknown) =>
  typeof v === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
function validate(entity: string, d: any, label: string) {
  const fail = (s: string): never => {
    throw new Error(`${label}: ${s}`);
  };
  const positive = (n: any) =>
    (typeof n === "string" || typeof n === "number") &&
    String(n).length <= 64 &&
    Number.isFinite(+n) &&
    +n > 0 &&
    +n <= 1e12;
  const string = (n: any, max: number, min = 0) =>
    typeof n === "string" && n.length >= min && n.length <= max;
  const shape: Record<string, string[]> = {
    item: ["name", "color", "unit", "amount", "presets", "archived", "order"],
    entry: [
      "item_id",
      "quantity",
      "unit",
      "item_name",
      "color",
      "occurred_at",
      "timezone",
      "note",
    ],
    day: ["date", "note", "zero"],
  };
  if (
    Object.keys(d).some((k) => !shape[entity].includes(k)) ||
    shape[entity].some((k) => !(k in d))
  )
    fail("unexpected or missing fields.");
  if (entity === "item") {
    if (
      !string(d.name, 200, 1) ||
      !string(d.unit, 64, 1) ||
      !positive(d.amount) ||
      !/^#[0-9a-f]{6}$/i.test(d.color) ||
      !Array.isArray(d.presets) ||
      d.presets.length > 30 ||
      d.presets.some((n: any) => !positive(n)) ||
      typeof d.archived !== "boolean" ||
      !Number.isInteger(d.order) ||
      Math.abs(d.order) > 1000000
    )
      fail("invalid name, unit, amount, color, presets, archive or order.");
  }
  if (entity === "entry") {
    if (
      !uuid(d.item_id) ||
      !string(d.item_name, 200, 1) ||
      !string(d.unit, 64, 1) ||
      !/^#[0-9a-f]{6}$/i.test(d.color) ||
      !positive(d.quantity) ||
      !string(d.note, 10000)
    )
      fail(
        "valid item identity, name, unit, color, note and positive quantity are required.",
      );
    if (
      !string(d.occurred_at, 64) ||
      !/T.*(?:Z|[+-]\d\d:\d\d)$/.test(d.occurred_at) ||
      Number.isNaN(Date.parse(d.occurred_at))
    )
      fail(
        "time must include an explicit UTC offset; ambiguous local dates cannot be imported.",
      );
    try {
      if (!string(d.timezone, 100, 1)) fail("invalid timezone.");
      new Intl.DateTimeFormat("en", { timeZone: d.timezone }).format();
    } catch {
      fail("invalid timezone.");
    }
  }
  if (
    entity === "day" &&
    (!/^\d{4}-\d{2}-\d{2}$/.test(d.date) ||
      Number.isNaN(Date.parse(d.date)) ||
      new Date(d.date).toISOString().slice(0, 10) !== d.date ||
      typeof d.zero !== "boolean" ||
      !string(d.note, 10000))
  )
    fail("invalid day note.");
}
