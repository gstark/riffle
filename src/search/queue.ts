// The index queue. S3 sends an event for each meta/ write. The full build sends lists of IDs.

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
            MaxNumberOfMessages: SQS_BATCH,
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
