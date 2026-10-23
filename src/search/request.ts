// The body of POST /search: text for Claude to read, or exact filters that skip Claude.

import { z } from "zod";
import type { Label } from "../shared/storage.ts";
import { searchableLabels, type ParsedQuery } from "./parse-query.ts";

/** A request that is valid JSON but asks for something that does not exist. The API returns 400. */
export class BadRequestError extends Error {
  override name = "BadRequestError";
}

const term = z.string().trim().min(1).max(200);
const terms = z.array(term).max(10);

export const FiltersSchema = z
  .strictObject({
    text: z.string().trim().max(500),
    from: terms,
    to: terms,
    after: z.iso.date().nullable(),
    before: z.iso.date().nullable(),
    /** Label names, as the search response gives them. */
    labels: terms,
    includeSpamTrash: z.boolean(),
    hasAttachment: z.boolean().nullable(),
    sort: z.enum(["relevance", "newest", "oldest"]),
  })
  .refine((filters) => filters.after === null || filters.before === null || filters.after < filters.before, {
    message: "after must be earlier than before",
    path: ["before"],
  });

export type Filters = z.infer<typeof FiltersSchema>;

const limit = z.number().int().min(1).max(50).default(20);

export const SearchBodySchema = z.union([
  z.strictObject({ q: z.string().trim().min(1).max(500), limit }),
  z.strictObject({ filters: FiltersSchema, limit }),
]);

export type SearchInput = { q: string } | { filters: Filters };

/** The filters as a query, with label IDs for the filter condition. */
export function exactQuery(filters: Filters, labels: Label[]): ParsedQuery {
  const idByName = new Map(searchableLabels(labels).map((label) => [label.name, label.id]));
  const unknown = filters.labels.find((name) => !idByName.has(name));
  if (unknown !== undefined) throw new BadRequestError(`Unknown label: ${unknown}`);
  return { ...filters, labelIds: filters.labels.flatMap((name) => idByName.get(name) ?? []), source: "filters" };
}
