// Builds the LanceDB filter for a search. The values come from Claude's reading of the user's text,
// so this code escapes every value. The model never writes the condition.

export interface SearchFilter {
  /** Parts of sender names or addresses. A message matches any one of them. */
  from: string[];
  /** Parts of recipient names or addresses. A message matches any one of them. */
  to: string[];
  /** First day to include, YYYY-MM-DD in the configured time zone. */
  after: string | null;
  /** First day to leave out, YYYY-MM-DD in the configured time zone. */
  before: string | null;
  /** Gmail label IDs that a message must all have. */
  labelIds: string[];
  includeSpamTrash: boolean;
  hasAttachment: boolean | null;
}

/** A SQL string literal. Single quotes are doubled. */
export const sqlString = (value: string) => `'${value.replaceAll("'", "''")}'`;

const sqlList = (values: string[]) => `[${values.map(sqlString).join(", ")}]`;

const sqlTimestamp = (date: Date) => `timestamp '${date.toISOString().slice(0, 19).replace("T", " ")}'`;

function containsAny(column: string, terms: string[]): string | null {
  const clean = terms.map((term) => term.trim().toLowerCase()).filter((term) => term !== "");
  if (clean.length === 0) return null;
  return `(${clean.map((term) => `contains(${column}, ${sqlString(term)})`).join(" OR ")})`;
}

/** How far `timeZone` is ahead of UTC at `instant`, in milliseconds. */
function offsetMs(instant: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
  }).formatToParts(instant);
  const part = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const local = Date.UTC(part("year"), part("month") - 1, part("day"), part("hour"), part("minute"), part("second"));
  return local - (instant - (instant % 1000));
}

/** The UTC time of midnight at the start of `day` (YYYY-MM-DD) in `timeZone`. */
export function startOfDay(day: string, timeZone: string): Date {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!match) throw new Error(`Not a date: ${day}`);
  const midnightAsUtc = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  // The offset at UTC midnight gives a first guess. The second pass corrects it on daylight saving days.
  const guess = midnightAsUtc - offsetMs(midnightAsUtc, timeZone);
  return new Date(midnightAsUtc - offsetMs(guess, timeZone));
}

export function buildWhere(filter: SearchFilter, timeZone: string): string {
  const conditions = [
    "deleted = false",
    filter.includeSpamTrash ? null : "NOT array_has_any(labels, ['SPAM', 'TRASH'])",
    filter.labelIds.length > 0 ? `array_has_all(labels, ${sqlList(filter.labelIds)})` : null,
    containsAny("fromKey", filter.from),
    containsAny("toKey", filter.to),
    filter.after ? `date >= ${sqlTimestamp(startOfDay(filter.after, timeZone))}` : null,
    filter.before ? `date < ${sqlTimestamp(startOfDay(filter.before, timeZone))}` : null,
    filter.hasAttachment === null ? null : `hasAttachment = ${filter.hasAttachment}`,
  ];
  return conditions.filter((condition) => condition !== null).join(" AND ");
}
