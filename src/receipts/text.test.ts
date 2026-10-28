import { describe, expect, it } from "vitest";
import { rawEmail } from "../search/test-fakes.ts";
import { htmlToTextWithLinks, readReceiptEmail } from "./text.ts";

describe("htmlToTextWithLinks", () => {
  it("writes the URL after the link text and decodes entities", () => {
    expect(htmlToTextWithLinks('<p>View <a href="https://a.example/o?id=1&amp;x=2">your order</a></p>')).toBe(
      "View your order [https://a.example/o?id=1&x=2]",
    );
  });

  it("keeps links that have only an image, single quotes, and other attributes", () => {
    expect(htmlToTextWithLinks(`<a class="b" href='https://x.example/r' target="_blank"><img src="logo.png"></a>`)).toBe(
      "[https://x.example/r]",
    );
  });

  it("keeps the text of links that are not http or https", () => {
    expect(htmlToTextWithLinks('<a href="mailto:help@x.example">Help</a>')).toBe("Help");
  });

  it("reads upper-case tags", () => {
    expect(htmlToTextWithLinks('<A HREF="https://x.example">Go</A>')).toBe("Go [https://x.example]");
  });

  it("decodes numeric and currency entities", () => {
    expect(htmlToTextWithLinks("<p>Total &euro;12,99 &#36;5 &#x20AC;3</p>")).toBe("Total €12,99 $5 €3");
  });

  it("decodes the pound, yen, and cent entities", () => {
    expect(htmlToTextWithLinks("<p>&pound;1 &yen;2 &cent;3</p>")).toBe("£1 ¥2 ¢3");
  });

  it("reads links that have nested tags", () => {
    expect(htmlToTextWithLinks('<a href="https://x.example/o"><b>View</b> order</a>')).toBe(
      "View order [https://x.example/o]",
    );
  });

  it("reads a link with an unquoted href", () => {
    expect(htmlToTextWithLinks("<a href=https://x.example/o>Order</a>")).toBe("Order [https://x.example/o]");
  });

  it("ignores data-href", () => {
    expect(htmlToTextWithLinks('<a data-href="https://x.example">Go</a>')).toBe("Go");
  });
});

describe("readReceiptEmail", () => {
  it("uses the HTML body with links when there is one", async () => {
    const raw = rawEmail({
      from: "Amazon <auto-confirm@amazon.com>",
      subject: "Your order",
      html: '<p>See <a href="https://shop.example/o/1">order details</a></p>',
    });

    expect(await readReceiptEmail(raw)).toEqual({
      from: "Amazon <auto-confirm@amazon.com>",
      subject: "Your order",
      text: "See order details [https://shop.example/o/1]",
    });
  });

  it("uses the plain text body when there is no HTML", async () => {
    const raw = rawEmail({ subject: "Receipt", text: "Paid $5.00 https://shop.example/r/2" });

    expect((await readReceiptEmail(raw)).text).toBe("Paid $5.00 https://shop.example/r/2");
  });
});
