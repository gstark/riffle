import type { JWT } from "google-auth-library";
import type { Label } from "../shared/storage.ts";

const BASE_URL = "https://gmail.googleapis.com/gmail/v1/users/me";

// Gmail reports rate limits as 403 or 429.
const RETRY = {
  retry: 6,
  statusCodesToRetry: [
    [403, 403],
    [429, 429],
    [500, 599],
  ],
};

export interface RawMessage {
  id: string;
  threadId: string;
  labelIds?: string[];
  /** Milliseconds since the epoch, as a string. */
  internalDate: string;
  historyId: string;
  sizeEstimate: number;
  /** Base64url-encoded RFC 822 message. */
  raw: string;
}

export interface MessageLabels {
  labelIds: string[];
  historyId: string;
}

interface HistoryMessage {
  message: { id: string };
}

/** One record of users.history.list. Only the fields the sync uses. */
export interface HistoryRecord {
  messagesAdded?: HistoryMessage[];
  messagesDeleted?: HistoryMessage[];
  labelsAdded?: HistoryMessage[];
  labelsRemoved?: HistoryMessage[];
}

export interface HistoryPage {
  records: HistoryRecord[];
  /** The mailbox's current history ID. */
  historyId: string;
}

/** Gmail no longer has history records that start at the requested history ID. */
export class HistoryExpiredError extends Error {
  constructor(startHistoryId: string) {
    super(`Gmail history from ${startHistoryId} has expired. A full reconcile is necessary.`);
  }
}

export interface GmailReader {
  getHistoryId(): Promise<string>;
  /** Labels sorted by ID. */
  listLabels(): Promise<Label[]>;
  /** Yields message IDs one page at a time. Trash is included, spam is not. */
  listMessageIds(): AsyncIterable<string[]>;
  /** Yields the changes after `startHistoryId`, oldest first. */
  listHistory(startHistoryId: string): AsyncIterable<HistoryPage>;
  /** Returns null when the message no longer exists. */
  getRawMessage(id: string): Promise<RawMessage | null>;
  /** Returns null when the message no longer exists. */
  getMessageLabels(id: string): Promise<MessageLabels | null>;
}

export function createGmailReader(client: JWT): GmailReader {
  const get = async <T>(path: string, params?: Record<string, string>): Promise<T> => {
    const { data } = await client.request<T>({
      url: `${BASE_URL}${path}`,
      params,
      retryConfig: RETRY,
    });
    return data;
  };

  const getOrNull = async <T>(path: string, params?: Record<string, string>): Promise<T | null> => {
    try {
      return await get<T>(path, params);
    } catch (error) {
      if (httpStatus(error) === 404) return null;
      throw error;
    }
  };

  return {
    async getHistoryId() {
      return (await get<{ historyId: string }>("/profile")).historyId;
    },

    async listLabels() {
      const { labels = [] } = await get<{ labels?: Label[] }>("/labels");
      return labels
        .map(({ id, name, type }) => ({ id, name, type }))
        .toSorted((a, b) => a.id.localeCompare(b.id));
    },

    async *listMessageIds() {
      let pageToken: string | undefined;
      do {
        const page = await get<{ messages?: { id: string }[]; nextPageToken?: string }>(
          "/messages",
          {
            maxResults: "500",
            includeSpamTrash: "true",
            q: "-in:spam",
            ...(pageToken && { pageToken }),
          },
        );
        yield (page.messages ?? []).map((m) => m.id);
        pageToken = page.nextPageToken;
      } while (pageToken);
    },

    async *listHistory(startHistoryId) {
      let pageToken: string | undefined;
      do {
        const page = await getOrNull<{
          history?: HistoryRecord[];
          historyId: string;
          nextPageToken?: string;
        }>("/history", {
          startHistoryId,
          maxResults: "500",
          ...(pageToken && { pageToken }),
        });
        if (!page) throw new HistoryExpiredError(startHistoryId);
        yield { records: page.history ?? [], historyId: page.historyId };
        pageToken = page.nextPageToken;
      } while (pageToken);
    },

    getRawMessage(id) {
      return getOrNull<RawMessage>(`/messages/${id}`, { format: "raw" });
    },

    async getMessageLabels(id) {
      const message = await getOrNull<{ labelIds?: string[]; historyId: string }>(`/messages/${id}`, {
        format: "minimal",
      });
      return message && { labelIds: message.labelIds ?? [], historyId: message.historyId };
    },
  };
}

// Reads the status field directly. google-auth-library uses the CommonJS build of gaxios,
// so its GaxiosError is a different class from the one an ESM import would give.
function httpStatus(error: unknown): unknown {
  return typeof error === "object" && error !== null && "status" in error ? error.status : undefined;
}
