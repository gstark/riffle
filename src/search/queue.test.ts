import { describe, expect, it } from "vitest";
import { idsFromBody } from "./queue.ts";

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
