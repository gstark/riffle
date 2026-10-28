import type { ReceiveMessageCommand, SQSClient } from "@aws-sdk/client-sqs";
import { describe, expect, it } from "vitest";
import { createSqsQueue, drainQueue, idsFromBody, type Queue, type QueueMessage } from "./queue.ts";

describe("idsFromBody", () => {
  it("reads the message IDs of meta keys in an S3 event", () => {
    const body = JSON.stringify({
      Records: [
        { eventName: "ObjectCreated:Put", s3: { object: { key: "meta/18c2f.json" } } },
        { eventName: "ObjectCreated:Put", s3: { object: { key: "raw/2024/03/18c2f.eml" } } },
      ],
    });

    expect(idsFromBody(body)).toEqual(["18c2f"]);
  });

  it("decodes URL-encoded keys", () => {
    const body = JSON.stringify({ Records: [{ s3: { object: { key: "meta/a%3Db.json" } } }] });

    expect(idsFromBody(body)).toEqual(["a=b"]);
  });

  it("reads the ID list that the full build sends", () => {
    expect(idsFromBody('{"ids":["a","b"]}')).toEqual(["a", "b"]);
  });

  it("returns no IDs for the S3 test event", () => {
    expect(idsFromBody('{"Service":"Amazon S3","Event":"s3:TestEvent"}')).toEqual([]);
  });
});

describe("createSqsQueue", () => {
  it("asks for no more messages than can fit the ID limit", async () => {
    const batch = (count: number) => ({
      Messages: Array.from({ length: count }, (_, n) => ({
        ReceiptHandle: `h${n}`,
        Body: JSON.stringify({ ids: Array.from({ length: 100 }, (_, i) => `${n}-${i}`) }),
      })),
    });
    const responses = [batch(3), batch(0)];
    const asked: (number | undefined)[] = [];
    const sqs = {
      send: async (command: ReceiveMessageCommand) => {
        asked.push(command.input.MaxNumberOfMessages);
        return responses.shift() ?? {};
      },
    } as unknown as SQSClient;

    const messages = await createSqsQueue(sqs, "url").receive(500);

    expect(asked).toEqual([5, 2]);
    expect(messages).toHaveLength(3);
  });
});

function fakeQueue(batches: QueueMessage[][]) {
  const deleted: string[] = [];
  const requested: number[] = [];
  const queue: Queue = {
    receive: async (maxIds) => {
      requested.push(maxIds);
      return batches.shift() ?? [];
    },
    delete: async (handles) => {
      deleted.push(...handles);
    },
  };
  return { queue, deleted, requested };
}

const done = (failed: string[] = []) => ({ failedIds: new Set(failed) });

describe("drainQueue", () => {
  it("handles batches until the queue is empty, and deletes only the messages that fully succeeded", async () => {
    const { queue, deleted } = fakeQueue([
      [
        { receiptHandle: "h1", ids: ["a", "b"] },
        { receiptHandle: "h2", ids: ["c"] },
      ],
      [{ receiptHandle: "h3", ids: ["d"] }],
    ]);
    const seen: string[][] = [];
    const logged: string[] = [];

    const result = await drainQueue({
      queue,
      handle: async (ids) => {
        seen.push(ids);
        return done(ids.includes("c") ? ["c"] : []);
      },
      describe: (batch) => `${batch.failedIds.size} failed`,
      deadline: Infinity,
      now: () => 0,
      log: (message) => logged.push(message),
    });

    expect(result).toEqual({ drained: true });
    expect(seen).toEqual([["a", "b", "c"], ["d"]]);
    expect(deleted).toEqual(["h1", "h3"]);
    expect(logged).toEqual(["1 failed (1 of 2 queue messages done)", "0 failed (1 of 1 queue messages done)"]);
  });

  it("receives the batch size from the option, 500 by default", async () => {
    const options = { handle: async () => done(), describe: () => "", deadline: Infinity, now: () => 0, log: () => {} };
    const custom = fakeQueue([]);
    const standard = fakeQueue([]);

    await drainQueue({ ...options, queue: custom.queue, batchIds: 200 });
    await drainQueue({ ...options, queue: standard.queue });

    expect(custom.requested).toEqual([200]);
    expect(standard.requested).toEqual([500]);
  });

  it("stops at the deadline", async () => {
    let time = 0;
    const { queue } = fakeQueue([[{ receiptHandle: "h1", ids: ["a"] }], [{ receiptHandle: "h2", ids: ["b"] }]]);

    const result = await drainQueue({
      queue,
      handle: async () => {
        time += 10;
        return done();
      },
      describe: () => "",
      deadline: 5,
      now: () => time,
      log: () => {},
    });

    expect(result).toEqual({ drained: false });
  });
});
