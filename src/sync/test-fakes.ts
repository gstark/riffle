// In-memory Gmail and archive for tests.

import { rawKey, type Label, type MessageMeta, type SyncState } from "../shared/storage.ts";
import type { Archive } from "./archive.ts";
import type { GmailReader, HistoryPage, RawMessage } from "./gmail.ts";

export const INBOX: Label = { id: "INBOX", name: "INBOX", type: "system" };

export function message(id: string, labelIds = ["INBOX"]): RawMessage {
  return {
    id,
    threadId: `t-${id}`,
    labelIds,
    internalDate: String(Date.UTC(2024, 2, 9)),
    historyId: "500",
    sizeEstimate: 123,
    raw: Buffer.from(`Subject: ${id}\r\n\r\nbody`).toString("base64url"),
  };
}

export function meta(id: string, labelIds = ["INBOX"]): MessageMeta {
  return {
    id,
    threadId: `t-${id}`,
    labelIds,
    internalDate: "2024-03-09T00:00:00.000Z",
    historyId: "1",
    sizeEstimate: 123,
    rawKey: rawKey(id, new Date("2024-03-09T00:00:00.000Z")),
    deletedAt: null,
    updatedAt: "2024-03-09T00:00:00.000Z",
  };
}

interface FakeGmailOptions {
  messages?: RawMessage[];
  /** Pages of listMessageIds. Defaults to one page with every message. */
  listPages?: string[][];
  history?: HistoryPage[];
  historyId?: string;
  labels?: Label[];
  failIds?: string[];
}

export function fakeGmail({
  messages = [],
  listPages = [messages.map((m) => m.id)],
  history = [],
  historyId = "100",
  labels = [INBOX],
  failIds = [],
}: FakeGmailOptions = {}): GmailReader {
  const byId = new Map(messages.map((m) => [m.id, m]));
  const find = (id: string) => {
    if (failIds.includes(id)) throw new Error("boom");
    return byId.get(id) ?? null;
  };

  return {
    getHistoryId: async () => historyId,
    listLabels: async () => labels,
    async *listMessageIds() {
      yield* listPages;
    },
    async *listHistory() {
      yield* history;
    },
    getRawMessage: async (id) => find(id),
    getMessageLabels: async (id) => {
      const m = find(id);
      return m && { labelIds: m.labelIds ?? [], historyId: m.historyId };
    },
  };
}

export function fakeArchive({ metas = [] as MessageMeta[], state = null as SyncState | null, labels = null as Label[] | null } = {}) {
  const raw = new Map<string, string>();
  const meta = new Map(metas.map((m) => [m.id, m]));
  const saved = { state, labels, metaWrites: 0, labelWrites: 0 };

  const archive: Archive = {
    listMessageIds: async () => new Set(meta.keys()),
    putMessage: async (body, m) => {
      raw.set(m.rawKey, body.toString());
      meta.set(m.id, m);
    },
    getMeta: async (id) => meta.get(id) ?? null,
    putMeta: async (m) => {
      meta.set(m.id, m);
      saved.metaWrites++;
    },
    getSyncState: async () => saved.state,
    putSyncState: async (s) => {
      saved.state = s;
    },
    getLabels: async () => saved.labels,
    putLabels: async (l) => {
      saved.labels = l;
      saved.labelWrites++;
    },
  };
  return { archive, raw, meta, saved };
}
