import { describe, expect, it } from "vitest";
import { rawEmail } from "../search/test-fakes.ts";
import { readProofEmail } from "./proof-email.ts";

describe("readProofEmail", () => {
  it("adds a header, keeps the links, and returns PDF attachments", async () => {
    const email = await readProofEmail(
      rawEmail({
        from: "Shop <orders@shop.example>",
        subject: "Your <receipt>",
        html: '<p>Total $5.00 <a href="https://shop.example/r/1">View receipt</a></p>',
        attachment: "invoice.pdf",
      }),
    );

    expect(email.page).toContain("<b>From:</b> Shop &lt;orders@shop.example&gt;");
    expect(email.page).toContain("<b>Subject:</b> Your &lt;receipt&gt;");
    expect(email.page).toContain("Total $5.00");
    expect(email.links).toEqual([{ url: "https://shop.example/r/1", text: "View receipt" }]);
    expect(email.pdfs).toHaveLength(1);
    expect(email.pdfs[0]?.filename).toBe("invoice.pdf");
    expect(Buffer.from(email.pdfs[0]?.content ?? []).toString("latin1")).toMatch(/^%PDF/);
  });

  it("escapes a plain text email", async () => {
    const email = await readProofEmail(rawEmail({ text: "Total <$5.00>" }));
    expect(email.page).toContain("Total &lt;$5.00&gt;");
    expect(email.links).toEqual([]);
  });
});
