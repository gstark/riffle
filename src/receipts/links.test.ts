import { describe, expect, it } from "vitest";
import { emailLinks, selectLinks } from "./links.ts";

describe("emailLinks", () => {
  it("returns http links with their text and decodes &amp;", () => {
    const html = `<a href="https://shop.example/r?a=1&amp;b=2"><b>View</b> receipt</a>
      <a href='mailto:help@shop.example'>Help</a> <a class="x" href="http://shop.example/"><img src="logo.png"></a>`;
    expect(emailLinks(html)).toEqual([
      { url: "https://shop.example/r?a=1&b=2", text: "View receipt" },
      { url: "http://shop.example/", text: "" },
    ]);
  });
});

describe("selectLinks", () => {
  const links = [
    { url: "https://shop.example/", text: "" },
    { url: "https://shop.example/unsubscribe?u=1", text: "Unsubscribe" },
    { url: "https://click.example/abc", text: "View your order" },
    { url: "https://shop.example/invoice/42.pdf", text: "Download invoice" },
    { url: "https://shop.example/account/cancel", text: "Cancel subscription" },
    { url: "https://www.facebook.com/shop", text: "Order on Facebook" },
  ];

  it("puts receipt words first and drops links without them", () => {
    expect(selectLinks(links, [], 3)).toEqual(["https://shop.example/invoice/42.pdf", "https://click.example/abc"]);
  });

  it("adds the model link, also when it is only in the plain text", () => {
    expect(selectLinks(links, ["https://shop.example/"], 3)).toEqual([
      "https://shop.example/invoice/42.pdf",
      "https://shop.example/",
      "https://click.example/abc",
    ]);
    expect(selectLinks([], ["https://plain.example/r/1"], 3)).toEqual(["https://plain.example/r/1"]);
  });

  it("never selects links that change the account, even from the model", () => {
    expect(selectLinks(links, ["https://shop.example/unsubscribe?u=1"], 5)).not.toContain(
      "https://shop.example/unsubscribe?u=1",
    );
  });

  it("keeps confirmation links and blocks action paths", () => {
    const more = [
      { url: "https://shop.example/orders/1?ref=confirm", text: "View order confirmation" },
      { url: "https://shop.example/subscription/cancel/1", text: "Billing" },
    ];
    expect(selectLinks(more, [], 3)).toEqual(["https://shop.example/orders/1?ref=confirm"]);
  });

  it("returns at most max links", () => {
    expect(selectLinks(links, [], 1)).toEqual(["https://shop.example/invoice/42.pdf"]);
  });
});
