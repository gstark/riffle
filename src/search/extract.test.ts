import { describe, expect, it } from "vitest";
import { extractMessage, htmlToText } from "./extract.ts";
import { rawEmail } from "./test-fakes.ts";

describe("extractMessage", () => {
  it("reads the sender, recipients, subject, and plain text body", async () => {
    const fields = await extractMessage(
      rawEmail({ to: "Me <me@example.com>", cc: "bob@example.com", subject: "Lunch", text: "See you\r\n  at noon" }),
    );

    expect(fields).toEqual({
      from: "Jane Doe <jane@example.com>",
      to: "Me <me@example.com>, bob@example.com",
      subject: "Lunch",
      attachments: [],
      body: "See you at noon",
    });
  });

  it("uses the HTML body without tags when there is no plain text", async () => {
    const fields = await extractMessage(
      rawEmail({ html: "<style>p { color: red }</style><p>Your order <b>shipped</b></p>" }),
    );

    expect(fields.body).toBe("Your order shipped");
  });

  it("lists attachment filenames", async () => {
    const fields = await extractMessage(rawEmail({ attachment: "invoice.pdf" }));

    expect(fields.attachments).toEqual(["invoice.pdf"]);
  });

  it("lists the members of an address group", async () => {
    const fields = await extractMessage(rawEmail({ to: "Team: a@example.com, b@example.com;" }));

    expect(fields.to).toBe("a@example.com, b@example.com");
  });
});

describe("htmlToText", () => {
  it("removes tags, styles, and scripts, and decodes common entities", () => {
    expect(htmlToText("<style>p{}</style><p>Tom &amp; Jerry&nbsp;&lt;3</p><script>x()</script>")).toBe(
      "Tom & Jerry <3",
    );
  });
});
