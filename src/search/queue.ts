// SQS queues of message IDs: the index queue and the receipts queue. S3 sends an event for each meta/ write
// to the index queue. The full build, the indexer, and the receipts backfill send lists of IDs.

import {
  DeleteMessageBatchCommand,
  ReceiveMessageCommand,
  SendMessageBatchCommand,
  type SQSClient,
} from "@aws-sdk/client-sqs";
import { z } from "zod";
import { gmailIdFromMetaKey } from "../shared/storage.ts";

export interface QueueMessage {
  receiptHandle: string;
  ids: string[];
}

export interface Queue {
  /** Receives messages until they hold at least `maxIds` IDs or the queue has no more. */
  receive(maxIds: number): Promise<QueueMessage[]>;
  delete(receiptHandles: string[]): Promise<void>;
}

/** IDs per message that the full build sends. */
const IDS_PER_MESSAGE = 100;
/** The SQS maximum for batch calls. */
const SQS_BATCH = 10;

const S3EventSchema = z.object({
  Records: z.array(z.object({ s3: z.object({ object: z.object({ key: z.string() }) }) })),
});
const IdListSchema = z.object({ ids: z.array(z.string()) });

/** Message IDs in one queue message body. Other bodies, such as the S3 test event, have none. */
export function idsFromBody(body: string): string[] {
  const json: unknown = JSON.parse(body);
  const event = S3EventSchema.safeParse(json);
  if (event.success) {
    return event.data.Records.flatMap(({ s3 }) => {
      // S3 event keys are URL-encoded, with "+" for spaces.
      const id = gmailIdFromMetaKey(decodeURIComponent(s3.object.key.replaceAll("+", " ")));
      return id ? [id] : [];
    });
  }
  const list = IdListSchema.safeParse(json);
  return list.success ? list.data.ids : [];
}

const chunk = <T>(items: T[], size: number): T[][] =>
  Array.from({ length: Math.ceil(items.length / size) }, (_, i) => items.slice(i * size, (i + 1) * size));

export function createSqsQueue(sqs: SQSClient, url: string): Queue {
  return {
    async receive(maxIds) {
      const messages: QueueMessage[] = [];
      let idCount = 0;
      while (idCount < maxIds) {
        // Wait briefly for the first messages. After that, take only what is already there.
        const { Messages = [] } = await sqs.send(
          new ReceiveMessageCommand({
            QueueUrl: url,
            // Messages hold up to IDS_PER_MESSAGE IDs: do not ask for more than can fit.
            MaxNumberOfMessages: Math.min(SQS_BATCH, Math.max(1, Math.ceil((maxIds - idCount) / IDS_PER_MESSAGE))),
            WaitTimeSeconds: messages.length === 0 ? 1 : 0,
          }),
        );
        if (Messages.length === 0) break;
        for (const message of Messages) {
          if (!message.ReceiptHandle) continue;
          const ids = idsFromBody(message.Body ?? "{}");
          messages.push({ receiptHandle: message.ReceiptHandle, ids });
          idCount += ids.length;
        }
      }
      return messages;
    },

    async delete(receiptHandles) {
      for (const handles of chunk(receiptHandles, SQS_BATCH)) {
        const result = await sqs.send(
          new DeleteMessageBatchCommand({
            QueueUrl: url,
            Entries: handles.map((handle, n) => ({ Id: String(n), ReceiptHandle: handle })),
          }),
        );
        if (result.Failed?.length) throw new Error(`Could not delete ${result.Failed.length} queue messages`);
      }
    },
  };
}

/** Sends IDs to the queue in the full build format. */
export async function sendIds(sqs: SQSClient, url: string, ids: string[]): Promise<void> {
  const bodies = chunk(ids, IDS_PER_MESSAGE).map((part) => JSON.stringify({ ids: part }));
  for (const entries of chunk(bodies, SQS_BATCH)) {
    const result = await sqs.send(
      new SendMessageBatchCommand({
        QueueUrl: url,
        Entries: entries.map((body, n) => ({ Id: String(n), MessageBody: body })),
      }),
    );
    if (result.Failed?.length) throw new Error(`Could not queue ${result.Failed.length} messages`);
  }
}

/** Default IDs per batch that drainQueue gives to `handle`. */
const BATCH_IDS = 500;

export interface DrainOptions<R extends { failedIds: Set<string> }> {
  queue: Queue;
  /** Processes the IDs of one batch. Queue messages with an ID in `failedIds` come back later. */
  handle: (ids: string[]) => Promise<R>;
  /** One log line about the result of a batch. */
  describe: (result: R) => string;
  /** IDs per batch. */
  batchIds?: number;
  /** Stop receiving after this time, in epoch milliseconds. */
  deadline: number;
  now: () => number;
  log: (message: string) => void;
}

/**
 * Handles queue batches until the queue is empty or the deadline passes.
 * A queue message is deleted only when all of its IDs succeeded. The others come back after the visibility timeout.
 */
export async function drainQueue<R extends { failedIds: Set<string> }>({
  queue,
  handle,
  describe,
  batchIds = BATCH_IDS,
  deadline,
  now,
  log,
}: DrainOptions<R>): Promise<{ drained: boolean }> {
  while (now() < deadline) {
    const messages = await queue.receive(batchIds);
    if (messages.length === 0) return { drained: true };

    const result = await handle(messages.flatMap((message) => message.ids));
    const finished = messages.filter((message) => message.ids.every((id) => !result.failedIds.has(id)));
    await queue.delete(finished.map((message) => message.receiptHandle));
    log(`${describe(result)} (${finished.length} of ${messages.length} queue messages done)`);
  }
  return { drained: false };
}
